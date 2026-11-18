//
//  GarminCommandProcessor.swift
//  GarminSmartwatchKit
//
//  From Tai's WatchCommandProcessor (mountrcg/Tai, MIT), for the plugin.
//

import Foundation
import LoopKit

/// Validates and executes watch commands independent of the transport that delivered them.
protocol GarminCommandProcessing {
    /// Runs `request` at most once per app and request ID and returns its terminal result;
    /// a duplicate gets the cached result back without executing again.
    func process(_ request: GarminWatchCommandRequest) async -> GarminWatchCommandResult

    /// Override and temp target presets, sorted by display name, with the current command switches
    /// and limits.
    func presets() async -> GarminWatchCommandPresets
}

/// The host side, implemented by GarminSmartwatchManager over its SmartwatchManagerDelegate.
@MainActor protocol GarminCommandHost: AnyObject {
    /// Read fresh at every check.
    var commandSettings: GarminWatchSettings { get }
    /// Throws `SmartwatchActionError`; `.deliveryFailed` is the only one that may mean the pump was asked.
    func deliverBolus(_ units: Double) async throws -> Double
    func addCarbEntry(_ grams: Double, date: Date) async throws -> Double
    /// `nil` ends the running override.
    func enactOverride(_ presetID: String?) async throws
    /// `nil` ends the running temp target.
    func enactTempTarget(_ presetID: String?) async throws
    func overridePresets() async -> [TemporaryPreset]
    func activeOverride() async -> TemporaryScheduleOverride?
    /// `nil`: host has no temp targets (Loop).
    func tempTargetPresets() async -> [TemporaryPreset]?
    func activeTempTarget() async -> TemporaryScheduleOverride?
    func maximumBolus() async -> Double?
    func maximumCarbEntry() async -> Double?
    func supportedBolusVolumes() async -> [Double]
    /// When the newest stored glucose reading was taken; `nil` when there is none recent or it
    /// can't be read.
    func latestGlucoseDate() async -> Date?
}

/// Revocation epoch for watch commands; a command admitted under an older epoch was revoked.
///
/// Advanced synchronously before a command switch that turns off is stored, so an off-then-on
/// sequence that lands while a command is suspended still revokes it.
final class GarminCommandAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    var current: UInt64 { lock.withLock { epoch } }

    /// Call before `new` is stored. Turning either switch off always revokes, even when it is
    /// switched back on right after; turning one on never does.
    func settingsWillChange(from old: GarminWatchSettings, to new: GarminWatchSettings) {
        let masterTurnedOff = old.isCommandControlEnabled && !new.isCommandControlEnabled
        let bolusTurnedOff = old.isBolusCommandEnabled && !new.isBolusCommandEnabled
        // With no command app before, nothing could be pending.
        let oldCommandApp = GarminCommandApp(old)
        let commandAppChanged = oldCommandApp != .none && oldCommandApp != GarminCommandApp(new)
        guard masterTurnedOff || bolusTurnedOff || commandAppChanged else { return }
        lock.withLock { epoch += 1 }
    }
}

/// Admits one watch insulin command at a time across all request IDs, so each one sees the
/// previous command's delivery. Waiters suspend on a continuation and never hold the actor.
///
/// Once a watch bolus was handed to the host, the next watch insulin command is rejected for
/// `GarminCommandProcessor.minimumBolusInterval`, even when the pump refused it, since pump history
/// may not show it yet and a refusal can still mean partial delivery. Only an error that means
/// nothing reached the pump withdraws the record.
///
/// The record lives in a `GarminCommandStore`, so the hold outlasts an app relaunch.
actor GarminCommandInsulinLane {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let store: GarminCommandStore

    init(store: GarminCommandStore = GarminCommandDefaultsStore.standard) {
        self.store = store
    }

    /// Last bolus handed to the host through a lane, in this launch or an earlier one; pump
    /// history may not show it yet.
    var lastEnactment: Date? { store.lastBolusEnactment }

    var waitingCount: Int { waiters.count }

    func enter() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lane straight to the next waiter, so no newcomer can slip in between.
    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Stored before the host is called.
    func recordEnactment(at date: Date) {
        store.setLastBolusEnactment(date)
    }

    /// Puts back what `recordEnactment(at: recorded)` replaced when the request never reached the
    /// pump; a newer record (another lane on the same store) stays.
    func restoreEnactment(_ previous: Date?, replacing recorded: Date) {
        guard store.lastBolusEnactment == recorded else { return }
        store.setLastBolusEnactment(previous)
    }
}

/// Checks and runs the watch apps' commands against the host.
///
/// Every side effect is preceded by a final check (freshness for insulin, revocation epoch and
/// switches) with no `await` between the check and the host call; both run on the main actor.
///
/// Tai also ran Trio's 20% recent-bolus check before each watch bolus. The host deliberately
/// offers no such check: Trio's host skips it for watch boluses and relies on the plugin
/// instead, as for Luped. What stands in for it here, for every bolus and meal bolus, inside the
/// insulin lane right before the final check:
/// - the newest glucose reading is at most `maximumGlucoseAge` old;
/// - the `minimumBolusInterval` hold, kept across relaunches.
/// There is no forced bolus. Maximum bolus, maximum IOB, maximum carbs and rounding are the
/// host's.
///
/// A meal bolus is checked for everything that can be known before its carbs are added (freshness,
/// switches, the hold, glucose age) before they are, so a refused one adds nothing and a resend
/// can't log the carbs twice.
@MainActor final class GarminCommandProcessor: GarminCommandProcessing {
    /// The watch talks to the phone directly over Bluetooth and a command arrives within seconds,
    /// so two minutes only keeps a late or replayed command from executing long after it was confirmed.
    static let maximumCommandAge: TimeInterval = 2 * 60
    /// Clock skew tolerance for watches that run slightly ahead of the phone.
    static let maximumCommandLead: TimeInterval = 60
    /// How long a watch bolus handed to the host holds back the next watch insulin command.
    static let minimumBolusInterval: TimeInterval = 6 * 60
    /// A watch bolus needs a glucose reading at most this old (Luped's limit); on the watch the
    /// user may not see that glucose is missing.
    static let maximumGlucoseAge: TimeInterval = 15 * 60

    /// Weak: the host owns the processor.
    private weak var host: GarminCommandHost?
    private let authorization: GarminCommandAuthorization
    private let cache: GarminCommandRequestCache
    private let insulinLane: GarminCommandInsulinLane
    private let now: () -> Date
    private let log: (String) -> Void

    /// `cache` and `insulinLane` default to ones over `store`, which defaults to the plugin's
    /// `UserDefaults` store.
    init(
        host: GarminCommandHost,
        authorization: GarminCommandAuthorization,
        store: GarminCommandStore = GarminCommandDefaultsStore.standard,
        cache: GarminCommandRequestCache? = nil,
        insulinLane: GarminCommandInsulinLane? = nil,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.host = host
        self.authorization = authorization
        self.cache = cache ?? GarminCommandRequestCache(store: store)
        self.insulinLane = insulinLane ?? GarminCommandInsulinLane(store: store)
        self.now = now
        self.log = log
    }

    func process(_ request: GarminWatchCommandRequest) async -> GarminWatchCommandResult {
        let key = GarminCommandRequestCache.Key(appUUID: request.appUUID, requestID: request.requestID)
        let name = request.command.name
        let grant = authorization.current

        let ticket: GarminCommandRequestCache.Ticket
        switch await cache.admit(key, command: request.command, now: now()) {
        case let .accepted(admitted):
            ticket = admitted
        case let .completed(result):
            log("Garmin: duplicate \(name) request - returning cached result")
            return result
        case .interrupted:
            log("Garmin: duplicate \(name) request from before the app restarted, outcome unknown - rejected")
            return .failure(GarminCommandMessage.interrupted)
        case .inProgress:
            log("Garmin: duplicate \(name) request still in progress - rejected")
            return GarminWatchCommandResult(acknowledged: false, ackCode: .inProgress, message: GarminCommandMessage.inProgress)
        case .conflict:
            log("Garmin: request ID reused for a different command (\(name)) - rejected")
            return .failure(GarminCommandMessage.requestIDReused)
        case .full:
            log("Garmin: too many \(name) requests in progress - rejected")
            return .failure(GarminCommandMessage.tooManyRequests)
        }

        let result = await execute(request, grant: grant)
        await cache.complete(ticket, result: result)

        log("Garmin: \(name) -> \(result.ackCode.rawValue)")
        return result
    }

    func presets() async -> GarminWatchCommandPresets {
        guard let host else {
            return GarminWatchCommandPresets(overridePresets: [], tempTargetPresets: [])
        }
        let overrides = await host.overridePresets()
        let activeOverrideID = await Self.presetID(of: host.activeOverride())
        let tempTargets = await host.tempTargetPresets() ?? []
        let activeTempTargetID = await Self.presetID(of: host.activeTempTarget())
        let maxBolus = await host.maximumBolus()
        let maxCarbs = await host.maximumCarbEntry()
        let volumes = await host.supportedBolusVolumes()
        // read last, so a switch turned off is reported off in the very next reply
        let settings = host.commandSettings

        return GarminWatchCommandPresets(
            overridePresets: Self.sortedByName(overrides).map {
                GarminWatchPreset(name: $0.name, isEnabled: $0.id == activeOverrideID)
            },
            tempTargetPresets: Self.sortedByName(tempTargets).map {
                GarminWatchPreset(name: $0.name, isEnabled: $0.id == activeTempTargetID)
            },
            capabilities: GarminWatchCommandCapabilities(
                isCommandControlEnabled: settings.isCommandControlEnabled,
                // Without supported volumes (no pump) the host refuses every bolus, so the watch
                // isn't offered one.
                isBolusCommandEnabled: settings.isCommandControlEnabled && settings.isBolusCommandEnabled
                    && !volumes.isEmpty,
                maxBolus: Self.decimal(maxBolus),
                maxCarbs: Self.decimal(maxCarbs),
                bolusIncrement: Self.bolusIncrement(volumes)
            )
        )
    }

    // MARK: - Validation

    private func execute(_ request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        if let rejection = rejection(for: request, grant: grant) {
            return rejection
        }
        if let grams = request.command.carbsAmount, let rejection = await carbsLimitRejection(grams, request: request) {
            return rejection
        }

        switch request.command {
        case let .bolus(units):
            return await bolus(units, request: request, grant: grant)
        case let .carbs(grams):
            return await carbs(grams, request: request, grant: grant)
        case let .mealBolus(grams, units):
            return await mealBolus(carbs: grams, bolus: units, request: request, grant: grant)
        case let .activateOverride(name):
            return await activateOverride(named: name, request: request, grant: grant)
        case .cancelOverride:
            return await enact(.stopOverride, presetID: nil, request: request, grant: grant)
        case let .activateTempTarget(name):
            return await activateTempTarget(named: name, request: request, grant: grant)
        case .cancelTempTarget:
            return await cancelTempTarget(request: request, grant: grant)
        }
    }

    /// Checks that need no host reads: freshness, switches and positive amounts.
    private func rejection(for request: GarminWatchCommandRequest, grant: UInt64) -> GarminWatchCommandResult? {
        if let rejection = expiryRejection(for: request) ?? authorizationRejection(for: request, grant: grant) {
            return rejection
        }
        if let units = request.command.bolusAmount, units <= 0 {
            return .failure(GarminCommandMessage.invalidBolus)
        }
        if let grams = request.command.carbsAmount, grams <= 0 {
            return .failure(GarminCommandMessage.invalidCarbs)
        }
        return nil
    }

    /// Refuses carbs above the host's maximum carb entry before anything is added; the host checks
    /// it again. Without a known maximum only the host checks.
    private func carbsLimitRejection(_ grams: Int, request: GarminWatchCommandRequest) async -> GarminWatchCommandResult? {
        guard let host else { return .failure(GarminCommandMessage.commandsDisabled) }
        guard let maximum = await host.maximumCarbEntry(), Double(grams) > maximum else { return nil }
        log("Garmin: \(request.command.name) rejected - carbs above max carbs")
        return .failure(GarminCommandMessage.carbsAboveMaximum)
    }

    /// Re-checked for insulin after every wait: queueing in the lane or waiting for the host can
    /// outlast the window the request was admitted in.
    private func expiryRejection(for request: GarminWatchCommandRequest) -> GarminWatchCommandResult? {
        let age = now().timeIntervalSince(request.date)
        guard age <= Self.maximumCommandAge, age >= -Self.maximumCommandLead else {
            log("Garmin: \(request.command.name) timestamp outside the freshness window - rejected")
            return .failure(GarminCommandMessage.expired)
        }
        return nil
    }

    /// Re-read at every side-effect boundary: settings can change while a command is suspended.
    ///
    /// Settings are read before the epoch. The epoch advances before a switch-off is stored, so
    /// a check that still sees the switch on after an off-then-on sequence also sees the new epoch.
    private func authorizationRejection(for request: GarminWatchCommandRequest, grant: UInt64) -> GarminWatchCommandResult? {
        let name = request.command.name
        guard let settings = host?.commandSettings else {
            log("Garmin: \(name) rejected - host gone")
            return .failure(GarminCommandMessage.commandsDisabled)
        }
        guard authorization.current == grant else {
            log("Garmin: \(name) rejected - command settings changed while pending")
            return .failure(GarminCommandMessage.settingsChanged)
        }
        guard settings.isCommandControlEnabled else {
            log("Garmin: \(name) rejected - watch commands disabled")
            return .failure(GarminCommandMessage.commandsDisabled)
        }
        guard GarminCommandApp(settings).appUUID == request.appUUID else {
            log("Garmin: \(name) rejected - sent by an app that isn't the command app")
            return .failure(GarminCommandMessage.notCommandApp)
        }
        guard !request.command.isInsulin || settings.isBolusCommandEnabled else {
            log("Garmin: \(name) rejected - bolus commands disabled")
            return .failure(GarminCommandMessage.bolusDisabled)
        }
        return nil
    }

    private enum Gate {
        case open(GarminCommandHost)
        case closed(GarminWatchCommandResult)
    }

    /// The linearization point of a command: callers call the host in the `.open` case with
    /// nothing awaited in between. Insulin re-checks the freshness window as well.
    private func finalCheck(for request: GarminWatchCommandRequest, grant: UInt64) -> Gate {
        if request.command.isInsulin, let rejection = expiryRejection(for: request) {
            return .closed(rejection)
        }
        if let rejection = authorizationRejection(for: request, grant: grant) {
            return .closed(rejection)
        }
        guard let host else { return .closed(.failure(GarminCommandMessage.commandsDisabled)) }
        return .open(host)
    }

    // MARK: - Treatments

    private enum CarbsOutcome {
        case added
        /// A final check refused it; nothing was added.
        case rejected(GarminWatchCommandResult)
        case failed(Error)
    }

    private enum BolusOutcome {
        case delivered
        /// Nothing was sent to the pump.
        case rejected(String)
        /// The pump was asked and didn't accept it, or the outcome is unknown; part of the bolus
        /// may still have been delivered.
        case failed
    }

    private func carbs(_ grams: Int, request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        switch await addCarbs(grams, request: request, grant: grant) {
        case .added:
            return .success(.carbsLogged, GarminCommandMessage.carbsLogged)
        case let .rejected(result):
            return result
        case let .failed(error):
            return .failure(message(for: error, action: .carbs))
        }
    }

    private func mealBolus(
        carbs grams: Int,
        bolus units: Decimal,
        request: GarminWatchCommandRequest,
        grant: UInt64
    ) async -> GarminWatchCommandResult {
        if let message = await mealBolusRejectionBeforeCarbs(request: request, grant: grant) {
            return .failure(message)
        }

        switch await addCarbs(grams, request: request, grant: grant) {
        case .added:
            break
        case let .rejected(result):
            return result
        case .failed:
            return .failure(GarminCommandMessage.mealCarbsFailed)
        }

        switch await deliverBolus(units, request: request, grant: grant) {
        case .delivered:
            return .success(.genericSuccess, GarminCommandMessage.mealBolusStarted)
        case .rejected:
            return GarminWatchCommandResult(acknowledged: false, ackCode: .partialFailure, message: GarminCommandMessage.mealBolusRejected)
        case .failed:
            return GarminWatchCommandResult(acknowledged: false, ackCode: .partialFailure, message: GarminCommandMessage.mealBolusFailed)
        }
    }

    /// The bolus checks that can be made before a meal's carbs are added, so a meal bolus that
    /// would be refused for them adds nothing. The insulin lane checks all of them again.
    private func mealBolusRejectionBeforeCarbs(request: GarminWatchCommandRequest, grant: UInt64) async -> String? {
        if let rejection = expiryRejection(for: request) ?? authorizationRejection(for: request, grant: grant) {
            return rejection.message
        }
        guard let host else { return GarminCommandMessage.commandsDisabled }
        if let message = glucoseRejection(await host.latestGlucoseDate(), request: request) {
            return message
        }
        // read last, closest to the carbs
        if let message = holdRejection(await insulinLane.lastEnactment) {
            return message
        }
        return nil
    }

    private func addCarbs(_ grams: Int, request: GarminWatchCommandRequest, grant: UInt64) async -> CarbsOutcome {
        switch finalCheck(for: request, grant: grant) {
        case let .closed(result):
            return .rejected(result)
        case let .open(host):
            do {
                _ = try await host.addCarbEntry(Double(grams), date: request.date)
                return .added
            } catch {
                log("Garmin: adding carbs failed (\(Self.logDescription(error)))")
                return .failed(error)
            }
        }
    }

    private func bolus(_ units: Decimal, request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        switch await deliverBolus(units, request: request, grant: grant) {
        case .delivered:
            return .success(.genericSuccess, GarminCommandMessage.bolusStarted)
        case let .rejected(message):
            return .failure(message)
        case .failed:
            return .failure(GarminCommandMessage.bolusFailed)
        }
    }

    private func deliverBolus(_ units: Decimal, request: GarminWatchCommandRequest, grant: UInt64) async -> BolusOutcome {
        await insulinLane.enter()
        let outcome = await deliverBolusInLane(units, request: request, grant: grant)
        await insulinLane.leave()
        return outcome
    }

    /// Only runs while holding the insulin lane; everything is re-checked because the wait for the
    /// lane can take as long as another command's pump request.
    private func deliverBolusInLane(_ units: Decimal, request: GarminWatchCommandRequest, grant: UInt64) async -> BolusOutcome {
        if let rejection = expiryRejection(for: request) ?? authorizationRejection(for: request, grant: grant) {
            return .rejected(rejection.message)
        }

        let previousEnactment = await insulinLane.lastEnactment
        if let message = holdRejection(previousEnactment) {
            return .rejected(message)
        }

        // Read now, in the lane, so a reading that went stale while the bolus waited stops it.
        guard let host else { return .rejected(GarminCommandMessage.commandsDisabled) }
        if let message = glucoseRejection(await host.latestGlucoseDate(), request: request) {
            return .rejected(message)
        }
        let requested = NSDecimalNumber(decimal: units).doubleValue

        // recorded before the request, since a pump error can still mean partial delivery
        let enactment = now()
        await insulinLane.recordEnactment(at: enactment)

        switch finalCheck(for: request, grant: grant) {
        case let .closed(result):
            await insulinLane.restoreEnactment(previousEnactment, replacing: enactment)
            return .rejected(result.message)
        case let .open(host):
            do {
                _ = try await host.deliverBolus(requested)
                return .delivered
            } catch let error as SmartwatchActionError where !error.mayHaveReachedPump {
                await insulinLane.restoreEnactment(previousEnactment, replacing: enactment)
                log("Garmin: bolus refused, nothing sent to the pump (\(Self.logDescription(error)))")
                return .rejected(message(for: error, action: .bolus))
            } catch {
                log("Garmin: bolus failed (\(Self.logDescription(error)))")
                return .failed
            }
        }
    }

    /// The `minimumBolusInterval` hold after the last watch bolus handed to the host.
    private func holdRejection(_ lastEnactment: Date?) -> String? {
        guard let lastEnactment, now().timeIntervalSince(lastEnactment) < Self.minimumBolusInterval else { return nil }
        log("Garmin: bolus rejected - previous watch bolus may not be in pump history yet")
        return GarminCommandMessage.recentBolus
    }

    /// Refuses without a glucose reading from the last `maximumGlucoseAge`.
    private func glucoseRejection(_ latestGlucose: Date?, request: GarminWatchCommandRequest) -> String? {
        guard let latestGlucose, now().timeIntervalSince(latestGlucose) <= Self.maximumGlucoseAge else {
            log("Garmin: \(request.command.name) rejected - no glucose reading in the last 15 minutes")
            return GarminCommandMessage.noRecentGlucose
        }
        return nil
    }

    // MARK: - Adjustments

    private func activateOverride(named name: String, request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        guard let host else { return .failure(GarminCommandMessage.commandsDisabled) }
        guard let preset = await Self.uniquePreset(named: name, in: host.overridePresets()) else {
            log("Garmin: override preset missing or ambiguous")
            return .failure(GarminCommandMessage.overrideNotFound)
        }
        return await enact(.startOverride, presetID: preset.id, request: request, grant: grant)
    }

    private func activateTempTarget(named name: String, request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        guard let host else { return .failure(GarminCommandMessage.commandsDisabled) }
        guard let presets = await host.tempTargetPresets() else {
            log("Garmin: activateTempTarget rejected - host has no temp targets")
            return .failure(GarminCommandMessage.tempTargetsUnavailable)
        }
        guard let preset = Self.uniquePreset(named: name, in: presets) else {
            log("Garmin: temp target preset missing or ambiguous")
            return .failure(GarminCommandMessage.tempTargetNotFound)
        }
        return await enact(.startTempTarget, presetID: preset.id, request: request, grant: grant)
    }

    private func cancelTempTarget(request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        guard let host else { return .failure(GarminCommandMessage.commandsDisabled) }
        guard await host.tempTargetPresets() != nil else {
            log("Garmin: cancelTempTarget rejected - host has no temp targets")
            return .failure(GarminCommandMessage.tempTargetsUnavailable)
        }
        return await enact(.stopTempTarget, presetID: nil, request: request, grant: grant)
    }

    /// Starts or ends an override or temp target; the host treats ending one when none runs as success.
    private func enact(_ action: Action, presetID: String?, request: GarminWatchCommandRequest, grant: UInt64) async -> GarminWatchCommandResult {
        switch finalCheck(for: request, grant: grant) {
        case let .closed(result):
            return result
        case let .open(host):
            do {
                if action == .startOverride || action == .stopOverride {
                    try await host.enactOverride(presetID)
                } else {
                    try await host.enactTempTarget(presetID)
                }
            } catch {
                log("Garmin: \(request.command.name) failed (\(Self.logDescription(error)))")
                return .failure(message(for: error, action: action))
            }
            switch action {
            case .startOverride: return .success(.overrideStarted, GarminCommandMessage.overrideStarted)
            case .stopOverride: return .success(.overrideStopped, GarminCommandMessage.overrideStopped)
            case .startTempTarget: return .success(.tempTargetStarted, GarminCommandMessage.tempTargetStarted)
            default: return .success(.tempTargetStopped, GarminCommandMessage.tempTargetStopped)
            }
        }
    }

    // MARK: - Presets

    /// Exact, case-sensitive match that ignores whether the preset is running; two presets that
    /// only differ in whitespace or case must not let the watch start the wrong one.
    private static func uniquePreset(named name: String, in presets: [TemporaryPreset]) -> TemporaryPreset? {
        let matches = presets.filter { $0.name == name }
        return matches.count == 1 ? matches.first : nil
    }

    private static func sortedByName(_ presets: [TemporaryPreset]) -> [TemporaryPreset] {
        presets.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            // tie-break on raw names so equal display names keep a stable order
            case .orderedSame: return $0.name < $1.name
            }
        }
    }

    private static func presetID(of adjustment: TemporaryScheduleOverride?) -> String? {
        guard case let .preset(preset) = adjustment?.context else { return nil }
        return preset.id
    }

    /// The smallest positive gap between the pump's volumes, else its smallest volume, else 0.
    private static func bolusIncrement(_ volumes: [Double]) -> Decimal {
        let sorted = Set(volumes.filter { $0.isFinite && $0 > 0 }.map { decimal($0) }).sorted()
        let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        // Never 0: the watch apps step their bolus picker by it. Without volumes (no pump) bolus
        // is reported off; 0.05 U is only a placeholder.
        return gaps.min() ?? sorted.first ?? Self.placeholderBolusIncrement
    }

    static let placeholderBolusIncrement: Decimal = 0.05

    /// Rounded to 6 places, so 0.05 is reported as 0.05 and not its binary approximation; 0 when
    /// unknown or not a positive number.
    private static func decimal(_ value: Double?) -> Decimal {
        guard let value, value.isFinite, value > 0 else { return 0 }
        var raw = Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 6, .plain)
        return rounded
    }

    // MARK: - Messages

    private enum Action: Equatable {
        case bolus
        case carbs
        case startOverride
        case stopOverride
        case startTempTarget
        case stopTempTarget
    }

    /// Never carries amounts or the host's own reason strings; those go to the log only.
    private func message(for error: Error, action: Action) -> String {
        guard let error = error as? SmartwatchActionError else { return Self.fallbackMessage(for: action) }
        switch error {
        case .notAllowed:
            return GarminCommandMessage.notAllowed
        case .expiredRequest:
            return GarminCommandMessage.expired
        case .invalidAmount:
            switch action {
            case .bolus: return GarminCommandMessage.invalidBolus
            case .carbs: return GarminCommandMessage.invalidCarbs
            default: return Self.fallbackMessage(for: action)
            }
        case .exceedsMaximum:
            switch action {
            case .bolus: return GarminCommandMessage.bolusAboveMaximum
            case .carbs: return GarminCommandMessage.carbsAboveMaximum
            default: return Self.fallbackMessage(for: action)
            }
        case .exceedsRecommendation:
            return GarminCommandMessage.bolusAboveRecommendation
        case .noRecentGlucose:
            return GarminCommandMessage.noRecentGlucose
        case .rateLimited:
            return action == .bolus ? GarminCommandMessage.recentBolus : GarminCommandMessage.rateLimited
        case .dailyLimitReached:
            return GarminCommandMessage.dailyLimitReached
        case .unknownPreset:
            switch action {
            case .startOverride, .stopOverride: return GarminCommandMessage.overrideNotFound
            case .startTempTarget, .stopTempTarget: return GarminCommandMessage.tempTargetNotFound
            default: return Self.fallbackMessage(for: action)
            }
        case .inProgress:
            return GarminCommandMessage.bolusInProgress
        case .deliveryFailed:
            return GarminCommandMessage.bolusFailed
        case .refusedByHost,
             .failed:
            return Self.fallbackMessage(for: action)
        }
    }

    private static func fallbackMessage(for action: Action) -> String {
        switch action {
        case .bolus: return GarminCommandMessage.bolusRefused
        case .carbs: return GarminCommandMessage.carbsFailed
        case .startOverride: return GarminCommandMessage.overrideStartFailed
        case .stopOverride: return GarminCommandMessage.overrideStopFailed
        case .startTempTarget: return GarminCommandMessage.tempTargetStartFailed
        case .stopTempTarget: return GarminCommandMessage.tempTargetStopFailed
        }
    }

    /// The case name, plus the host's own reason for the cases that carry one. Never amounts the
    /// plugin knows.
    private static func logDescription(_ error: Error) -> String {
        guard let error = error as? SmartwatchActionError else { return "unexpected" }
        switch error {
        // The host logs its own reason, which can name amounts; only the case goes here.
        case .refusedByHost: return "refusedByHost"
        case .deliveryFailed: return "deliveryFailed"
        case .failed: return "failed"
        case .notAllowed: return "notAllowed"
        case .expiredRequest: return "expiredRequest"
        case .invalidAmount: return "invalidAmount"
        case .exceedsMaximum: return "exceedsMaximum"
        case .exceedsRecommendation: return "exceedsRecommendation"
        case .noRecentGlucose: return "noRecentGlucose"
        case .rateLimited: return "rateLimited"
        case .dailyLimitReached: return "dailyLimitReached"
        case .unknownPreset: return "unknownPreset"
        case .inProgress: return "inProgress"
        }
    }
}

private extension SmartwatchActionError {
    /// Per `SmartwatchManagerDelegate.deliverBolus`, only `.deliveryFailed` means the pump was asked.
    var mayHaveReachedPump: Bool {
        if case .deliveryFailed = self { return true }
        return false
    }
}

/// User-facing acks; Tai's wording where it had one.
private enum GarminCommandMessage {
    static var interrupted: String {
        LocalizedString("Interrupted by an app restart. Check carbs and pump history before repeating.", comment: "Garmin watch command ack")
    }
    static var inProgress: String { LocalizedString("Request is already in progress.", comment: "Garmin watch command ack") }
    static var requestIDReused: String { LocalizedString("Request ID was already used.", comment: "Garmin watch command ack") }
    static var tooManyRequests: String { LocalizedString("Too many requests in progress. Please try again.", comment: "Garmin watch command ack") }
    static var expired: String { LocalizedString("Command expired. Please try again.", comment: "Garmin watch command ack") }
    static var settingsChanged: String { LocalizedString("Watch command settings changed.", comment: "Garmin watch command ack") }
    static var commandsDisabled: String { LocalizedString("Watch commands are disabled.", comment: "Garmin watch command ack") }
    static var bolusDisabled: String { LocalizedString("Bolus from watch is disabled.", comment: "Garmin watch command ack") }
    static var notCommandApp: String { LocalizedString("Commands are handled by another watch app.", comment: "Garmin watch command ack") }
    static var notAllowed: String { LocalizedString("Not allowed from the watch.", comment: "Garmin watch command ack") }

    static var invalidBolus: String { LocalizedString("Invalid bolus amount.", comment: "Garmin watch command ack") }
    static var invalidCarbs: String { LocalizedString("Invalid carbs amount.", comment: "Garmin watch command ack") }
    static var carbsAboveMaximum: String { LocalizedString("Carbs exceed the maximum allowed.", comment: "Garmin watch command ack") }
    static var bolusAboveMaximum: String { LocalizedString("Bolus exceeds max bolus.", comment: "Garmin watch command ack") }
    static var bolusAboveRecommendation: String { LocalizedString("Bolus exceeds the recommendation.", comment: "Garmin watch command ack") }
    static var noRecentGlucose: String { LocalizedString("No recent glucose reading.", comment: "Garmin watch command ack") }
    static var recentBolus: String { LocalizedString("A bolus was given in the last 6 minutes.", comment: "Garmin watch command ack") }
    static var rateLimited: String { LocalizedString("Too soon after the previous request.", comment: "Garmin watch command ack") }
    static var dailyLimitReached: String { LocalizedString("Daily watch bolus limit reached.", comment: "Garmin watch command ack") }
    static var bolusInProgress: String { LocalizedString("Another bolus is in progress.", comment: "Garmin watch command ack") }

    static var carbsLogged: String { LocalizedString("Carbs logged.", comment: "Garmin watch command ack") }
    static var carbsFailed: String { LocalizedString("Could not log carbs.", comment: "Garmin watch command ack") }
    static var bolusStarted: String { LocalizedString("Bolus started.", comment: "Garmin watch command ack") }
    static var bolusRefused: String { LocalizedString("Bolus refused. No bolus was delivered.", comment: "Garmin watch command ack") }
    static var bolusFailed: String { LocalizedString("Bolus failed. Check pump history before repeating.", comment: "Garmin watch command ack") }
    static var mealCarbsFailed: String { LocalizedString("Could not log carbs. No bolus was delivered.", comment: "Garmin watch command ack") }
    static var mealBolusStarted: String { LocalizedString("Carbs logged and bolus started.", comment: "Garmin watch command ack") }
    static var mealBolusRejected: String { LocalizedString("Carbs logged. No bolus was delivered.", comment: "Garmin watch command ack") }
    static var mealBolusFailed: String {
        LocalizedString("Carbs logged. Bolus failed, check pump history before repeating.", comment: "Garmin watch command ack")
    }

    static var overrideNotFound: String { LocalizedString("Override preset not found.", comment: "Garmin watch command ack") }
    static var overrideStarted: String { LocalizedString("Override started.", comment: "Garmin watch command ack") }
    static var overrideStopped: String { LocalizedString("Override stopped.", comment: "Garmin watch command ack") }
    static var overrideStartFailed: String { LocalizedString("Could not start override.", comment: "Garmin watch command ack") }
    static var overrideStopFailed: String { LocalizedString("Could not stop override.", comment: "Garmin watch command ack") }
    static var tempTargetsUnavailable: String { LocalizedString("Temp targets aren't available.", comment: "Garmin watch command ack") }
    static var tempTargetNotFound: String { LocalizedString("Temp target preset not found.", comment: "Garmin watch command ack") }
    static var tempTargetStarted: String { LocalizedString("Temp target started.", comment: "Garmin watch command ack") }
    static var tempTargetStopped: String { LocalizedString("Temp target stopped.", comment: "Garmin watch command ack") }
    static var tempTargetStartFailed: String { LocalizedString("Could not start temp target.", comment: "Garmin watch command ack") }
    static var tempTargetStopFailed: String { LocalizedString("Could not stop temp target.", comment: "Garmin watch command ack") }
}
