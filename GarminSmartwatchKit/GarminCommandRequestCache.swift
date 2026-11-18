//
//  GarminCommandRequestCache.swift
//  GarminSmartwatchKit
//
//  From Tai's WatchCommandRequestCache (mountrcg/Tai, MIT), for the plugin.
//

import Foundation

/// Remembers recent watch request IDs so a relayed or retried command executes at most once.
///
/// Insulin requests (bolus, meal bolus) are also kept in a `GarminCommandStore`: admitted before
/// they run and updated with their result, so a resend after an app relaunch gets the first
/// answer, or `.interrupted` when the app stopped while it ran, and is never executed again.
/// Other commands are kept in memory only; after a relaunch their freshness window is what stops
/// a replay.
actor GarminCommandRequestCache {
    struct Key: Hashable {
        let appUUID: UUID
        let requestID: UUID
    }

    /// Proof of one admission; only its holder may complete the entry it reserved.
    struct Ticket: Equatable {
        let key: Key
        let generation: UInt64
    }

    enum Admission: Equatable {
        /// First sighting; the caller must execute and then call `complete` with the ticket.
        case accepted(Ticket)
        case inProgress
        /// The request ID was already used for a different command.
        case conflict
        case completed(GarminWatchCommandResult)
        /// Admitted before the app was last relaunched, with no result stored: it may have run.
        case interrupted
        /// Every slot holds an executing request, and those are never evicted.
        case full
    }

    private enum State {
        case inFlight(generation: UInt64)
        case completed(GarminWatchCommandResult)
        /// Loaded from the store without a result.
        case interrupted
    }

    private struct Entry {
        let command: GarminWatchCommand
        var state: State
        let insertedAt: Date
        var lastUsed: UInt64

        var isInFlight: Bool {
            if case .inFlight = state { return true }
            return false
        }
    }

    static let defaultCapacity = 256
    static let defaultLifetime: TimeInterval = 15 * 60

    private let capacity: Int
    private let lifetime: TimeInterval
    private let store: GarminCommandStore

    private var entries: [Key: Entry] = [:]
    /// Monotonic use counter; a clock would tie when several requests arrive within one tick.
    private var useCounter: UInt64 = 0
    private var generationCounter: UInt64 = 0

    /// Loads the insulin requests `store` kept from earlier launches; expired ones are dropped at
    /// the next `admit`.
    init(
        capacity: Int = defaultCapacity,
        lifetime: TimeInterval = defaultLifetime,
        store: GarminCommandStore = GarminCommandDefaultsStore.standard
    ) {
        self.capacity = capacity
        self.lifetime = lifetime
        self.store = store
        var loaded: [Key: Entry] = [:]
        for stored in store.insulinRequests {
            let state: State = stored.commandResult.map { .completed($0) } ?? .interrupted
            loaded[Key(appUUID: stored.appUUID, requestID: stored.requestID)] = Entry(
                command: stored.command,
                state: state,
                insertedAt: stored.admittedAt,
                lastUsed: 0
            )
        }
        entries = loaded
    }

    var count: Int { entries.count }

    /// Reserves `key` before anything executes, or reports why it must not run now.
    func admit(_ key: Key, command: GarminWatchCommand, now: Date) -> Admission {
        evictExpired(now: now)
        useCounter += 1

        if var entry = entries[key] {
            guard entry.command == command else { return .conflict }
            entry.lastUsed = useCounter
            entries[key] = entry
            switch entry.state {
            case .inFlight: return .inProgress
            case let .completed(result): return .completed(result)
            case .interrupted: return .interrupted
            }
        }

        if entries.count >= capacity {
            // evicting a running request would let its duplicate execute a second time
            guard let leastRecentlyUsed = entries.filter({ !$0.value.isInFlight })
                .min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            else { return .full }
            entries[leastRecentlyUsed] = nil
        }

        generationCounter += 1
        let ticket = Ticket(key: key, generation: generationCounter)
        entries[key] = Entry(
            command: command,
            state: .inFlight(generation: ticket.generation),
            insertedAt: now,
            lastUsed: useCounter
        )
        // stored before the caller can execute it
        if let stored = GarminStoredInsulinRequest(appUUID: key.appUUID, requestID: key.requestID, admittedAt: now, command: command) {
            store.saveInsulinRequest(stored)
        }
        return .accepted(ticket)
    }

    /// Ignored unless `ticket` still owns the reservation, so a stale execution cannot overwrite
    /// the result of a newer admission under the same key.
    func complete(_ ticket: Ticket, result: GarminWatchCommandResult) {
        guard var entry = entries[ticket.key],
              case let .inFlight(generation) = entry.state,
              generation == ticket.generation
        else { return }
        entry.state = .completed(result)
        entries[ticket.key] = entry
        if let stored = GarminStoredInsulinRequest(
            appUUID: ticket.key.appUUID,
            requestID: ticket.key.requestID,
            admittedAt: entry.insertedAt,
            command: entry.command,
            result: result
        ) {
            store.saveInsulinRequest(stored)
        }
    }

    /// Executing entries outlive their lifetime until they complete. Stored requests are pruned
    /// by the lifetime alone: one still executing that long is far outside its freshness window.
    private func evictExpired(now: Date) {
        entries = entries.filter { $0.value.isInFlight || now.timeIntervalSince($0.value.insertedAt) < lifetime }
        store.pruneInsulinRequests(admittedThrough: now.addingTimeInterval(-lifetime))
    }
}
