//
//  GarminCommandRouter.swift
//  GarminSmartwatchKit
//
//  From Tai's GarminCommandRouter (mountrcg/Tai, MIT), for the plugin.
//

import Foundation

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
