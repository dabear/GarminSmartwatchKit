//
//  GarminSmartwatchManager+BolusChecks.swift
//  GarminSmartwatchKit
//
//  The host read behind the watch bolus glucose check (`GarminCommandProcessor`).
//

import Foundation
import LoopKit

extension GarminSmartwatchManager {
    /// When the newest glucose reading of the last `GarminCommandProcessor.maximumGlucoseAge` was
    /// taken, CGM or entered; `nil` when there is none, no delegate, or the read failed.
    @MainActor func latestGlucoseDate() async -> Date? {
        guard let delegate = smartwatchManagerDelegate else { return nil }
        let since = Date(timeIntervalSinceNow: -GarminCommandProcessor.maximumGlucoseAge)
        let samples = try? await delegate.smartwatchManager(self, glucoseSamplesSince: since)
        // A reading dated ahead (another app's clock) would look fresh for as long as it is
        // ahead; up to a minute is clock skew. Manual and display-only readings count, as in Luped.
        let latest = Date(timeIntervalSinceNow: 60)
        return samples?.map(\.startDate).filter { $0 <= latest }.max()
    }
}
