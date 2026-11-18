//
//  GarminSmartwatchManager+BolusChecks.swift
//  GarminSmartwatchKit
//
//  The host reads behind the watch bolus checks (`GarminCommandProcessor`).
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
        return samples?.map(\.startDate).max()
    }

    /// The host's recommendation now with no carbs added (carbs the watch just added count).
    /// Throws `SmartwatchActionError.notAllowed` without a delegate, and whatever the host throws.
    @MainActor func recommendedBolus() async throws -> Double {
        guard let delegate = smartwatchManagerDelegate else { throw SmartwatchActionError.notAllowed }
        return try await delegate.smartwatchManager(self, recommendBolusForCarbs: 0, absorptionTime: nil)
    }
}
