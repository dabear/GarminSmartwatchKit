import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

/// Covers what the processor decides before and around the host calls: freshness, switches,
/// revocation, limits, deduplication, the insulin lane and the meal sequencing. The host is faked.
@MainActor @Suite("Garmin command processor") struct GarminCommandProcessorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let clock: GarminTestClock
    private let host: GarminFakeCommandHost
    private let authorization: GarminCommandAuthorization
    private let lane: GarminCommandInsulinLane
    private let store: GarminCommandMemoryStore
    private let logs: GarminLogLines
    private let processor: GarminCommandProcessor
    /// The command app of the host's settings below: a Trio watchface with commands on.
    private let appUUID = GarminWatchControls.appUUID!
    private let complicationUUID = GarminWatchface.complication.watchfaceUUID!

    init() {
        clock = GarminTestClock(start)
        host = GarminFakeCommandHost(clock: clock)
        authorization = GarminCommandAuthorization()
        store = GarminCommandMemoryStore()
        lane = GarminCommandInsulinLane(store: store)
        logs = GarminLogLines()
        var settings = GarminWatchSettings()
        settings.watchface = .trio
        settings.isCommandControlEnabled = true
        settings.isBolusCommandEnabled = true
        host.commandSettings = settings
        processor = GarminCommandProcessor(
            host: host,
            authorization: authorization,
            store: store,
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
            #expect(result.message == "Command expired. Nothing was done. Try again.")
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
            #expect(result == .failure("Watch commands are off. Turn them on in the Garmin settings on the phone."))
        }
        #expect(host.calls.isEmpty)
    }

    @Test("Bolus switch off rejects bolus and meal bolus but not carbs") func bolusSwitchOff() async {
        changeSettings { $0.isBolusCommandEnabled = false }

        #expect(await processor.process(request(.bolus(1))) == .failure("Boluses from the watch are off. Turn them on in the Garmin settings on the phone."))
        #expect(await processor.process(request(.mealBolus(carbs: 10, bolus: 1))) == .failure("Boluses from the watch are off. Turn them on in the Garmin settings on the phone."))
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

    @Test("Changing the command app advances the epoch, unless there was none") func commandAppEpoch() {
        func settings(_ watchface: GarminWatchface, commands: Bool) -> GarminWatchSettings {
            var settings = GarminWatchSettings()
            settings.watchface = watchface
            settings.isCommandControlEnabled = commands
            return settings
        }
        let watchControls = settings(.trio, commands: true)
        let complication = settings(.complication, commands: true)
        let none = settings(.trio, commands: false)
        #expect(GarminCommandApp(watchControls) == .watchControls)
        #expect(GarminCommandApp(complication) == .complication)
        #expect(GarminCommandApp(none) == .none)

        let epoch = authorization.current
        authorization.settingsWillChange(from: watchControls, to: complication)
        #expect(authorization.current == epoch + 1, "WatchControls to Complication")
        authorization.settingsWillChange(from: complication, to: watchControls)
        #expect(authorization.current == epoch + 2, "Complication to WatchControls")

        // Complication stays the command app with commands off; the master switch then decides
        authorization.settingsWillChange(from: complication, to: settings(.complication, commands: false))
        #expect(authorization.current == epoch + 3, "Commands turned off still revoke")

        // nothing could be pending without a command app
        authorization.settingsWillChange(from: none, to: watchControls)
        authorization.settingsWillChange(from: none, to: complication)
        #expect(authorization.current == epoch + 3, "From no command app")

        // same command app
        authorization.settingsWillChange(from: watchControls, to: settings(.swissalpine, commands: true))
        authorization.settingsWillChange(from: settings(.complication, commands: false), to: complication)
        #expect(authorization.current == epoch + 3, "The command app stays")
    }

    // MARK: - Command app

    @Test(
        "Only the current command app's commands run",
        arguments: [
            (GarminWatchface.trio, true, false),
            (.swissalpine, true, false),
            (.complication, true, true)
        ]
    ) func onlyCommandApp(watchface: GarminWatchface, sentByComplication: Bool, isAccepted: Bool) async {
        changeSettings { $0.watchface = watchface }
        let sender = sentByComplication ? complicationUUID : appUUID

        let result = await processor.process(request(.carbs(10), app: sender))

        #expect(result.acknowledged == isAccepted)
        #expect(host.calls.count == (isAccepted ? 1 : 0))
        if !isAccepted {
            #expect(result == .failure("Commands are handled by another watch app."))
        }
    }

    @Test("Each command app is refused while the other one is current", arguments: [false, true])
    func bothDirections(complicationIsCurrent: Bool) async {
        changeSettings { $0.watchface = complicationIsCurrent ? .complication : .trio }
        let current = complicationIsCurrent ? complicationUUID : appUUID
        let other = complicationIsCurrent ? appUUID : complicationUUID
        host.overrides = [preset("Sport", id: "sport")]
        let commands: [GarminWatchCommand] = [
            .bolus(1), .carbs(10), .mealBolus(carbs: 10, bolus: 1),
            .activateOverride(name: "Sport"), .cancelOverride, .cancelTempTarget
        ]

        for command in commands {
            let result = await processor.process(request(command, app: other))
            #expect(result == .failure("Commands are handled by another watch app."), "\(command)")
        }
        #expect(host.calls.isEmpty)
        #expect(await processor.process(request(.carbs(10), app: current)).acknowledged)
    }

    @Test("An unknown app is never the command app") func unknownApp() async {
        for watchface in [GarminWatchface.trio, .complication] {
            changeSettings { $0.watchface = watchface }
            #expect(await processor.process(request(.carbs(10), app: UUID())) == .failure("Commands are handled by another watch app."))
        }
        #expect(host.calls.isEmpty)
    }

    @Test("The master switch is reported before the command app; the command app before the bolus switch") func checkOrder() async {
        changeSettings { $0.isBolusCommandEnabled = false }
        #expect(
            await processor.process(request(.bolus(1), app: complicationUUID)) == .failure("Commands are handled by another watch app.")
        )
        #expect(await processor.process(request(.bolus(1))) == .failure("Boluses from the watch are off. Turn them on in the Garmin settings on the phone."))

        changeSettings { $0.isCommandControlEnabled = false }
        #expect(await processor.process(request(.carbs(10), app: complicationUUID)) == .failure("Watch commands are off. Turn them on in the Garmin settings on the phone."))
        #expect(await processor.process(request(.carbs(10))) == .failure("Watch commands are off. Turn them on in the Garmin settings on the phone."))
        #expect(host.calls.isEmpty)
    }

    @Test("With commands off the Complication app is still the command app, and refused by the master switch") func complicationCommandsOff() async {
        changeSettings {
            $0.watchface = .complication
            $0.isCommandControlEnabled = false
        }

        #expect(await processor.process(request(.carbs(10), app: complicationUUID)) == .failure("Watch commands are off. Turn them on in the Garmin settings on the phone."))
        #expect(host.calls.isEmpty)
    }

    @Test("A refusal for the wrong app is cached like any rejection") func wrongAppRejectionCached() async {
        let request = request(.carbs(10), app: complicationUUID)
        let first = await processor.process(request)
        changeSettings { $0.watchface = .complication }

        #expect(await processor.process(request) == first)
        #expect(host.calls.isEmpty)
    }

    @Test("A refusal for the wrong app is logged without amounts") func wrongAppLogged() async {
        _ = await processor.process(request(.bolus(8.88), app: complicationUUID))

        #expect(logs.lines.contains { $0.contains("isn't the command app") })
        #expect(logs.lines.allSatisfy { !$0.contains("8.88") })
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

        #expect(await processor.process(request(.carbs(51))) == .failure("Carbs are above the maximum carb entry. Nothing was logged."))
        #expect(await processor.process(request(.mealBolus(carbs: 51, bolus: 1))) == .failure("Carbs are above the maximum carb entry. Nothing was logged."))
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
        #expect(await processor.process(request(.carbs(10))) == .failure("Carbs are above the maximum carb entry. Nothing was logged."))

        host.carbsError = SmartwatchActionError.failed("secret 42 g")
        #expect(await processor.process(request(.carbs(10))) == .failure("Couldn't log carbs."))
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
        #expect(await processor.process(request(.bolus(30))).message == "Bolus is above the maximum bolus. No bolus was delivered.")
        host.bolusErrors = [SmartwatchActionError.inProgress]
        #expect(await processor.process(request(.bolus(1))).message == "Another bolus is in progress. No bolus was delivered.")
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
        #expect(held == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No bolus was delivered."))
        #expect(host.bolusCalls == [2])
    }

    @Test("A watch bolus holds back the next one for six minutes") func minimumBolusInterval() async {
        #expect(await processor.process(request(.bolus(1))).acknowledged)

        clock.advance(by: GarminCommandProcessor.minimumBolusInterval - 1)
        #expect(await processor.process(request(.bolus(1))).acknowledged == false)
        #expect(await processor.process(request(.mealBolus(carbs: 20, bolus: 1))) == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No carbs or bolus were logged."))
        #expect(host.carbCalls.isEmpty, "The hold is checked before the carbs")
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
        // under the maximum the plugin knows, so the host is asked after the carbs and refuses
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == GarminWatchCommandResult(
            acknowledged: false, ackCode: .partialFailure, message: "Carbs logged. Bolus is above the maximum bolus. No bolus was delivered."
        ))
    }

    @Test("A pump failure after meal carbs is a partial failure") func mealBolusPumpFailure() async {
        host.bolusErrors = [SmartwatchActionError.deliveryFailed("x")]
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == GarminWatchCommandResult(
            acknowledged: false, ackCode: .partialFailure,
            message: "Carbs logged. Bolus failed. Check pump history before repeating."
        ))
    }

    @Test("Failed meal carbs never reach the bolus") func mealCarbsFailure() async {
        host.carbsError = SmartwatchActionError.failed("x")
        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == .failure("Couldn't log carbs. No bolus was delivered."))
        #expect(host.bolusCalls.isEmpty)
    }

    @Test("A meal bolus above the maximum bolus, or without a pump, adds no carbs")
    func mealBolusMaximumOrNoPumpAddsNoCarbs() async {
        host.maxBolus = 2
        #expect(await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))
            == .failure("Bolus is above the maximum bolus. No carbs or bolus were logged."))
        host.maxBolus = 10
        host.volumes = []
        #expect(await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))
            == .failure("No pump. No carbs or bolus were logged."))
        #expect(host.calls.isEmpty)
    }

    @Test("A clock turned back after a watch bolus holds for at most the interval from then")
    func clockTurnedBackInSession() async {
        #expect(await processor.process(request(.bolus(1))).acknowledged)
        clock.advance(by: -3600)
        #expect(await processor.process(request(.bolus(1))).acknowledged == false, "Held: the bolus may be recent")
        clock.advance(by: GarminCommandProcessor.minimumBolusInterval)
        #expect(await processor.process(request(.bolus(1))).acknowledged, "Not held for the hour the clock went back")
    }

    @Test("A meal bolus held back by the hold adds no carbs, and a resend adds none either") func mealBolusHoldAddsNoCarbs() async {
        #expect(await processor.process(request(.bolus(1))).acknowledged)
        clock.advance(by: 60)

        let meal = request(.mealBolus(carbs: 40, bolus: 3))
        let refused = await processor.process(meal)
        #expect(refused == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No carbs or bolus were logged."), "Nothing logged, so no partial failure")
        #expect(await processor.process(meal) == refused)
        #expect(await processor.process(request(.mealBolus(carbs: 40, bolus: 3))) == refused)
        #expect(host.carbCalls.isEmpty)
        #expect(host.bolusCalls == [1])
    }

    @Test("A meal bolus without recent glucose adds no carbs", arguments: [nil, 15 * 60 + 1] as [TimeInterval?])
    func mealBolusStaleGlucoseAddsNoCarbs(glucoseAge: TimeInterval?) async {
        host.glucoseAge = glucoseAge

        let result = await processor.process(request(.mealBolus(carbs: 40, bolus: 3)))

        #expect(result == .failure("No glucose reading in the last 15 minutes. No carbs or bolus were logged."))
        #expect(host.calls.isEmpty)
    }

    @Test("A meal bolus refused before its carbs leaves no hold behind") func mealBolusRefusedBeforeCarbsNoHold() async {
        host.glucoseAge = nil
        #expect(await processor.process(request(.mealBolus(carbs: 40, bolus: 3))).acknowledged == false)

        host.glucoseAge = 60
        #expect(await processor.process(request(.bolus(1))).acknowledged)
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
        host.carbsGate = GarminTestGate()
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

        #expect(result == .failure("This request was already used. Nothing was done."))
        #expect(host.calls.count == 1)
    }

    @Test("Request IDs are scoped per app") func scopedPerApp() async {
        let id = UUID()
        #expect(await processor.process(request(.carbs(10), id: id)).acknowledged)
        // only the command app runs commands, so the other app becomes it
        changeSettings { $0.watchface = .complication }
        #expect(await processor.process(request(.carbs(10), id: id, app: complicationUUID)).acknowledged)
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

        #expect(await processor.process(request(.activateTempTarget(name: "Walk"))) == .failure("This app has no temp targets."))
        #expect(await processor.process(request(.cancelTempTarget)) == .failure("This app has no temp targets."))
        #expect(host.calls.isEmpty)
    }

    @Test("Host adjustment errors map to safe messages") func adjustmentErrors() async {
        host.overrides = [preset("Sport", id: "sport")]
        host.overrideError = SmartwatchActionError.unknownPreset
        #expect(await processor.process(request(.activateOverride(name: "Sport"))) == .failure("Override preset not found."))

        host.overrideError = SmartwatchActionError.failed("secret")
        #expect(await processor.process(request(.activateOverride(name: "Sport"))) == .failure("Couldn't start override."))
        #expect(await processor.process(request(.cancelOverride)) == .failure("Couldn't stop override."))

        host.tempTargetError = SmartwatchActionError.refusedByHost("secret")
        #expect(await processor.process(request(.cancelTempTarget)) == .failure("Couldn't stop temp target."))
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
            bolusIncrement: 0.05
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
            ([] as [Double], "0.05")
        ]
    ) func bolusIncrement(volumes: [Double], expected: String) async {
        host.volumes = volumes
        #expect(await processor.presets().capabilities.bolusIncrement == Decimal(string: expected))
    }

    @Test("Without supported volumes (no pump) bolus is reported off, with a non-zero increment")
    func noPumpCapabilities() async {
        host.volumes = []
        #expect(await processor.presets().capabilities.isBolusCommandEnabled == false)
        #expect(await processor.presets().capabilities.bolusIncrement == 0.05)
        host.volumes = [0.05, 0.1]
        #expect(await processor.presets().capabilities.isBolusCommandEnabled == true)
    }

    // MARK: - Revocation while waiting

    @Test(
        "A switch toggled off and on while carbs wait for the maximum adds nothing",
        arguments: [false, true]
    ) func carbsRevokedWhileWaiting(isMeal: Bool) async {
        host.maxCarbsGate = GarminTestGate()
        let command: GarminWatchCommand = isMeal ? .mealBolus(carbs: 40, bolus: 3) : .carbs(40)
        let pending = Task { await processor.process(request(command)) }
        await host.maxCarbsGate?.waitForArrivals()

        toggleOffAndOn(bolusSwitch: false)
        host.maxCarbsGate?.open()
        let result = await pending.value

        #expect(result == .failure("Command settings changed on the phone. Nothing was done."), "Nothing was logged, so this is no partial failure")
        #expect(host.calls.isEmpty)
    }

    @Test(
        "Switching the watchface to another command app while carbs wait adds nothing",
        arguments: [(GarminWatchface.trio, GarminWatchface.complication), (.complication, .trio), (.swissalpine, .complication)]
    ) func carbsRevokedByWatchface(from: GarminWatchface, to: GarminWatchface) async {
        changeSettings { $0.watchface = from }
        let sender = GarminCommandApp(host.commandSettings).appUUID!
        host.maxCarbsGate = GarminTestGate()
        let pending = Task { await processor.process(request(.carbs(40), app: sender)) }
        await host.maxCarbsGate?.waitForArrivals()

        changeSettings { $0.watchface = to }
        host.maxCarbsGate?.open()

        #expect(await pending.value == .failure("Command settings changed on the phone. Nothing was done."))
        #expect(host.calls.isEmpty)
    }

    @Test("A watchface switch that keeps the command app does not revoke a waiting command") func watchfaceSwitchKeepsCommandApp() async {
        host.maxCarbsGate = GarminTestGate()
        let pending = Task { await processor.process(request(.carbs(40))) }
        await host.maxCarbsGate?.waitForArrivals()

        changeSettings { $0.watchface = .swissalpine }
        host.maxCarbsGate?.open()

        #expect(await pending.value.acknowledged)
        #expect(host.calls.count == 1)
    }

    @Test("A command that waits while the watchface is switched away and back is still revoked") func watchfaceRoundTrip() async {
        host.maxCarbsGate = GarminTestGate()
        let pending = Task { await processor.process(request(.carbs(40))) }
        await host.maxCarbsGate?.waitForArrivals()

        changeSettings { $0.watchface = .complication }
        changeSettings { $0.watchface = .trio }
        host.maxCarbsGate?.open()

        #expect(await pending.value == .failure("Command settings changed on the phone. Nothing was done."))
        #expect(host.calls.isEmpty)
    }

    @Test("A bolus waiting in the lane when the watchface is switched is not delivered") func bolusRevokedByWatchface() async {
        host.bolusGate = GarminTestGate()
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await processor.process(request(.bolus(1))) }
        #expect(await garminEventually { await lane.waitingCount == 1 })

        changeSettings { $0.watchface = .complication }
        host.bolusGate?.open()
        #expect(await first.value.acknowledged == false)

        #expect(await second.value == .failure("Command settings changed on the phone. Nothing was done."))
        #expect(host.bolusCalls == [2])
        #expect(
            await processor.process(request(.bolus(1))) == .failure("Commands are handled by another watch app."),
            "The old command app stays refused"
        )
        #expect(await processor.process(request(.bolus(1), app: complicationUUID)).acknowledged)
        #expect(host.bolusCalls == [2, 1])
    }

    @Test("A switch toggled while meal carbs are added stops the bolus") func mealRevokedDuringCarbs() async {
        host.carbsGate = GarminTestGate()
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
        host.presetsGate = GarminTestGate()
        let pending = Task { await processor.process(request(command)) }
        await host.presetsGate?.waitForArrivals()

        toggleOffAndOn(bolusSwitch: false)
        host.presetsGate?.open()

        #expect(await pending.value == .failure("Command settings changed on the phone. Nothing was done."))
        #expect(host.calls.isEmpty)
    }

    @Test(
        "A bolus waiting in the lane while a switch is toggled is not delivered",
        arguments: [false, true]
    ) func bolusRevokedInLane(bolusSwitch: Bool) async {
        host.bolusGate = GarminTestGate()
        // the first is refused with nothing delivered, so the lane hold can't be what stops the second
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await processor.process(request(.bolus(1))) }
        #expect(await garminEventually { await lane.waitingCount == 1 })

        toggleOffAndOn(bolusSwitch: bolusSwitch)
        host.bolusGate?.open()
        #expect(await first.value.acknowledged == false)

        #expect(await second.value == .failure("Command settings changed on the phone. Nothing was done."))
        #expect(host.bolusCalls == [2])
        #expect(await processor.process(request(.bolus(1))).acknowledged, "New commands run under the new settings")
    }

    @Test(
        "A request that expires while it waits in the lane is not delivered",
        arguments: [false, true]
    ) func expiredInLane(isMeal: Bool) async {
        // parked before its enactment is recorded, so a meal's pre-checks see no hold and its
        // carbs are added before it waits in the lane
        host.firstGlucoseGate = GarminTestGate()
        host.bolusErrors = [SmartwatchActionError.exceedsMaximum]
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.firstGlucoseGate?.waitForArrivals()
        let command: GarminWatchCommand = isMeal ? .mealBolus(carbs: 30, bolus: 1) : .bolus(1)
        let second = Task { await processor.process(request(command, age: GarminCommandProcessor.maximumCommandAge - 10)) }
        #expect(await garminEventually { await lane.waitingCount == 1 })
        #expect(host.carbCalls.count == (isMeal ? 1 : 0))

        clock.advance(by: 20)
        host.firstGlucoseGate?.open()
        #expect(await first.value.acknowledged == false)
        let result = await second.value

        #expect(result.acknowledged == false)
        #expect(result.ackCode == (isMeal ? .partialFailure : .genericFailure))
        #expect(host.bolusCalls == [2])
        #expect(logs.lines.contains { $0.contains("outside the freshness window") })
    }

    @Test("A second insulin request waits for the first, then is held back") func insulinSerialized() async {
        host.bolusGate = GarminTestGate()
        let first = Task { await processor.process(request(.bolus(2))) }
        await host.bolusGate?.waitForArrivals()
        let second = Task { await processor.process(request(.bolus(1))) }
        #expect(await garminEventually { await lane.waitingCount == 1 }, "Parked while the host delivers the first")
        #expect(host.bolusCalls == [2])

        host.bolusGate?.open()
        #expect(await first.value.acknowledged)
        #expect(await second.value == .failure("Too soon after the previous watch bolus. Check pump history and wait 6 minutes. No bolus was delivered."))
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

@MainActor final class GarminFakeCommandHost: GarminCommandHost {
    enum Call: Equatable {
        case bolus(Double)
        case carbs(Double, Date)
        case override(String?)
        case tempTarget(String?)
    }

    var commandSettings = GarminWatchSettings()
    private(set) var calls: [Call] = []
    private let clock: GarminTestClock

    init(clock: GarminTestClock) {
        self.clock = clock
    }

    /// Age of the newest glucose reading on the test clock; `nil`: none.
    var glucoseAge: TimeInterval? = 60
    /// Generous by default, so only tests about it reach it.
    private(set) var glucoseReads = 0

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
    var volumes: [Double] = [0.05, 0.1, 0.15]

    /// Park a call after it was recorded, so the request counts as received by the host.
    var bolusGate: GarminTestGate?
    var carbsGate: GarminTestGate?
    /// Park a read before the processor gets its answer.
    var presetsGate: GarminTestGate?
    var maxCarbsGate: GarminTestGate?
    var firstGlucoseGate: GarminTestGate?

    var bolusCalls: [Double] {
        calls.compactMap { if case let .bolus(units) = $0 { return units } else { return nil } }
    }

    var carbCalls: [Double] {
        calls.compactMap { if case let .carbs(grams, _) = $0 { return grams } else { return nil } }
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

    func latestGlucoseDate() async -> Date? {
        glucoseReads += 1
        // parks only the first read, so a later command's pre-checks aren't held behind it
        if glucoseReads == 1 { await firstGlucoseGate?.pass() }
        return glucoseAge.map { clock.now.addingTimeInterval(-$0) }
    }
}

/// Parks callers until opened, and lets a test wait until a call arrived.
@MainActor final class GarminTestGate {
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

final class GarminTestClock: @unchecked Sendable {
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

final class GarminLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func record(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

private struct UnexpectedError: Error {}

@MainActor func garminEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// A processor over a fake host with watch commands and bolus on, for suites in other files.
/// `relaunched()` is a new processor (new cache, lane and authorization) on the same store, host
/// and clock, as after an app relaunch.
@MainActor struct GarminProcessorRig {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let appUUID = GarminWatchControls.appUUID!

    let clock: GarminTestClock
    let host: GarminFakeCommandHost
    let store: GarminCommandStore
    let logs: GarminLogLines
    let lane: GarminCommandInsulinLane
    let processor: GarminCommandProcessor

    init(store: GarminCommandStore = GarminCommandMemoryStore(), clock: GarminTestClock = GarminTestClock(start), host: GarminFakeCommandHost? = nil) {
        self.clock = clock
        self.store = store
        let logs = GarminLogLines()
        self.logs = logs
        let host = host ?? {
            let host = GarminFakeCommandHost(clock: clock)
            var settings = GarminWatchSettings()
            settings.watchface = .trio
            settings.isCommandControlEnabled = true
            settings.isBolusCommandEnabled = true
            host.commandSettings = settings
            return host
        }()
        self.host = host
        let lane = GarminCommandInsulinLane(store: store)
        self.lane = lane
        processor = GarminCommandProcessor(
            host: host,
            authorization: GarminCommandAuthorization(),
            store: store,
            insulinLane: lane,
            now: { [clock] in clock.now },
            log: { [logs] in logs.record($0) }
        )
    }

    func relaunched() -> GarminProcessorRig {
        GarminProcessorRig(store: store, clock: clock, host: host)
    }

    func request(_ command: GarminWatchCommand, id: UUID = UUID(), age: TimeInterval = 5) -> GarminWatchCommandRequest {
        GarminWatchCommandRequest(requestID: id, appUUID: Self.appUUID, date: clock.now.addingTimeInterval(-age), command: command)
    }
}
