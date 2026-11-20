//
//  GarminWatchCommand.swift
//  GarminSmartwatchKit
//
//  From Tai's WatchCommand (mountrcg/Tai, MIT), for the plugin.
//

import Foundation

/// A state-changing command sent from a watch app, already parsed and type-checked.
enum GarminWatchCommand: Equatable, Sendable {
    case bolus(Decimal)
    case carbs(Int)
    /// Carbs are added before the bolus runs, so a refused bolus still leaves the meal logged.
    case mealBolus(carbs: Int, bolus: Decimal)
    case activateOverride(name: String)
    case cancelOverride
    case activateTempTarget(name: String)
    case cancelTempTarget

    /// Wire name of the command; also the only command detail that is safe to log.
    var name: String {
        switch self {
        case .bolus: return "bolus"
        case .carbs: return "carbs"
        case .mealBolus: return "mealBolus"
        case .activateOverride: return "activateOverride"
        case .cancelOverride: return "cancelOverride"
        case .activateTempTarget: return "activateTempTarget"
        case .cancelTempTarget: return "cancelTempTarget"
        }
    }

    var bolusAmount: Decimal? {
        switch self {
        case let .bolus(units),
             let .mealBolus(_, units):
            return units
        default:
            return nil
        }
    }

    var carbsAmount: Int? {
        switch self {
        case let .carbs(grams),
             let .mealBolus(grams, _):
            return grams
        default:
            return nil
        }
    }

    var isInsulin: Bool { bolusAmount != nil }

    /// Commands whose success changes which preset is running on the watch's preset list.
    var changesPresetState: Bool {
        switch self {
        case .activateOverride,
             .activateTempTarget,
             .cancelOverride,
             .cancelTempTarget:
            return true
        default:
            return false
        }
    }
}

struct GarminWatchCommandRequest: Equatable, Sendable {
    let requestID: UUID
    /// Watch app that sent the command; request IDs are only unique per app.
    let appUUID: UUID
    /// When the watch issued the command.
    let date: Date
    let command: GarminWatchCommand
}

/// The `ackCode` values of Trio's watch protocol, which the Connect IQ apps branch on.
enum GarminAckCode: String, Sendable {
    case carbsLogged = "carbs_logged"
    case overrideStarted = "override_started"
    case overrideStopped = "override_stopped"
    case tempTargetStarted = "temp_target_started"
    case tempTargetStopped = "temp_target_stopped"
    case genericSuccess = "success"
    case genericFailure = "failure"
    /// Meal logged but its bolus was not delivered.
    case partialFailure = "partial_failure"
    /// Duplicate of a request that is still running; that request's own ack follows.
    case inProgress = "in_progress"
}

/// Terminal answer to a watch command, sent back to the requesting app only.
struct GarminWatchCommandResult: Equatable, Sendable {
    let acknowledged: Bool
    let ackCode: GarminAckCode
    /// Short, user-facing text. Never carries amounts or internal error details.
    let message: String

    static func success(_ ackCode: GarminAckCode, _ message: String) -> GarminWatchCommandResult {
        GarminWatchCommandResult(acknowledged: true, ackCode: ackCode, message: message)
    }

    static func failure(_ message: String) -> GarminWatchCommandResult {
        GarminWatchCommandResult(acknowledged: false, ackCode: .genericFailure, message: message)
    }
}

/// A preset as the watch lists it: its name and whether it is running now.
/// Whether it runs never restricts activating it.
struct GarminWatchPreset: Equatable, Sendable {
    let name: String
    let isEnabled: Bool
}

struct GarminWatchCommandPresets: Equatable, Sendable {
    let overridePresets: [GarminWatchPreset]
    let tempTargetPresets: [GarminWatchPreset]
    var capabilities = GarminWatchCommandCapabilities()
}

/// Switches and limits the watch uses to offer only what the phone would accept; the phone still
/// enforces every one of them. The defaults describe a phone that accepts nothing.
struct GarminWatchCommandCapabilities: Equatable, Sendable {
    var isCommandControlEnabled = false
    var isBolusCommandEnabled = false
    var maxBolus: Decimal = 0
    var maxCarbs: Decimal = 0
    var bolusIncrement: Decimal = 0
}
