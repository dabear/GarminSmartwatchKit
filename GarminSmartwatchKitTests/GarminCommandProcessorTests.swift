import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

/// Covers what the processor decides before and around the host calls: freshness, switches,
/// revocation, limits, deduplication, the insulin lane and the meal sequencing. The host is faked.
@MainActor @Suite("Garmin command processor") struct GarminCommandProcessorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let clock: TestClock
    private let host: FakeHost
    private let authorization: GarminCommandAuthorization
    private let lane: GarminCommandInsulinLane
    private let logs: LogLines
    private let processor: GarminCommandProcessor
    private let appUUID = UUID()

    init() {
        clock = TestClock(start)
        host = FakeHost()
        authorization = GarminCommandAuthorization()
        lane = GarminCommandInsulinLane()
        logs = LogLines()
        var settings = GarminWatchSettings()
        settings.isCommandControlEnabled = true
        settings.isBolusCommandEnabled = true
        host.commandSettings = settings
        processor = GarminCommandProcessor(
            host: host,
            authorization: authorization,
            insulinLane: lane,
            now: { [clock] in clock.now },
            log: { [logs] in logs.record($0) }
        )
    }

    private func request(
        _ command: GarminWatchCommand,
        id: UUID = UUID(),
        app: UUID? = nil,
        age: TimeInterval = 5
    ) -> GarminWatchCommandRequest {
        GarminWatchCommandRequest(requestID: id, appUUID: app ?? appUUID, date: clock.now.addingTimeInterval(-age), command: command)
    }

    /// The way the manager stores settings: the epoch first, then the new value.
    private func changeSettings(_ change: (inout GarminWatchSettings) -> Void) {
        let old = host.commandSettings
        var new = old
        change(&new)
        authorization.settingsWillChange(from: old, to: new)
        host.commandSettings = new
    }

    /// Off and straight back on, as a quick toggle that lands while a command waits.
    private func toggleOffAndOn(bolusSwitch: Bool) {
        if bolusSwitch {
            changeSettings { $0.isBolusCommandEnabled = false }
            changeSettings { $0.isBolusCommandEnabled = true }
        } else {
            changeSettings { $0.isCommandControlEnabled = false }
            changeSettings {
                $0.isCommandControlEnabled = true
                $0.isBolusCommandEnabled = true
            }
        }
    }

    private func preset(_ name: String, id: String) -> TemporaryPreset {
        TemporaryPreset(
            id: id,
            symbol: nil,
            name: name,
            settings: TemporaryPresetSettings(targetRange: nil, insulinNeedsScaleFactor: 1.2),
            duration: .indefinite
        )
    }

    private func running(_ preset: TemporaryPreset) -> TemporaryScheduleOverride {
        TemporaryScheduleOverride(
            context: .preset(preset),
            settings: preset.settings,
            startDate: start,
            duration: .indefinite,
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
    }

    // MARK: - Freshness and switches

    @Test(
        "Only commands within the freshness window run",
        arguments: [(-61.0, false), (-60.0, true), (0.0, true), (120.0, true), (121.0, false)]
    ) func freshnessWindow(age: TimeInterval, accepted: Bool) async {
        let result = await processor.process(request(.carbs(10), age: age))

        #expect(result.acknowledged == accepted)
        #expect(host.calls.count == (accepted ? 1 : 0))
        if !accepted {
            #expect(result.message == "Command expired. Please try again.")
        }
    }

    @Test("Master switch off rejects every command without calling the host") func masterSwitchOff() async {
        host.overrides = [preset("Sport", id: "sport")]
        host.tempTargets = [preset("Walk", id: "walk")]
        changeSettings { $0.isCommandControlEnabled = false }

        let commands: [GarminWatchCommand] = [
            .bolus(1), .carbs(10), .mealBolus(carbs: 10, bolus: 1),
            .activateOverride(name: "Sport"), .cancelOverride,
            .activateTempTarget(name: "Walk"), .cancelTempTarget
        ]
        for command in commands {
            let result = await processor.process(request(command))
            #expect(result == .failure("Watch commands are disabled."))
        }
        #expect(host.calls.isEmpty)
    }

    @Test("Bolus switch off rejects bolus and meal bolus but not carbs") func bolusSwitchOff() async {
        changeSettings { $0.isBolusCommandEnabled = false }

        #expect(await processor.process(request(.bolus(1))) == .failure("Bolus from watch is disabled."))
        #expect(await processor.process(request(.mealBolus(carbs: 10, bolus: 1))) == .failure("Bolus from watch is disabled."))
        #expect(await processor.process(request(.carbs(10))).acknowledged)
        #expect(host.calls.count == 1)
    }

    @Test("A switch the host reports off is enforced even without an epoch change") func switchReadFresh() async {
        // no settingsWillChange: the processor still reads the switch at every check
        host.commandSettings.isBolusCommandEnabled = false

        #expect(await processor.process(request(.bolus(1))).acknowledged == false)
        #expect(host.bolusCalls.isEmpty)
    }

    // MARK: - Authorization epoch

    @Test("Turning a switch off advances the epoch; turning one on does not") func authorizationEpoch() {
        var on = GarminWatchSettings()
        on.isCommandControlEnabled = true
        on.isBolusCommandEnabled = true
        var bolusOff = on
        bolusOff.isBolusCommandEnabled = false
        var masterOff = on
        masterOff.isCommandControlEnabled = false

        let epoch = authorization.current
        authorization.settingsWillChange(from: bolusOff, to: on)
        authorization.settingsWillChange(from: on, to: on)
        #expect(authorization.current == epoch)

        authorization.settingsWillChange(from: on, to: bolusOff)
        #expect(authorization.current == epoch + 1)
        // master off clears bolus too; still one revocation
        authorization.settingsWillChange(from: on, to: masterOff)
        #expect(authorization.current == epoch + 2)
    }

    // MARK: - Carbs

    @Test("Carbs are added with the command date") func carbs() async {
        let request = request(.carbs(42))
        let result = await processor.process(request)

        #expect(result == .success(.carbsLogged, "Carbs logged."))
        #expect(host.calls == [.carbs(42, request.date)])
    }

    @Test("Carbs above the host's maximum are rejected; exactly the maximum is allowed") func maxCarbs() async {
        host.maxCarbs = 50

        #expect(await processor.process(request(.carbs(51))) == .failure("Carbs exceed the maximum allowed."))
        #expect(await processor.process(request(.mealBolus(carbs: 51, bolus: 1))) == .failure("Carbs exceed the maximum allowed."))
        #expect(host.calls.isEmpty)
        #expect(await processor.process(request(.carbs(50))).acknowledged)
    }

    @Test("Without a known maximum only the host checks carbs") func unknownMaxCarbs() async {
        host.maxCarbs = nil
        #expect(await processor.process(request(.carbs(500))).acknowledged)
    }

    @Test(
        "Non-positive amounts are rejected without calling the host",
        arguments: [
            GarminWatchCommand.bolus(0), .bolus(-1), .carbs(0), .carbs(-5),
            .mealBolus(carbs: 0, bolus: 1), .mealBolus(carbs: 10, bolus: 0)
        ]
    ) func nonPositiveAmounts(command: GarminWatchCommand) async {
        let result = await processor.process(request(command))

        #expect(result.acknowledged == false)
        #expect(result.ackCode == .genericFailure)
        #expect(host.calls.isEmpty)
    }

    @Test("Host carb errors map to safe messages") func carbsErrors() async {
        host.carbsError = SmartwatchActionError.exceedsMaximum
        #expect(await processor.process(request(.carbs(10))) == .failure("Carbs exceed the maximum allowed."))

        host.carbsError = SmartwatchActionError.failed("secret 42 g")
        #expect(await processor.process(request(.carbs(10))) == .failure("Could not log carbs."))
    }

    // MARK: - Bolus

    @Test("A bolus is delivered as the units the watch sent") func bolusDelivered() async {
        let result = await processor.process(request(.bolus(2.5)))

        #expect(result == .success(.genericSuccess, "Bolus started."))
        #expect(host.bolusCalls == [2.5])
    }

    @Test("An error that means nothing reached the pump withdraws the lane hold") func nothingReachedPump() async {
        let errors: [SmartwatchActionError] = [
            .notAllowed, .expiredRequest, .invalidAmount, .exceedsMaximum, .exceedsRecommendation,
            .noRecentGlucose, .rateLimited, .dailyLimitReached, .unknownPreset, .inProgress,
            .refusedByHost("secret 4.2 U"), .failed("secret")
        ]
        for error in errors {
            host.bolusErrors = [error]
            let refused = await processor.process(request(.bolus(1)))
            #expect(refused.acknowledged == false)
            #expect(refused.ackCode == .genericFailure)
            #expect(!refused.message.contains("secret"))
            #expect(!refused.message.contains("pump history"), "Nothing reached the pump: \(error)")

            #expect(await processor.process(request(.bolus(1))).acknowledged, "No hold after \(error)")
            clock.advance(by: GarminCommandProcessor.minimumBolusInterval)
        }
    }

    @Test("Host bolus refusals keep their meaning") func bolusErrorMessages() async {
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        #expect(await processor.process(request(.bolus(30))).message == "Bolus exceeds max bolus.")
        host.bolusErrors = [SmartwatchActionError.inProgress]
        #expect(await processor.process(request(.bolus(1))).message == "Another bolus is in progress.")
        host.bolusErrors = [SmartwatchActionError.refusedByHost("max IOB 5 U")]
        #expect(await processor.process(request(.bolus(1))).message == "Bolus refused. No bolus was delivered.")
    }

    @Test(
        "A pump failure, or an unknown error, keeps the lane hold",
        arguments: [true, false]
    ) func pumpFailureKeepsHold(isDeliveryFailed: Bool) async {
        let error: Error = isDeliveryFailed ? SmartwatchActionError.deliveryFailed("secret") : UnexpectedError()
        host.bolusErrors = [error]

        let failed = await processor.process(request(.bolus(2)))
        #expect(failed == .failure("Bolus failed. Check pump history before repeating."))

        let held = await processor.process(request(.bolus(1)))
        #expect(held == .failure("A bolus was given in the last 6 minutes."))
        #expect(host.bolusCalls == [2])
    }

    @Test("A watch bolus holds back the next one for six minutes") func minimumBolusInterval() async {
        #expect(await processor.process(request(.bolus(1))).acknowledged)

        clock.advance(by: GarminCommandProcessor.minimumBolusInterval - 1)
        #expect(await processor.process(request(.bolus(1))).acknowledged == false)
        #expect(await processor.process(request(.mealBolus(carbs: 20, bolus: 1))).ackCode == .partialFailure)
        #expect(logs.lines.contains { $0.contains("previous watch bolus may not be in pump history yet") })

        clock.advance(by: 1)
        #expect(await processor.process(request(.bolus(1))).acknowledged)
        #expect(host.bolusCalls == [1, 1])
    }

    // MARK: - Meal bolus

    @Test("Meal bolus adds carbs before the bolus") func mealBolusOrder() async {
        let request = request(.mealBolus(carbs: 40, bolus: 3))
        let result = await processor.process(request)

        #expect(result == .success(.genericSuccess, "Carbs logged and bolus started."))
        #expect(host.calls == [.carbs(40, request.date), .bolus(3)])
    }

    @Test("A refused meal bolus keeps the carbs and reports a partial failure") func mealBolusRefused() async {
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 30)))

        #expect(result == GarminWatchCommandResult(
            acknowledged: false, ackCode: .partialFailure, message: "Carbs logged. No bolus was delivered."
        ))
    }

    @Test("A pump failure after meal carbs is a partial failure") func mealBolusPumpFailure() async {
        host.bolusErrors = [SmartwatchActionError.deliveryFailed("x")]
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == GarminWatchCommandResult(
            acknowledged: false, ackCode: .partialFailure,
            message: "Carbs logged. Bolus failed, check pump history before repeating."
        ))
    }

    @Test("Failed meal carbs never reach the bolus") func mealCarbsFailure() async {
        host.carbsError = SmartwatchActionError.failed("x")
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == .failure("Could not log carbs. No bolus was delivered."))
        #expect(host.bolusCalls.isEmpty)
    }

    // MARK: - Deduplication

    @Test("A completed duplicate replays its result without executing again") func completedDuplicate() async {
        let request = request(.bolus(1))
        let first = await processor.process(request)
        let replay = await processor.process(request)

        #expect(replay == first)
        #expect(host.bolusCalls == [1])
    }

    @Test("Rejections are cached as terminal results too") func rejectionCached() async {
        changeSettings { $0.isCommandControlEnabled = false }
        let request = request(.carbs(10))
        let first = await processor.process(request)
        changeSettings { $0.isCommandControlEnabled = true }

        #expect(await processor.process(request) == first)
        #expect(host.calls.isEmpty)
    }

    @Test("A duplicate of an in-flight request gets in_progress") func inFlightDuplicate() async {
        host.carbsGate = TestGate()
        let request = request(.carbs(10))
        let pending = Task { await processor.process(request) }
        await host.carbsGate?.waitForArrivals()

        let duplicate = await processor.process(request)
        #expect(duplicate.acknowledged == false)
        #expect(duplicate.ackCode == .inProgress)

        host.carbsGate?.open()
        #expect(await pending.value.acknowledged)
        #expect(host.calls.count == 1)
    }

    @Test("Reusing a request ID for another command is rejected") func conflict() async {
        let id = UUID()
        _ = await processor.process(request(.carbs(10), id: id))
        let result = await processor.process(request(.carbs(20), id: id))

        #expect(result == .failure("Request ID was already used."))
        #expect(host.calls.count == 1)
    }

    @Test("Request IDs are scoped per app") func scopedPerApp() async {
        let id = UUID()
        #expect(await processor.process(request(.carbs(10), id: id)).acknowledged)
        #expect(await processor.process(request(.carbs(10), id: id, app: UUID())).acknowledged)
        #expect(host.calls.count == 2)
    }

    // MARK: - Presets

    @Test("Activating an override uses the exact preset's id") func activateOverride() async {
        host.overrides = [preset("Sport", id: "sport"), preset("Sport ", id: "sport-space")]

        let result = await processor.process(request(.activateOverride(name: "Sport")))

        #expect(result == .success(.overrideStarted, "Override started."))
        #expect(host.calls == [.override("sport")])
    }

    @Test(
        "Missing, ambiguous or differently cased override names are rejected",
        arguments: ["Missing", "Sport", "run"]
    ) func overrideNotUnique(name: String) async {
        host.overrides = [preset("Sport", id: "a"), preset("Sport", id: "b"), preset("Run", id: "run")]

        #expect(await processor.process(request(.activateOverride(name: name))) == .failure("Override preset not found."))
        #expect(host.calls.isEmpty)
    }

    @Test("Cancelling ends the running override or temp target") func cancel() async {
        #expect(await processor.process(request(.cancelOverride)) == .success(.overrideStopped, "Override stopped."))
        #expect(await processor.process(request(.cancelTempTarget)) == .success(.tempTargetStopped, "Temp target stopped."))
        #expect(host.calls == [.override(nil), .tempTarget(nil)])
    }

    @Test("Activating a temp target uses the exact preset's id") func activateTempTarget() async {
        host.tempTargets = [preset("Walk", id: "walk"), preset("walk", id: "lower")]

        #expect(await processor.process(request(.activateTempTarget(name: "Walk"))) == .success(.tempTargetStarted, "Temp target started."))
        #expect(host.calls == [.tempTarget("walk")])
    }

    @Test("Temp target commands fail when the host has no temp targets") func noTempTargets() async {
        host.tempTargets = nil

        #expect(await processor.process(request(.activateTempTarget(name: "Walk"))) == .failure("Temp targets aren't available."))
        #expect(await processor.process(request(.cancelTempTarget)) == .failure("Temp targets aren't available."))
        #expect(host.calls.isEmpty)
    }

    @Test("Host adjustment errors map to safe messages") func adjustmentErrors() async {
        host.overrides = [preset("Sport", id: "sport")]
        host.overrideError = SmartwatchActionError.unknownPreset
        #expect(await processor.process(request(.activateOverride(name: "Sport"))) == .failure("Override preset not found."))

        host.overrideError = SmartwatchActionError.failed("secret")
        #expect(await processor.process(request(.activateOverride(name: "Sport"))) == .failure("Could not start override."))
        #expect(await processor.process(request(.cancelOverride)) == .failure("Could not stop override."))

        host.tempTargetError = SmartwatchActionError.refusedByHost("secret")
        #expect(await processor.process(request(.cancelTempTarget)) == .failure("Could not stop temp target."))
    }

    @Test("Presets are sorted by name and report which one runs") func presetsSorted() async {
        let running = preset("A", id: "upper-a")
        host.overrides = [preset("b", id: "b"), preset("10", id: "10"), running, preset("9", id: "9")]
        host.runningOverride = self.running(running)
        let walk = preset("Walk", id: "walk")
        host.tempTargets = [walk, preset("Eat soon", id: "eat")]
        host.runningTempTarget = self.running(walk)

        let presets = await processor.presets()

        #expect(presets.overridePresets.map(\.name) == ["9", "10", "A", "b"])
        #expect(presets.overridePresets.filter(\.isEnabled).map(\.name) == ["A"])
        #expect(presets.tempTargetPresets == [
            GarminWatchPreset(name: "Eat soon", isEnabled: false),
            GarminWatchPreset(name: "Walk", isEnabled: true)
        ])
    }

    @Test("Presets read with commands off, and report no temp targets for a host without them") func presetsWithoutTempTargets() async {
        changeSettings { $0.isCommandControlEnabled = false }
        host.overrides = [preset("Sport", id: "sport")]
        host.tempTargets = nil

        let presets = await processor.presets()

        #expect(presets.overridePresets == [GarminWatchPreset(name: "Sport", isEnabled: false)])
        #expect(presets.tempTargetPresets.isEmpty)
        #expect(presets.capabilities.isCommandControlEnabled == false)
        #expect(presets.capabilities.isBolusCommandEnabled == false)
    }

    @Test("Capabilities come from the host and the switches") func capabilities() async {
        host.maxBolus = 7.5
        host.maxCarbs = 120
        changeSettings { $0.isBolusCommandEnabled = false }

        let capabilities = await processor.presets().capabilities

        #expect(capabilities == GarminWatchCommandCapabilities(
            isCommandControlEnabled: true,
            isBolusCommandEnabled: false,
            maxBolus: 7.5,
            maxCarbs: 120,
            bolusIncrement: 0
        ))

        host.maxBolus = nil
        host.maxCarbs = nil
        #expect(await processor.presets().capabilities.maxBolus == 0)
        #expect(await processor.presets().capabilities.maxCarbs == 0)
    }

    @Test(
        "The bolus increment is the smallest gap between supported volumes",
        arguments: [
            ([0.05, 0.1, 0.15, 0.2] as [Double], "0.05"),
            ([0, 0.025, 0.05, 0.075, 1.0, 1.05], "0.025"),
            ([0.1, 0.05, 0.1, 0.2], "0.05"),
            ([0.5], "0.5"),
            ([] as [Double], "0")
        ]
    ) func bolusIncrement(volumes: [Double], expected: String) async {
        host.volumes = volumes
        #expect(await processor.presets().capabilities.bolusIncrement == Decimal(string: expected))
    }

    // MARK: - Revocation while waiting

    @Test(
        "A switch toggled off and on while carbs wait for the maximum adds nothing",
        arguments: [false, true]
    ) func carbsRevokedWhileWaiting(isMeal: Bool) async {
        host.maxCarbsGate = TestGate()
        let command: GarminWatchCommand = isMeal ? .mealBolus(carbs: 40, bolus: 3) : .carbs(40)
        let pending = Task { await processor.process(request(command)) }
        await host.maxCarbsGate?.waitForArrivals()

        toggleOffAndOn(bolusSwitch: false)
        host.maxCarbsGate?.open()
        let result = await pending.value

        #expect(result == .failure("Watch command settings changed."), "Nothing was logged, so this is no partial failure")
        #expect(host.calls.isEmpty)
    }

    @Test("A switch toggled while meal carbs are added stops the bolus") func mealRevokedDuringCarbs() async {
        host.carbsGate = TestGate()
        let pending = Task { await processor.process(request(.mealBolus(carbs: 40, bolus: 3))) }
        await host.carbsGate?.waitForArrivals()

        toggleOffAndOn(bolusSwitch: true)
        host.carbsGate?.open()
        let result = await pending.value

        #expect(result.ackCode == .partialFailure)
        #expect(host.bolusCalls.isEmpty)
        #expect(host.calls.count == 1)
    }

    @Test(
        "A switch toggled while an adjustment loads presets stops it",
        arguments: [GarminWatchCommand.activateOverride(name: "Sport"), .activateTempTarget(name: "Walk"), .cancelTempTarget]
    ) func adjustmentRevokedWhileLoading(command: GarminWatchCommand) async {
        host.overrides = [preset("Sport", id: "sport")]
        host.tempTargets = [preset("Walk", id: "walk")]
        host.presetsGate = TestGate()
        let pending = Task { await processor.process(request(command)) }
        await host.presetsGate?.waitForArrivals()

        toggleOffAndOn(bolusSwitch: false)
        host.presetsGate?.open()

        #expect(await pending.value == .failure("Watch command settings changed."))
        #expect(host.calls.isEmpty)
    }

    @Test(
        "A bolus waiting in the lane while a switch is toggled is not delivered",
        arguments: [false, true]
    ) func bolusRevokedInLane(bolusSwitch: Bool) async {
        host.bolusGate = TestGate()
        // the first is refused with nothing delivered, so the lane hold can't be what stops the second
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await processor.process(request(.bolus(1))) }
        #expect(await eventually { await lane.waitingCount == 1 })

        toggleOffAndOn(bolusSwitch: bolusSwitch)
        host.bolusGate?.open()
        #expect(await first.value.acknowledged == false)

        #expect(await second.value == .failure("Watch command settings changed."))
        #expect(host.bolusCalls == [2])
        #expect(await processor.process(request(.bolus(1))).acknowledged, "New commands run under the new settings")
    }

    @Test(
        "A request that expires while it waits in the lane is not delivered",
        arguments: [false, true]
    ) func expiredInLane(isMeal: Bool) async {
        host.bolusGate = TestGate()
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let command: GarminWatchCommand = isMeal ? .mealBolus(carbs: 30, bolus: 1) : .bolus(1)
        let second = Task { await processor.process(request(command, age: GarminCommandProcessor.maximumCommandAge - 10)) }
        #expect(await eventually { await lane.waitingCount == 1 })

        clock.advance(by: 20)
        host.bolusGate?.open()
        #expect(await first.value.acknowledged == false)
        let result = await second.value

        #expect(result.acknowledged == false)
        #expect(result.ackCode == (isMeal ? .partialFailure : .genericFailure))
        #expect(host.bolusCalls == [2])
        #expect(logs.lines.contains { $0.contains("outside the freshness window") })
    }

    @Test("A second insulin request waits for the first, then is held back") func insulinSerialized() async {
        host.bolusGate = TestGate()
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await processor.process(request(.bolus(1))) }
        #expect(await eventually { await lane.waitingCount == 1 }, "Parked while the host delivers the first")
        #expect(host.bolusCalls == [2])

        host.bolusGate?.open()
        #expect(await first.value.acknowledged)
        #expect(await second.value == .failure("A bolus was given in the last 6 minutes."))
        #expect(host.bolusCalls == [2])
    }

    // MARK: - Safe logging

    @Test("Logs and acks never carry amounts or preset names") func safeLogging() async {
        host.overrides = [preset("Secret Sport", id: "sport")]
        _ = await processor.process(request(.bolus(4.25)))
        clock.advance(by: GarminCommandProcessor.minimumBolusInterval)
        _ = await processor.process(request(.mealBolus(carbs: 42, bolus: 3.75)))
        _ = await processor.process(request(.activateOverride(name: "Secret Sport")))
        _ = await processor.process(request(.activateOverride(name: "Secret Missing")))

        #expect(!logs.lines.isEmpty)
        for line in logs.lines {
            #expect(!line.contains("4.25") && !line.contains("42") && !line.contains("3.75") && !line.contains("Secret"), "\(line)")
        }
    }
}

// MARK: - Test doubles

@MainActor private final class FakeHost: GarminCommandHost {
    enum Call: Equatable {
        case bolus(Double)
        case carbs(Double, Date)
        case override(String?)
        case tempTarget(String?)
    }

    var commandSettings = GarminWatchSettings()
    private(set) var calls: [Call] = []

    /// One entry per bolus call, used up in order; `nil` or empty delivers.
    var bolusErrors: [Error?] = []
    var carbsError: Error?
    var overrideError: Error?
    var tempTargetError: Error?

    var overrides: [TemporaryPreset] = []
    var runningOverride: TemporaryScheduleOverride?
    var tempTargets: [TemporaryPreset]? = []
    var runningTempTarget: TemporaryScheduleOverride?
    var maxBolus: Double? = 10
    var maxCarbs: Double? = 100
    var volumes: [Double] = []

    /// Park a call after it was recorded, so the request counts as received by the host.
    var bolusGate: TestGate?
    var carbsGate: TestGate?
    /// Park a read before the processor gets its answer.
    var presetsGate: TestGate?
    var maxCarbsGate: TestGate?

    var bolusCalls: [Double] {
        calls.compactMap { if case let .bolus(units) = $0 { return units } else { return nil } }
    }

    func deliverBolus(_ units: Double) async throws -> Double {
        calls.append(.bolus(units))
        await bolusGate?.pass()
        if !bolusErrors.isEmpty, let error = bolusErrors.removeFirst() {
            throw error
        }
        return units
    }

    func addCarbEntry(_ grams: Double, date: Date) async throws -> Double {
        calls.append(.carbs(grams, date))
        await carbsGate?.pass()
        if let carbsError { throw carbsError }
        return grams
    }

    func enactOverride(_ presetID: String?) async throws {
        if let overrideError { throw overrideError }
        calls.append(.override(presetID))
    }

    func enactTempTarget(_ presetID: String?) async throws {
        if let tempTargetError { throw tempTargetError }
        calls.append(.tempTarget(presetID))
    }

    func overridePresets() async -> [TemporaryPreset] {
        await presetsGate?.pass()
        return overrides
    }

    func activeOverride() async -> TemporaryScheduleOverride? { runningOverride }

    func tempTargetPresets() async -> [TemporaryPreset]? {
        await presetsGate?.pass()
        return tempTargets
    }

    func activeTempTarget() async -> TemporaryScheduleOverride? { runningTempTarget }

    func maximumBolus() async -> Double? { maxBolus }

    func maximumCarbEntry() async -> Double? {
        await maxCarbsGate?.pass()
        return maxCarbs
    }

    func supportedBolusVolumes() async -> [Double] { volumes }
}

/// Parks callers until opened, and lets a test wait until a call arrived.
@MainActor private final class TestGate {
    private var isOpen = false
    private var arrivals = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        arrivals += 1
        let reached = arrivalWaiters.filter { $0.count <= arrivals }
        arrivalWaiters.removeAll { $0.count <= arrivals }
        reached.forEach { $0.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }

    func waitForArrivals(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func record(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

private struct UnexpectedError: Error {}

@MainActor private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
