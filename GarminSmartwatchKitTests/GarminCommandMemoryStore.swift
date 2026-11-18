import Foundation

@testable import GarminSmartwatchKit

/// For tests: the same contract without storage, gone with the instance.
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
