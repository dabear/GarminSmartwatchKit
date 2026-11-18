//
//  GarminCommandStore.swift
//  GarminSmartwatchKit
//
//  What the watch insulin commands must remember across app launches.
//

import Foundation

/// The insulin-command safety state that outlives the app: when a watch bolus was last handed to
/// the host (the 6-minute hold) and the insulin requests seen recently (so a resend after a
/// relaunch is not executed again).
///
/// Reads and writes are synchronous and thread-safe; a write is in memory at once and handed to
/// the backing storage before the call returns, so a record written before a host call is there
/// even when the app dies during that call.
protocol GarminCommandStore: AnyObject, Sendable {
    /// When a watch bolus was last handed to the host; `nil` when none is known.
    var lastBolusEnactment: Date? { get }
    func setLastBolusEnactment(_ date: Date?)

    /// Recently seen insulin requests, oldest first.
    var insulinRequests: [GarminStoredInsulinRequest] { get }
    /// Adds the request, or replaces the one with the same app and request ID.
    func saveInsulinRequest(_ request: GarminStoredInsulinRequest)
    /// Drops requests admitted at or before `cutoff`, as the cache's lifetime does.
    func pruneInsulinRequests(admittedThrough cutoff: Date)
    /// The stored record couldn't be read, so watch boluses are held as after a bolus.
    var recoveredFromUnreadableData: Bool { get }
}

extension GarminCommandStore {
    var recoveredFromUnreadableData: Bool { false }
}

/// An insulin request as stored: who sent it, what it asked for, when it was admitted and, once
/// it ran to the end, its result. Without a result after a relaunch, the app stopped while it ran.
struct GarminStoredInsulinRequest: Codable, Equatable, Sendable {
    struct Result: Codable, Equatable, Sendable {
        let acknowledged: Bool
        /// `GarminAckCode` raw value.
        let ackCode: String
        let message: String
    }

    let appUUID: UUID
    let requestID: UUID
    let admittedAt: Date
    let bolus: Decimal
    /// Grams for a meal bolus; `nil` for a bolus.
    let carbs: Int?
    var result: Result?

    /// `nil` for a command that isn't insulin.
    init?(appUUID: UUID, requestID: UUID, admittedAt: Date, command: GarminWatchCommand, result: GarminWatchCommandResult? = nil) {
        switch command {
        case let .bolus(units):
            bolus = units
            carbs = nil
        case let .mealBolus(grams, units):
            bolus = units
            carbs = grams
        default:
            return nil
        }
        self.appUUID = appUUID
        self.requestID = requestID
        self.admittedAt = admittedAt
        self.result = result.map(Result.init)
    }

    var command: GarminWatchCommand {
        carbs.map { .mealBolus(carbs: $0, bolus: bolus) } ?? .bolus(bolus)
    }

    /// An unknown ack code reads as a failure with the stored message: the request still never
    /// runs again.
    var commandResult: GarminWatchCommandResult? {
        guard let result else { return nil }
        guard let ackCode = GarminAckCode(rawValue: result.ackCode) else { return .failure(result.message) }
        return GarminWatchCommandResult(acknowledged: result.acknowledged, ackCode: ackCode, message: result.message)
    }
}

extension GarminStoredInsulinRequest.Result {
    init(_ result: GarminWatchCommandResult) {
        self.init(acknowledged: result.acknowledged, ackCode: result.ackCode.rawValue, message: result.message)
    }
}

// MARK: - UserDefaults

/// Keeps the state in `UserDefaults` under the plugin's own keys, as JSON.
///
/// Loaded once, on first use. Stored data that is there but can't be read fails safe: the hold
/// is taken to have started at that moment (`now()` at load), so no watch bolus runs for the
/// next `GarminCommandProcessor.minimumBolusInterval`, and the unreadable requests are dropped.
/// A resend of a request whose record was lost can then only run once that hold is over, after
/// its own 2-minute freshness window has closed. Treating unreadable data as empty would instead
/// let a bolus that was handed to the pump just before a relaunch be repeated at once.
///
/// A stored enactment later than `now()` at load (the phone's clock was turned back) is taken as
/// `now()`: the hold then lasts the full interval from the relaunch, never longer.
final class GarminCommandDefaultsStore: GarminCommandStore, @unchecked Sendable {
    static let lastBolusEnactmentKey = "org.loopkit.GarminSmartwatchKit.lastWatchBolusEnactment"
    static let insulinRequestsKey = "org.loopkit.GarminSmartwatchKit.recentInsulinRequests"
    /// Bounds the stored list whatever the request rate; the cache holds no more than this either.
    static let maximumStoredRequests = GarminCommandRequestCache.defaultCapacity

    /// The one the plugin uses, so every processor shares one hold.
    static let standard = GarminCommandDefaultsStore(defaults: .standard)

    private struct StoredEnactment: Codable {
        let date: Date
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()
    private var isLoaded = false
    private var enactment: Date?
    private var requests: [GarminStoredInsulinRequest] = []
    private(set) var recoveredFromUnreadableData = false

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    var lastBolusEnactment: Date? {
        lock.withLock {
            loadIfNeeded()
            return enactment
        }
    }

    func setLastBolusEnactment(_ date: Date?) {
        lock.withLock {
            loadIfNeeded()
            enactment = date
            writeEnactment()
        }
    }

    var insulinRequests: [GarminStoredInsulinRequest] {
        lock.withLock {
            loadIfNeeded()
            return requests
        }
    }

    func saveInsulinRequest(_ request: GarminStoredInsulinRequest) {
        lock.withLock {
            loadIfNeeded()
            if let index = requests.firstIndex(where: { $0.appUUID == request.appUUID && $0.requestID == request.requestID }) {
                requests[index] = request
            } else {
                requests.append(request)
                if requests.count > Self.maximumStoredRequests {
                    requests.removeFirst(requests.count - Self.maximumStoredRequests)
                }
            }
            writeRequests()
        }
    }

    func pruneInsulinRequests(admittedThrough cutoff: Date) {
        lock.withLock {
            loadIfNeeded()
            let kept = requests.filter { $0.admittedAt > cutoff }
            guard kept.count != requests.count else { return }
            requests = kept
            writeRequests()
        }
    }

    // MARK: - Storage

    /// Call with the lock held.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let loadedAt = now()
        var isUnreadable = false

        if defaults.object(forKey: Self.lastBolusEnactmentKey) != nil {
            if let data = defaults.data(forKey: Self.lastBolusEnactmentKey),
               let stored = try? JSONDecoder().decode(StoredEnactment.self, from: data)
            {
                enactment = min(stored.date, loadedAt)
            } else {
                isUnreadable = true
            }
        }
        if defaults.object(forKey: Self.insulinRequestsKey) != nil {
            if let data = defaults.data(forKey: Self.insulinRequestsKey),
               let stored = try? JSONDecoder().decode([GarminStoredInsulinRequest].self, from: data)
            {
                requests = stored
            } else {
                isUnreadable = true
            }
        }

        guard isUnreadable else { return }
        recoveredFromUnreadableData = true
        enactment = loadedAt
        // written back at once, so the next launch starts from readable data and the hold
        // started here does not start again
        writeEnactment()
        writeRequests()
    }

    private func writeEnactment() {
        if let enactment, let data = try? JSONEncoder().encode(StoredEnactment(date: enactment)) {
            defaults.set(data, forKey: Self.lastBolusEnactmentKey)
        } else {
            defaults.removeObject(forKey: Self.lastBolusEnactmentKey)
        }
    }

    private func writeRequests() {
        if let data = try? JSONEncoder().encode(requests) {
            defaults.set(data, forKey: Self.insulinRequestsKey)
        } else {
            defaults.removeObject(forKey: Self.insulinRequestsKey)
        }
    }
}

// MARK: - In memory

/// For tests and previews: the same contract without storage, gone with the instance.
final class GarminCommandMemoryStore: GarminCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var enactment: Date?
    private var requests: [GarminStoredInsulinRequest] = []

    init(lastBolusEnactment: Date? = nil, insulinRequests: [GarminStoredInsulinRequest] = []) {
        enactment = lastBolusEnactment
        requests = insulinRequests
    }

    var lastBolusEnactment: Date? { lock.withLock { enactment } }

    func setLastBolusEnactment(_ date: Date?) {
        lock.withLock { enactment = date }
    }

    var insulinRequests: [GarminStoredInsulinRequest] { lock.withLock { requests } }

    func saveInsulinRequest(_ request: GarminStoredInsulinRequest) {
        lock.withLock {
            if let index = requests.firstIndex(where: { $0.appUUID == request.appUUID && $0.requestID == request.requestID }) {
                requests[index] = request
            } else {
                requests.append(request)
            }
        }
    }

    func pruneInsulinRequests(admittedThrough cutoff: Date) {
        lock.withLock { requests.removeAll { $0.admittedAt <= cutoff } }
    }
}
