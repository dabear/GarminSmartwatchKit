import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

/// The checks that stand in for Trio's recent-bolus check (which its host skips for a watch
/// bolus): recent glucose and the host's recommendation, for every bolus and meal bolus.
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

    // MARK: - Recommendation

    @Test(
        "The units, rounded down to a supported volume, may not exceed the recommendation rounded the same way",
        arguments: [
            ("1.0", 1.02, true),
            ("1.04", 1.02, true), // rounds to 1.0
            ("1.05", 1.02, false),
            ("1.1", 1.02, false),
            ("0.97", 0.98, true), // both round to 0.95
            ("1.0", 0.98, false)
        ] as [(String, Double, Bool)]
    ) func recommendationWithVolumes(requested: String, recommendation: Double, accepted: Bool) async {
        host.volumes = Self.volumes
        host.recommendation = recommendation

        let result = await process(.bolus(Self.units(requested)))

        #expect(result.acknowledged == accepted, "\(requested) U against \(recommendation) U")
        #expect(host.bolusCalls.count == (accepted ? 1 : 0))
        if !accepted {
            #expect(result == .failure("Bolus exceeds the recommendation."))
        }
    }

    @Test(
        "Without volumes the raw amounts are compared, with a 0.0001 U tolerance",
        arguments: [("1", true), ("1.00005", true), ("1.00009", true), ("1.0002", false), ("2", false)] as [(String, Bool)]
    ) func recommendationTolerance(requested: String, accepted: Bool) async {
        host.recommendation = 1

        #expect(await process(.bolus(Self.units(requested))).acknowledged == accepted, "\(requested) U")
    }

    @Test("Nothing is allowed when the host recommends 0 U or less", arguments: [0.0, -0.5, .nan] as [Double])
    func noRecommendation(recommendation: Double) async {
        host.recommendation = recommendation

        #expect(await process(.bolus(Self.units("0.05"))) == .failure("Bolus exceeds the recommendation."))
        #expect(host.bolusCalls.isEmpty)
        #expect(rig.logs.lines.contains { $0.contains("above the host's recommendation") })
    }

    @Test(
        "A recommendation the host can't give refuses the bolus, nothing sent, no hold",
        arguments: [
            (SmartwatchActionError.refusedByHost("secret 3 U"), "Bolus refused. No bolus was delivered."),
            (.notAllowed, "Not allowed from the watch."),
            (.failed("secret"), "Bolus refused. No bolus was delivered.")
        ] as [(SmartwatchActionError, String)]
    ) func recommendationThrows(error: SmartwatchActionError, message: String) async {
        host.recommendationError = error

        #expect(await process(.bolus(1)) == .failure(message))
        #expect(host.bolusCalls.isEmpty)
        #expect(rig.logs.lines.allSatisfy { !$0.contains("secret") && !$0.contains("3 U") })

        host.recommendationError = nil
        #expect(await process(.bolus(1)).acknowledged, "Nothing was handed to the host, so no hold")
    }

    @Test("A meal bolus is checked against the recommendation read after its carbs, with 0 g") func mealRecommendationAfterCarbs() async {
        // recommends nothing before the carbs and 4 U with 40 g
        host.recommendation = 0
        host.recommendationPerGram = 0.1

        let result = await process(.mealBolus(carbs: 40, bolus: 3))

        #expect(result == .success(.genericSuccess, "Carbs logged and bolus started."))
        #expect(host.recommendationReads == [1], "Read once, with the carbs already added")
        #expect(host.carbCalls == [40])
        #expect(host.bolusCalls == [3])
    }

    @Test("A meal bolus above the recommendation with its carbs keeps the carbs") func mealAboveRecommendation() async {
        host.recommendation = 0
        host.recommendationPerGram = 0.1

        let result = await process(.mealBolus(carbs: 20, bolus: 3))

        #expect(result == GarminWatchCommandResult(acknowledged: false, ackCode: .partialFailure, message: "Carbs logged. No bolus was delivered."))
        #expect(host.carbCalls == [20])
        #expect(host.bolusCalls.isEmpty)
    }

    @Test("A held-back bolus reads neither glucose nor the recommendation") func holdBeforeReads() async {
        #expect(await process(.bolus(1)).acknowledged)
        let reads = (host.glucoseReads, host.recommendationReads.count)

        #expect(await process(.bolus(1)) == .failure("A bolus was given in the last 6 minutes."))
        #expect(host.glucoseReads == reads.0)
        #expect(host.recommendationReads.count == reads.1)
    }

    @Test("Logs of these refusals carry no amounts") func safeLogging() async {
        host.recommendation = 1.23
        _ = await process(.bolus(Self.units("4.56")))
        host.glucoseAge = nil
        _ = await process(.mealBolus(carbs: 78, bolus: Self.units("4.56")))

        for line in rig.logs.lines {
            #expect(!line.contains("1.23") && !line.contains("4.56") && !line.contains("78"), "\(line)")
        }
    }

    // MARK: - Rounding

    @Test("Rounding goes down to the largest supported volume, and leaves amounts alone without volumes")
    func rounding() {
        #expect(GarminCommandProcessor.roundToSupportedVolume(1.04, volumes: Self.volumes) == 1.0)
        #expect(GarminCommandProcessor.roundToSupportedVolume(0.04, volumes: Self.volumes) == 0)
        #expect(GarminCommandProcessor.roundToSupportedVolume(1.04, volumes: []) == 1.04)
        #expect(GarminCommandProcessor.isWithinRecommendation(.infinity, recommendation: 5, volumes: []) == false)
        #expect(GarminCommandProcessor.isWithinRecommendation(1, recommendation: .infinity, volumes: []) == false)
    }
}
