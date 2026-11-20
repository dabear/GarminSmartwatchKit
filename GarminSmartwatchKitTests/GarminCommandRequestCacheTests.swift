import Foundation
import Testing

@testable import GarminSmartwatchKit

@Suite("Garmin command request cache") struct GarminCommandRequestCacheTests {
    let appUUID = UUID()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let done = GarminWatchCommandResult.success(.overrideStopped, "Override stopped.")

    private func key(_ requestID: UUID = UUID(), app: UUID? = nil) -> GarminCommandRequestCache.Key {
        GarminCommandRequestCache.Key(appUUID: app ?? appUUID, requestID: requestID)
    }

    private func ticket(_ admission: GarminCommandRequestCache.Admission) -> GarminCommandRequestCache.Ticket? {
        guard case let .accepted(ticket) = admission else { return nil }
        return ticket
    }

    private func admitted(
        _ cache: GarminCommandRequestCache,
        _ key: GarminCommandRequestCache.Key,
        _ command: GarminWatchCommand,
        at now: Date
    ) async throws -> GarminCommandRequestCache.Ticket {
        let admission = await cache.admit(key, command: command, now: now)
        return try #require(ticket(admission))
    }

    @Test("A request stays in flight until completed, then replays its result") func testInFlightThenCompleted() async throws {
        let cache = GarminCommandRequestCache(store: GarminCommandMemoryStore())
        let key = key()
        let result = GarminWatchCommandResult.success(.carbsLogged, "Carbs logged.")

        let reservation = try await admitted(cache, key, .carbs(20), at: start)
        #expect(await cache.admit(key, command: .carbs(20), now: start) == .inProgress)

        await cache.complete(reservation, result: result)
        #expect(await cache.admit(key, command: .carbs(20), now: start) == .completed(result))
    }

    @Test("Reusing a request ID for another command is a conflict") func testConflict() async throws {
        let cache = GarminCommandRequestCache(store: GarminCommandMemoryStore())
        let key = key()

        _ = try await admitted(cache, key, .carbs(20), at: start)
        #expect(await cache.admit(key, command: .carbs(25), now: start) == .conflict)
        #expect(await cache.admit(key, command: .cancelOverride, now: start) == .conflict)
    }

    @Test("The same request ID from another app is a separate request") func testScopedByApp() async {
        let cache = GarminCommandRequestCache(store: GarminCommandMemoryStore())
        let requestID = UUID()

        #expect(ticket(await cache.admit(key(requestID), command: .cancelOverride, now: start)) != nil)
        #expect(ticket(await cache.admit(key(requestID, app: UUID()), command: .cancelOverride, now: start)) != nil)
    }

    @Test("Completed entries expire after their lifetime") func testExpiry() async throws {
        let cache = GarminCommandRequestCache(capacity: 256, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let key = key()

        let reservation = try await admitted(cache, key, .cancelOverride, at: start)
        await cache.complete(reservation, result: done)
        #expect(await cache.admit(key, command: .cancelOverride, now: start.addingTimeInterval(15 * 60 - 1)) == .completed(done))
        #expect(ticket(await cache.admit(key, command: .cancelOverride, now: start.addingTimeInterval(15 * 60))) != nil)
    }

    @Test("An executing entry outlives its lifetime") func testInFlightNeverExpires() async throws {
        let cache = GarminCommandRequestCache(capacity: 256, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let key = key()

        _ = try await admitted(cache, key, .cancelOverride, at: start)
        #expect(await cache.admit(key, command: .cancelOverride, now: start.addingTimeInterval(60 * 60)) == .inProgress)
    }

    @Test("A full cache evicts the least recently used completed entry") func testLeastRecentlyUsedEviction() async throws {
        let cache = GarminCommandRequestCache(capacity: 2, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let first = key()
        let second = key()

        try await cache.complete(admitted(cache, first, .cancelOverride, at: start), result: done)
        try await cache.complete(admitted(cache, second, .cancelOverride, at: start), result: done)
        // touching the first entry makes the second the least recently used
        #expect(await cache.admit(first, command: .cancelOverride, now: start) == .completed(done))
        #expect(ticket(await cache.admit(key(), command: .cancelOverride, now: start)) != nil)

        #expect(await cache.count == 2)
        #expect(await cache.admit(first, command: .cancelOverride, now: start) == .completed(done))
        #expect(ticket(await cache.admit(second, command: .cancelOverride, now: start)) != nil, "Second was evicted")
    }

    @Test("Executing entries are never evicted; a full cache rejects instead") func testCapacityKeepsInFlight() async throws {
        let cache = GarminCommandRequestCache(capacity: 2, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let first = key()
        let second = key()

        let firstTicket = try await admitted(cache, first, .bolus(1), at: start)
        _ = try await admitted(cache, second, .bolus(2), at: start)

        #expect(await cache.admit(key(), command: .bolus(3), now: start) == .full)
        // a replay of a running request is still recognized, never re-admitted
        #expect(await cache.admit(first, command: .bolus(1), now: start) == .inProgress)
        #expect(await cache.admit(first, command: .bolus(5), now: start) == .conflict)

        await cache.complete(firstTicket, result: done)
        #expect(ticket(await cache.admit(key(), command: .bolus(3), now: start)) != nil, "A completed slot frees up")
        #expect(await cache.admit(second, command: .bolus(2), now: start) == .inProgress)
    }

    @Test("A stale execution cannot complete a newer admission of the same key") func testStaleCompletion() async throws {
        let cache = GarminCommandRequestCache(capacity: 256, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let key = key()
        let stale = GarminWatchCommandResult.failure("stale")
        let fresh = GarminWatchCommandResult.success(.carbsLogged, "fresh")

        let oldTicket = try await admitted(cache, key, .carbs(10), at: start)
        await cache.complete(oldTicket, result: stale)
        let later = start.addingTimeInterval(15 * 60)
        let newTicket = try await admitted(cache, key, .carbs(10), at: later)
        #expect(newTicket != oldTicket)

        await cache.complete(oldTicket, result: stale)
        #expect(await cache.admit(key, command: .carbs(10), now: later) == .inProgress)

        await cache.complete(newTicket, result: fresh)
        #expect(await cache.admit(key, command: .carbs(10), now: later) == .completed(fresh))
        await cache.complete(oldTicket, result: stale)
        #expect(await cache.admit(key, command: .carbs(10), now: later) == .completed(fresh), "Completed results are final")
    }

    @Test("Expired entries are evicted before live ones") func testExpiredEvictedFirst() async throws {
        let cache = GarminCommandRequestCache(capacity: 2, lifetime: 15 * 60, store: GarminCommandMemoryStore())
        let old = key()
        let recent = key()

        try await cache.complete(admitted(cache, old, .cancelOverride, at: start), result: done)
        _ = await cache.admit(recent, command: .cancelOverride, now: start.addingTimeInterval(10 * 60))
        #expect(ticket(await cache.admit(key(), command: .cancelOverride, now: start.addingTimeInterval(16 * 60))) != nil)

        #expect(await cache.admit(recent, command: .cancelOverride, now: start.addingTimeInterval(16 * 60)) == .inProgress)
    }

    // MARK: - Across relaunches

    @Test("A completed insulin request replays its result from a new cache on the same store") func testInsulinResultSurvivesRelaunch() async throws {
        let store = GarminCommandMemoryStore()
        let key = key()
        let delivered = GarminWatchCommandResult.success(.genericSuccess, "Bolus started.")
        let first = GarminCommandRequestCache(store: store)
        try await first.complete(admitted(first, key, .bolus(1.5), at: start), result: delivered)

        let relaunched = GarminCommandRequestCache(store: store)
        #expect(await relaunched.admit(key, command: .bolus(1.5), now: start.addingTimeInterval(60)) == .completed(delivered))
        #expect(await relaunched.admit(key, command: .bolus(2), now: start.addingTimeInterval(60)) == .conflict)
    }

    @Test("An insulin request admitted but never completed is interrupted after a relaunch", arguments: [
        GarminWatchCommand.bolus(1), .mealBolus(carbs: 30, bolus: 2)
    ]) func testInterruptedAfterRelaunch(command: GarminWatchCommand) async throws {
        let store = GarminCommandMemoryStore()
        let key = key()
        _ = try await admitted(GarminCommandRequestCache(store: store), key, command, at: start)
        #expect(store.insulinRequests.count == 1, "Stored at admission, before anything runs")

        let relaunched = GarminCommandRequestCache(store: store)
        #expect(await relaunched.admit(key, command: command, now: start.addingTimeInterval(60)) == .interrupted)
    }

    @Test("Only insulin requests are stored") func testOnlyInsulinStored() async throws {
        let store = GarminCommandMemoryStore()
        let cache = GarminCommandRequestCache(store: store)
        for command in [GarminWatchCommand.carbs(10), .cancelOverride, .activateOverride(name: "Sport"), .cancelTempTarget] {
            try await cache.complete(admitted(cache, key(), command, at: start), result: done)
        }
        #expect(store.insulinRequests.isEmpty)
    }

    @Test("Stored requests expire with the cache lifetime and are pruned from the store") func testStoredRequestsPruned() async throws {
        let store = GarminCommandMemoryStore()
        let old = key()
        let cache = GarminCommandRequestCache(capacity: 256, lifetime: 15 * 60, store: store)
        try await cache.complete(admitted(cache, old, .bolus(1), at: start), result: done)
        _ = try await admitted(cache, key(), .bolus(1), at: start.addingTimeInterval(10 * 60))

        let relaunched = GarminCommandRequestCache(capacity: 256, lifetime: 15 * 60, store: store)
        let later = start.addingTimeInterval(15 * 60)
        #expect(ticket(await relaunched.admit(old, command: .bolus(1), now: later)) != nil, "Expired: a new request")
        #expect(store.insulinRequests.map(\.admittedAt) == [start.addingTimeInterval(10 * 60), later])
    }

    @Test("Default limits are 256 entries for 15 minutes") func testDefaults() {
        #expect(GarminCommandRequestCache.defaultCapacity == 256)
        #expect(GarminCommandRequestCache.defaultLifetime == 15 * 60)
    }
}
