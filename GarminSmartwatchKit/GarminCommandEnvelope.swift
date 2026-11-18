//
//  GarminCommandEnvelope.swift
//  GarminSmartwatchKit
//
//  From Tai's GarminCommandRouter (mountrcg/Tai, MIT), for the plugin.
//

import Foundation

/// The keys of Trio's Garmin v1 messages.
enum GarminMessageKey {
    static let protocolVersion = "v"
    static let request = "req"
    static let requestID = "requestId"
    static let date = "date"
    static let command = "command"
    static let payload = "payload"

    static let bolus = "bolus"
    static let carbs = "carbs"
    static let mealBolus = "mealBolus"
    static let activateOverride = "activateOverride"
    static let cancelOverride = "cancelOverride"
    static let activateTempTarget = "activateTempTarget"
    static let cancelTempTarget = "cancelTempTarget"
    static let presetName = "name"
    static let presetIsEnabled = "isEnabled"

    static let acknowledged = "acknowledged"
    static let ackCode = "ackCode"
    static let message = "message"

    static let overridePresets = "overridePresets"
    static let tempTargetPresets = "tempTargetPresets"
    static let isCommandControlEnabled = "isCommandControlEnabled"
    static let isBolusCommandEnabled = "isBolusCommandEnabled"
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let bolusIncrement = "bolusIncrement"

    static let isCommandAppActive = "active"
    static let commandApp = "owner"
}

/// A message received from a Connect IQ app, after envelope validation.
enum GarminInboundMessage: Equatable {
    /// Bare `"status"` string sent by watch apps that predate the v1 envelope.
    case legacyStatus
    case status
    case presets
    /// `requestIDString` is echoed back verbatim so the watch can match the ack.
    case command(requestIDString: String, requestID: UUID, date: Date, command: GarminWatchCommand)
    /// Malformed or unsupported; carries the request ID when the envelope still named one to answer.
    case invalid(requestID: String?)

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    /// Never includes payload values: a command body can carry an insulin amount.
    var logName: String {
        switch self {
        case .legacyStatus: return "legacy status request"
        case .status: return "status request"
        case .presets: return "presets request"
        case let .command(_, _, _, command): return "\(command.name) command"
        case .invalid: return "invalid message"
        }
    }
}

/// Garmin v1 wire contract: parsing inbound envelopes and building the targeted responses.
enum GarminCommandEnvelope {
    static let protocolVersion = 1

    enum Request: String {
        case status
        case presets
        case command
        case ack
        case ownerMode
    }

    private static let readEnvelopeKeys: Set<String> = [GarminMessageKey.protocolVersion, GarminMessageKey.request]
    private static let commandEnvelopeKeys: Set<String> = [
        GarminMessageKey.protocolVersion,
        GarminMessageKey.request,
        GarminMessageKey.requestID,
        GarminMessageKey.date,
        GarminMessageKey.command,
        GarminMessageKey.payload
    ]

    static func parse(_ message: Any) -> GarminInboundMessage {
        if let string = message as? String {
            return string == Request.status.rawValue ? .legacyStatus : .invalid(requestID: nil)
        }
        guard let envelope = message as? [String: Any] else {
            return .invalid(requestID: nil)
        }

        let requestIDString = envelope[GarminMessageKey.requestID] as? String
        let keys = Set(envelope.keys)
        guard integer(envelope[GarminMessageKey.protocolVersion]) == Int64(protocolVersion),
              let request = (envelope[GarminMessageKey.request] as? String).flatMap(Request.init(rawValue:))
        else {
            return .invalid(requestID: requestIDString)
        }

        switch request {
        case .status:
            return keys == readEnvelopeKeys ? .status : .invalid(requestID: requestIDString)
        case .presets:
            return keys == readEnvelopeKeys ? .presets : .invalid(requestID: requestIDString)
        case .command:
            guard keys == commandEnvelopeKeys,
                  let requestIDString,
                  let requestID = rfc4122UUID(requestIDString),
                  let milliseconds = integer(envelope[GarminMessageKey.date]), milliseconds >= 0,
                  let name = envelope[GarminMessageKey.command] as? String,
                  let payload = envelope[GarminMessageKey.payload] as? [String: Any],
                  let command = command(named: name, payload: payload)
            else {
                return .invalid(requestID: requestIDString)
            }
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            return .command(requestIDString: requestIDString, requestID: requestID, date: date, command: command)
        case .ack,
             .ownerMode:
            return .invalid(requestID: requestIDString)
        }
    }

    static func acknowledgment(requestID: String, result: GarminWatchCommandResult) -> [String: Any] {
        [
            GarminMessageKey.protocolVersion: protocolVersion,
            GarminMessageKey.request: Request.ack.rawValue,
            GarminMessageKey.requestID: requestID,
            GarminMessageKey.acknowledged: result.acknowledged,
            GarminMessageKey.ackCode: result.ackCode.rawValue,
            GarminMessageKey.message: result.message
        ]
    }

    /// Tells a command app whether it is the one whose commands run; `owner` lets an inactive one
    /// say which app is.
    static func commandAppNotice(isActive: Bool, commandApp: GarminCommandApp) -> [String: Any] {
        [
            GarminMessageKey.protocolVersion: protocolVersion,
            GarminMessageKey.request: Request.ownerMode.rawValue,
            GarminMessageKey.isCommandAppActive: isActive,
            GarminMessageKey.commandApp: commandApp.rawValue
        ]
    }

    /// Lists every preset; `isEnabled` reports whether it is running now, not whether the watch
    /// may start it. The switches and limits let the watch hide what the phone would refuse;
    /// amounts go out as doubles in U and g.
    static func presetsResponse(_ presets: GarminWatchCommandPresets) -> [String: Any] {
        let capabilities = presets.capabilities
        func list(_ presets: [GarminWatchPreset]) -> [[String: Any]] {
            presets.map { [GarminMessageKey.presetName: $0.name, GarminMessageKey.presetIsEnabled: $0.isEnabled] }
        }
        return [
            GarminMessageKey.protocolVersion: protocolVersion,
            GarminMessageKey.request: Request.presets.rawValue,
            GarminMessageKey.overridePresets: list(presets.overridePresets),
            GarminMessageKey.tempTargetPresets: list(presets.tempTargetPresets),
            GarminMessageKey.isCommandControlEnabled: capabilities.isCommandControlEnabled,
            GarminMessageKey.isBolusCommandEnabled: capabilities.isBolusCommandEnabled,
            GarminMessageKey.maxBolus: NSDecimalNumber(decimal: capabilities.maxBolus).doubleValue,
            GarminMessageKey.maxCarbs: NSDecimalNumber(decimal: capabilities.maxCarbs).doubleValue,
            GarminMessageKey.bolusIncrement: NSDecimalNumber(decimal: capabilities.bolusIncrement).doubleValue
        ]
    }

    // MARK: - Payloads

    private static func command(named name: String, payload: [String: Any]) -> GarminWatchCommand? {
        let keys = Set(payload.keys)

        switch name {
        case GarminMessageKey.bolus:
            guard keys == [GarminMessageKey.bolus], let units = units(payload[GarminMessageKey.bolus]) else { return nil }
            return .bolus(units)
        case GarminMessageKey.carbs:
            guard keys == [GarminMessageKey.carbs], let grams = grams(payload[GarminMessageKey.carbs]) else { return nil }
            return .carbs(grams)
        case GarminMessageKey.mealBolus:
            guard keys == [GarminMessageKey.carbs, GarminMessageKey.bolus],
                  let grams = grams(payload[GarminMessageKey.carbs]),
                  let units = units(payload[GarminMessageKey.bolus])
            else { return nil }
            return .mealBolus(carbs: grams, bolus: units)
        case GarminMessageKey.activateOverride:
            guard keys == [GarminMessageKey.presetName], let name = payload[GarminMessageKey.presetName] as? String
            else { return nil }
            return .activateOverride(name: name)
        case GarminMessageKey.cancelOverride:
            return keys.isEmpty ? .cancelOverride : nil
        case GarminMessageKey.activateTempTarget:
            guard keys == [GarminMessageKey.presetName], let name = payload[GarminMessageKey.presetName] as? String
            else { return nil }
            return .activateTempTarget(name: name)
        case GarminMessageKey.cancelTempTarget:
            return keys.isEmpty ? .cancelTempTarget : nil
        default:
            return nil
        }
    }

    // MARK: - Value Types

    /// Connect IQ delivers every number, and booleans too, as `NSNumber`; booleans are not numbers here.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number : nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = number(value) else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.0E15 else { return nil }
        return number.int64Value
    }

    private static func grams(_ value: Any?) -> Int? {
        integer(value).flatMap { Int(exactly: $0) }
    }

    /// Rounds to 0.001 U: a Monkey C `Float` of 0.1 arrives as 0.10000000149.
    private static func units(_ value: Any?) -> Decimal? {
        guard let number = number(value) else { return nil }
        var raw = Decimal(number.doubleValue)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 3, .plain)
        return rounded
    }

    static func rfc4122UUID(_ string: String) -> UUID? {
        guard string.count == 36, let uuid = UUID(uuidString: string) else { return nil }
        // variant bits 10xx mark the RFC 4122 layout
        return uuid.uuid.8 & 0xC0 == 0x80 ? uuid : nil
    }
}

/// Connect IQ side of watch commands: turns one inbound message into at most one reply for the
/// requesting app plus an optional state refresh. It has no broadcast path by design.
struct GarminCommandRouter {
    struct Outcome {
        /// Sent to the requesting `IQApp` only.
        var reply: [String: Any]?
        /// The watch asked for the regular watch state.
        var refreshesState = false
        /// A preset started or stopped, so the command app needs the preset list.
        var pushesPresets = false

        static let none = Outcome()
    }

    let processor: GarminCommandProcessing
    var log: (String) -> Void

    /// A command app that isn't registered still gets its commands answered, so a watch that missed
    /// the switch to the other command app sees a refusal instead of waiting for an ack that never comes.
    func route(
        _ message: Any,
        from appUUID: UUID,
        isRegistered: Bool,
        isCommandApp: Bool = false,
        appName: String
    ) async -> Outcome {
        let inbound = GarminCommandEnvelope.parse(message)
        log("Garmin \(appName): received \(inbound.logName)")

        guard isRegistered || (isCommandApp && inbound.isCommand) else {
            log("Garmin: ignored \(inbound.logName) from unregistered app \(appUUID.uuidString)")
            return .none
        }

        switch inbound {
        case .legacyStatus,
             .status:
            return Outcome(refreshesState: true)

        case .presets:
            let presets = await processor.presets()
            return Outcome(reply: GarminCommandEnvelope.presetsResponse(presets))

        case let .command(requestIDString, requestID, date, command):
            let request = GarminWatchCommandRequest(requestID: requestID, appUUID: appUUID, date: date, command: command)
            let result = await processor.process(request)
            return Outcome(
                reply: GarminCommandEnvelope.acknowledgment(requestID: requestIDString, result: result),
                pushesPresets: result.acknowledged && command.changesPresetState
            )

        case let .invalid(requestID):
            // without a request ID the watch could not match an answer, so none is sent
            guard let requestID else { return .none }
            let result = GarminWatchCommandResult.failure(LocalizedString("Invalid command.", comment: "Garmin watch command ack"))
            return Outcome(reply: GarminCommandEnvelope.acknowledgment(requestID: requestID, result: result))
        }
    }
}
