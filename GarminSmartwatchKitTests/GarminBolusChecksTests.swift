import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

/// The checks that stand in for Trio's recent-bolus check (which its host skips for a watch
/// bolus): a glucose reading from the last 15 minutes and the 6-minute watch-bolus hold, for every bolus
/// and meal bolus. There is no cap at the host's recommendation.
@MainActor @Suite("Garmin bolus checks") struct GarminBolusChecksTests {
    private let rig: GarminProcessorRig
    private var host: GarminFakeCommandHost { rig.host }

    init() {
        rig = GarminProcessorRig()
    }

    private func process(_ command: GarminWatchCommand) async -> GarminWatchCommandResult {
        await rig.processor.process(rig.request(command))
    }

    /// 0.05 U steps up to 10 U, parsed so 1.05 is the same Double as the literal.
    private static let volumes = (1 ... 200).map { Double("\(Decimal($0) * Decimal(string: "0.05")!)")! }

    private static func units(_ text: String) -> Decimal { Decimal(string: text)! }

    // MARK: - Glucose

    @Test(
        "A bolus needs a glucose reading at most 15 minutes old",
        arguments: [(0, true), (900, true), (901, false), (3600, false)] as [(TimeInterval, Bool)]
    ) func glucoseAge(age: TimeInterval, accepted: Bool) async {
        host.glucoseAge = age

        let result = await process(.bolus(1))

        #expect(result.acknowledged == accepted)
        #expect(host.bolusCalls == (accepted ? [1] : []))
        if !accepted {
            #expect(result == .failure("No recent glucose reading."))
        }
    }

    @Test("Without any glucose reading every watch bolus is refused, nothing sent", arguments: [
        GarminWatchCommand.bolus(1), .mealBolus(carbs: 20, bolus: 1)
    ]) func noGlucose(command: GarminWatchCommand) async {
        host.glucoseAge = nil

        #expect(await process(command) == .failure("No recent glucose reading."))
        #expect(host.calls.isEmpty)
        #expect(rig.logs.lines.contains { $0.contains("no glucose reading in the last 15 minutes") })
    }

    @Test("Glucose is read in the lane: a reading that goes stale while a bolus waits stops it") func glucoseReadInLane() async {
        host.bolusGate = GarminTestGate()
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await rig.processor.process(rig.request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await rig.processor.process(rig.request(.bolus(1))) }
        #expect(await garminEventually { await rig.lane.waitingCount == 1 })
        #expect(host.glucoseReads == 1, "The waiting bolus hasn't read glucose yet")

        host.glucoseAge = nil
        host.bolusGate?.open()
        #expect(await first.value.acknowledged == false)
        #expect(await second.value == .failure("No recent glucose reading."))
        #expect(host.bolusCalls == [2])
    }

    @Test("A held-back bolus doesn't read glucose") func holdBeforeReads() async {
        #expect(await process(.bolus(1)).acknowledged)
        let reads = host.glucoseReads

        #expect(await process(.bolus(1)) == .failure("A bolus was given in the last 6 minutes."))
        #expect(host.glucoseReads == reads)
    }

    @Test("Logs of these refusals carry no amounts") func safeLogging() async {
        _ = await process(.bolus(Self.units("4.56")))
        host.glucoseAge = nil
        _ = await process(.mealBolus(carbs: 78, bolus: Self.units("4.56")))

        for line in rig.logs.lines {
            #expect(!line.contains("4.56") && !line.contains("78"), "\(line)")
        }
    }
}
