import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

/// The insulin-command state kept across launches: the store itself, and the processor after a
/// relaunch (a new processor on the same store).
@MainActor @Suite("Garmin command store") struct GarminCommandStoreTests {
    private let start = GarminProcessorRig.start

    /// A throwaway defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "org.loopkit.GarminSmartwatchKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    private func stored(_ command: GarminWatchCommand, at date: Date, result: GarminWatchCommandResult? = nil) -> GarminStoredInsulinRequest {
        GarminStoredInsulinRequest(appUUID: UUID(), requestID: UUID(), admittedAt: date, command: command, result: result)!
    }

    // MARK: - UserDefaults store

    @Test("Keys are namespaced to the plugin") func keys() {
        #expect(GarminCommandDefaultsStore.lastBolusEnactmentKey.hasPrefix("org.loopkit.GarminSmartwatchKit."))
        #expect(GarminCommandDefaultsStore.insulinRequestsKey.hasPrefix("org.loopkit.GarminSmartwatchKit."))
    }

    @Test("What one store writes, a new store on the same defaults reads") func roundTrip() async {
        await withDefaults { defaults in
            let clock = GarminTestClock(start)
            let first = GarminCommandDefaultsStore(defaults: defaults, now: { clock.now })
            let meal = stored(.mealBolus(carbs: 30, bolus: Decimal(string: "2.35")!), at: start, result: .success(.genericSuccess, "ok"))
            let bolus = stored(.bolus(1), at: start)
            first.setLastBolusEnactment(start)
            first.saveInsulinRequest(meal)
            first.saveInsulinRequest(bolus)

            let second = GarminCommandDefaultsStore(defaults: defaults, now: { clock.now })
            #expect(second.lastBolusEnactment == start)
            #expect(second.insulinRequests == [meal, bolus])
            #expect(second.insulinRequests.map(\.command) == [.mealBolus(carbs: 30, bolus: Decimal(string: "2.35")!), .bolus(1)])
            #expect(second.insulinRequests.first?.commandResult == .success(.genericSuccess, "ok"))
            #expect(second.recoveredFromUnreadableData == false)

            second.setLastBolusEnactment(nil)
            #expect(GarminCommandDefaultsStore(defaults: defaults).lastBolusEnactment == nil)
        }
    }

    @Test("Saving the same request again replaces it") func upsert() async {
        await withDefaults { defaults in
            let store = GarminCommandDefaultsStore(defaults: defaults)
            var request = stored(.bolus(1), at: start)
            store.saveInsulinRequest(request)
            request.result = .init(.failure("No glucose reading in the last 15 minutes. No bolus was delivered."))
            store.saveInsulinRequest(request)

            #expect(GarminCommandDefaultsStore(defaults: defaults).insulinRequests == [request])
        }
    }

    @Test("Requests admitted at or before the cutoff are pruned") func prune() async {
        await withDefaults { defaults in
            let store = GarminCommandDefaultsStore(defaults: defaults)
            let old = stored(.bolus(1), at: start)
            let recent = stored(.bolus(1), at: start.addingTimeInterval(1))
            store.saveInsulinRequest(old)
            store.saveInsulinRequest(recent)

            store.pruneInsulinRequests(admittedThrough: start)

            #expect(store.insulinRequests == [recent])
            #expect(GarminCommandDefaultsStore(defaults: defaults).insulinRequests == [recent])
        }
    }

    @Test("At most a cache's worth of requests is kept, oldest dropped first") func capped() async {
        await withDefaults { defaults in
            let store = GarminCommandDefaultsStore(defaults: defaults)
            let limit = GarminCommandDefaultsStore.maximumStoredRequests
            for index in 0 ... limit {
                store.saveInsulinRequest(stored(.bolus(1), at: start.addingTimeInterval(TimeInterval(index))))
            }
            #expect(store.insulinRequests.count == limit)
            #expect(store.insulinRequests.first?.admittedAt == start.addingTimeInterval(1))
        }
    }

    @Test(
        "Unreadable data fails safe: the hold starts at load, unreadable requests are dropped, readable data is written back",
        arguments: ["enactment", "requests", "both", "wrongType"]
    ) func unreadable(what: String) async {
        await withDefaults { defaults in
            let garbage = Data("not json".utf8)
            let earlier = start.addingTimeInterval(-60 * 60)
            let readable = stored(.bolus(1), at: start)
            // readable data first, then the unreadable part over it
            let seed = GarminCommandDefaultsStore(defaults: defaults)
            seed.setLastBolusEnactment(earlier)
            seed.saveInsulinRequest(readable)
            if what == "enactment" || what == "both" {
                defaults.set(garbage, forKey: GarminCommandDefaultsStore.lastBolusEnactmentKey)
            }
            if what == "wrongType" {
                defaults.set("2026-01-01", forKey: GarminCommandDefaultsStore.lastBolusEnactmentKey)
            }
            if what == "requests" || what == "both" {
                defaults.set(garbage, forKey: GarminCommandDefaultsStore.insulinRequestsKey)
            }

            let clock = GarminTestClock(start)
            let store = GarminCommandDefaultsStore(defaults: defaults, now: { clock.now })
            #expect(store.lastBolusEnactment == start, "A bolus is taken to have happened at load")
            #expect(store.recoveredFromUnreadableData)
            let requestsReadable = what != "requests" && what != "both"
            #expect(store.insulinRequests == (requestsReadable ? [readable] : []))

            clock.advance(by: 60 * 60)
            let relaunched = GarminCommandDefaultsStore(defaults: defaults, now: { clock.now })
            #expect(relaunched.lastBolusEnactment == start, "Written back: the hold doesn't restart at the next launch")
            #expect(relaunched.recoveredFromUnreadableData == false)
        }
    }

    @Test("An enactment stored in the future (clock turned back) is taken as the load time") func futureEnactment() async {
        await withDefaults { defaults in
            GarminCommandDefaultsStore(defaults: defaults).setLastBolusEnactment(start.addingTimeInterval(24 * 60 * 60))

            let store = GarminCommandDefaultsStore(defaults: defaults, now: { [start] in start })
            #expect(store.lastBolusEnactment == start)
        }
    }

    @Test("Nothing stored is no enactment and no requests") func empty() async {
        await withDefaults { defaults in
            let store = GarminCommandDefaultsStore(defaults: defaults)
            #expect(store.lastBolusEnactment == nil)
            #expect(store.insulinRequests.isEmpty)
            #expect(store.recoveredFromUnreadableData == false)
        }
    }

    @Test("Only insulin commands can be stored") func onlyInsulin() {
        for command in [GarminWatchCommand.carbs(10), .cancelOverride, .activateOverride(name: "x"), .activateTempTarget(name: "x"), .cancelTempTarget] {
            #expect(GarminStoredInsulinRequest(appUUID: UUID(), requestID: UUID(), admittedAt: start, command: command) == nil)
        }
    }

    // MARK: - Processor after a relaunch

    @Test("The hold still applies after a relaunch", arguments: [false, true])
    func holdAfterRelaunch(isMeal: Bool) async {
        await withDefaults { defaults in
            let clock = GarminTestClock(start)
            let rig = GarminProcessorRig(store: GarminCommandDefaultsStore(defaults: defaults, now: { clock.now }), clock: clock)
            #expect(await rig.processor.process(rig.request(.bolus(1))).acknowledged)

            // a new store on the same defaults, as after the process was killed
            clock.advance(by: GarminCommandProcessor.minimumBolusInterval - 1)
            let relaunched = GarminProcessorRig(store: GarminCommandDefaultsStore(defaults: defaults, now: { clock.now }), clock: clock, host: rig.host)
            let command: GarminWatchCommand = isMeal ? .mealBolus(carbs: 30, bolus: 1) : .bolus(1)
            let expected = isMeal
                ? "Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No carbs or bolus were logged."
                : "Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No bolus was delivered."
            #expect(await relaunched.processor.process(relaunched.request(command)) == .failure(expected))
            #expect(rig.host.calls.count == 1, "No carbs, no second bolus")

            clock.advance(by: 1)
            #expect(await relaunched.processor.process(relaunched.request(.bolus(1))).acknowledged)
        }
    }

    @Test("A completed request resent after a relaunch gets its first answer and runs once") func duplicateAfterRelaunch() async {
        await withDefaults { defaults in
            let clock = GarminTestClock(start)
            let rig = GarminProcessorRig(store: GarminCommandDefaultsStore(defaults: defaults, now: { clock.now }), clock: clock)
            let request = rig.request(.mealBolus(carbs: 30, bolus: 1))
            let first = await rig.processor.process(request)
            #expect(first.acknowledged)

            // past the hold, inside the cache lifetime: only the request record stops it
            clock.advance(by: GarminCommandProcessor.minimumBolusInterval)
            let relaunched = GarminProcessorRig(store: GarminCommandDefaultsStore(defaults: defaults, now: { clock.now }), clock: clock, host: rig.host)
            #expect(await relaunched.processor.process(request) == first)
            #expect(rig.host.carbCalls == [30])
            #expect(rig.host.bolusCalls == [1])
        }
    }

    @Test("A request that was running when the app stopped is not run again") func interruptedAfterRelaunch() async {
        let rig = GarminProcessorRig()
        rig.host.bolusGate = GarminTestGate()
        let request = rig.request(.bolus(2))
        let pending = Task { await rig.processor.process(request) }
        await rig.host.bolusGate?.waitForArrivals()

        let relaunched = rig.relaunched()
        let resent = await relaunched.processor.process(request)
        #expect(resent.acknowledged == false)
        #expect(resent.ackCode == .genericFailure)
        #expect(resent.message.contains("pump history"))
        #expect(rig.host.bolusCalls == [2])

        rig.host.bolusGate?.open()
        _ = await pending.value
    }

    @Test("A bolus refused with nothing sent leaves no hold after a relaunch") func restoredHoldPersists() async {
        let rig = GarminProcessorRig()
        rig.host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        #expect(await rig.processor.process(rig.request(.bolus(2))).acknowledged == false)

        let relaunched = rig.relaunched()
        #expect(await relaunched.processor.process(relaunched.request(.bolus(1))).acknowledged)
    }

    @Test("An unreadable store holds back watch boluses, and their carbs, for six minutes") func unreadableStoreHolds() async {
        await withDefaults { defaults in
            defaults.set(Data("garbage".utf8), forKey: GarminCommandDefaultsStore.lastBolusEnactmentKey)
            let clock = GarminTestClock(start)
            let rig = GarminProcessorRig(store: GarminCommandDefaultsStore(defaults: defaults, now: { clock.now }), clock: clock)

            #expect(await rig.processor.process(rig.request(.bolus(1))) == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No bolus was delivered."))
            #expect(await rig.processor.process(rig.request(.mealBolus(carbs: 30, bolus: 1))) == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No carbs or bolus were logged."))
            #expect(rig.host.calls.isEmpty)
            #expect(await rig.processor.process(rig.request(.carbs(10))).acknowledged, "Carbs alone aren't held")

            clock.advance(by: GarminCommandProcessor.minimumBolusInterval)
            #expect(await rig.processor.process(rig.request(.bolus(1))).acknowledged)
        }
    }

    @Test("Stored requests older than the cache lifetime are pruned when the next command arrives") func prunedOnAdmit() async {
        let store = GarminCommandMemoryStore()
        let rig = GarminProcessorRig(store: store)
        #expect(await rig.processor.process(rig.request(.bolus(1))).acknowledged)
        #expect(store.insulinRequests.count == 1)

        rig.clock.advance(by: GarminCommandRequestCache.defaultLifetime)
        let relaunched = rig.relaunched()
        _ = await relaunched.processor.process(relaunched.request(.carbs(10)))
        #expect(store.insulinRequests.isEmpty)
    }
}
