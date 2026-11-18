//
//  GarminWatchSettings.swift
//  GarminSmartwatchKit
//
//  From Trio's GarminWatchSettings and GarminDevice (Trio contributors, MIT).
//

import ConnectIQ
import Foundation

// MARK: - Display choices

/// Shown next to glucose by the Trio and SwissAlpine watchfaces and datafields.
public enum GarminPrimaryAttributeChoice: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case cob
    case isf
    case sensRatio

    public var displayName: String {
        switch self {
        case .cob: return LocalizedString("COB", comment: "Garmin display choice: carbs on board")
        case .isf: return LocalizedString("ISF", comment: "Garmin display choice: insulin sensitivity")
        case .sensRatio: return LocalizedString("Sens Ratio", comment: "Garmin display choice: sensitivity ratio")
        }
    }
}

/// The second value the watchfaces and datafields show.
public enum GarminSecondaryAttributeChoice: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case tbr
    case eventualBG

    public var displayName: String {
        switch self {
        case .tbr: return LocalizedString("TBR", comment: "Garmin display choice: temp basal rate")
        case .eventualBG: return LocalizedString("evBG", comment: "Garmin display choice: eventual glucose")
        }
    }
}

/// How the watch colours glucose.
public enum GarminGlucoseColorScheme: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    /// The wire format the watch apps read.
    case staticColor = "static"
    case dynamicColor = "dynamic"

    public var displayName: String {
        switch self {
        case .staticColor: return LocalizedString("Static", comment: "Garmin glucose colour scheme: static")
        case .dynamicColor: return LocalizedString("Dynamic", comment: "Garmin glucose colour scheme: dynamic")
        }
    }
}

// MARK: - Watch apps

/// The Connect IQ watch apps that take the watchface slot.
public enum GarminWatchface: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case trio
    case swissalpine
    /// Not a watchface but a Connect IQ watch app that republishes the payload as
    /// complications, so any watchface with complication slots can show the data.
    case complication

    public var displayName: String {
        switch self {
        case .trio: return LocalizedString("Trio", comment: "Garmin watchface: Trio")
        case .swissalpine: return LocalizedString("Swissalpine", comment: "Garmin watchface: SwissAlpine")
        case .complication: return LocalizedString("Complication", comment: "Garmin watch app: complications")
        }
    }

    /// The Connect IQ store apps (live builds).
    public var watchfaceUUID: UUID? {
        switch self {
        case .trio: return UUID(uuidString: "7a121867-140e-41ba-9982-2e82e2aa6579")
        case .swissalpine: return UUID(uuidString: "4cea4efd-4aaf-4db4-8891-ef36dde14303")
        case .complication: return UUID(uuidString: "0986fd19-604b-4bcb-a931-6f8621738682")
        }
    }

    /// How far back the readings the watch app gets reach, measured from the newest
    /// reading; 0 sends the newest reading only. Time rather than a count, so it
    /// means the same with any CGM. The plugin reads only
    /// `GarminHostData.historyInterval` (3 h) from the host, so a longer span gets
    /// no more than that.
    public var historySpan: TimeInterval {
        switch self {
        case .trio: return 0
        case .swissalpine, .complication: return 2 * 60 * 60
        }
    }

    /// The least time between two readings the watch app gets. With 5 minutes a
    /// 1-minute CGM sends every 5th reading, so these apps get as many readings, as
    /// far apart, as with a 5-minute CGM.
    public var historySpacing: TimeInterval {
        switch self {
        case .trio, .swissalpine, .complication: return 5 * 60
        }
    }
}

/// The Connect IQ datafields.
public enum GarminDatafield: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case trio
    case swissalpine
    case loopgraph
    /// Read from settings saved before several datafields could be chosen; never offered.
    case none

    public var displayName: String {
        switch self {
        case .trio: return LocalizedString("Trio", comment: "Garmin datafield: Trio")
        case .swissalpine: return LocalizedString("Swissalpine", comment: "Garmin datafield: SwissAlpine")
        case .loopgraph: return LocalizedString("LoopGraph", comment: "Garmin datafield: LoopGraph")
        case .none: return LocalizedString("None", comment: "Garmin datafield: none")
        }
    }

    /// The Connect IQ store apps (live builds, except LoopGraph's, as in Tai).
    public var datafieldUUID: UUID? {
        switch self {
        case .trio: return UUID(uuidString: "3d9b6528-8c84-459a-bbab-989b5f001ebd")
        case .swissalpine: return UUID(uuidString: "dec5292a-74b0-41bc-8e45-cd93f1d5e137")
        // Tai's beta build; check it is published before relying on it.
        case .loopgraph: return UUID(uuidString: "986105b6-5d20-4895-a5c1-b98248ddde4c")
        case .none: return nil
        }
    }

    /// How far back from the newest reading this datafield needs; see `GarminWatchface.historySpan`.
    public var historySpan: TimeInterval {
        switch self {
        case .loopgraph: return 2 * 60 * 60
        case .trio, .swissalpine, .none: return 0
        }
    }

    /// The datafields the user can choose.
    public static var selectableCases: [GarminDatafield] {
        allCases.filter { $0 != .none }
    }

    /// Every chosen datafield is registered as its own Connect IQ app and gets
    /// the same broadcast, so this caps how many apps one update goes to.
    public static let maxSelectionCount = 4

    /// Drops `.none` and duplicates and keeps at most `maxSelectionCount`, in order.
    public static func sanitizedSelection(_ datafields: [GarminDatafield]) -> [GarminDatafield] {
        var selection = [GarminDatafield]()
        for datafield in datafields where datafield != .none && !selection.contains(datafield) {
            selection.append(datafield)
            if selection.count == maxSelectionCount { break }
        }
        return selection
    }
}

// MARK: - Settings

/// The plugin's settings, saved in its `rawState`.
public struct GarminWatchSettings: Codable, Hashable, Sendable {
    public var watchface: GarminWatchface = .trio
    /// The datafields that get data, in the order chosen; empty for none.
    /// Never more than `GarminDatafield.maxSelectionCount`.
    public var datafields: [GarminDatafield] = [.trio] {
        didSet {
            let sanitized = GarminDatafield.sanitizedSelection(datafields)
            if sanitized != datafields { datafields = sanitized }
        }
    }
    public var primaryAttributeChoice: GarminPrimaryAttributeChoice = .cob
    public var secondaryAttributeChoice: GarminSecondaryAttributeChoice = .tbr
    public var glucoseColorScheme: GarminGlucoseColorScheme = .staticColor
    /// Off while the user switches watchfaces on the watch, or uses only a datafield.
    public var isWatchfaceDataEnabled: Bool = true
    /// Lets watch apps send carbs, override and temp target commands. Off until the user turns it on.
    public var isCommandControlEnabled: Bool = false {
        didSet {
            // Turning commands back on never re-arms insulin by itself.
            if !isCommandControlEnabled { isBolusCommandEnabled = false }
        }
    }
    /// Also lets them send bolus and meal bolus commands; only while `isCommandControlEnabled` is on.
    public var isBolusCommandEnabled: Bool = false

    public init() {}

    /// Adds the datafield, or removes it when chosen already; an addition beyond the maximum is ignored.
    public mutating func toggleDatafield(_ datafield: GarminDatafield) {
        if let index = datafields.firstIndex(of: datafield) {
            datafields.remove(at: index)
        } else if datafield != .none, datafields.count < GarminDatafield.maxSelectionCount {
            datafields.append(datafield)
        }
    }

    /// Whether the datafield is chosen or can still be added.
    public func canSelectDatafield(_ datafield: GarminDatafield) -> Bool {
        datafields.contains(datafield) || datafields.count < GarminDatafield.maxSelectionCount
    }

    /// The longest history any chosen watch app needs; the broadcast goes to all of them.
    public var historySpan: TimeInterval {
        let datafieldSpan = datafields.map(\.historySpan).max() ?? 0
        return max(watchface.historySpan, datafieldSpan)
    }

    /// Each setting missing from what was saved (one added since) or no longer
    /// known (a choice removed since) takes its default, rather than all of them
    /// going back to theirs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let defaults = GarminWatchSettings()
        watchface = value(.watchface, or: defaults.watchface)
        if let saved = (try? container.decodeIfPresent([GarminDatafield].self, forKey: .datafields)) ?? nil {
            datafields = GarminDatafield.sanitizedSelection(saved)
        } else if let single = (try? container.decodeIfPresent(GarminDatafield.self, forKey: .datafield)) ?? nil {
            // Saved before several datafields could be chosen.
            datafields = single == .none ? [] : [single]
        } else {
            datafields = defaults.datafields
        }
        primaryAttributeChoice = value(.primaryAttributeChoice, or: defaults.primaryAttributeChoice)
        secondaryAttributeChoice = value(.secondaryAttributeChoice, or: defaults.secondaryAttributeChoice)
        glucoseColorScheme = value(.glucoseColorScheme, or: defaults.glucoseColorScheme)
        isWatchfaceDataEnabled = value(.isWatchfaceDataEnabled, or: defaults.isWatchfaceDataEnabled)
        // Missing (saved by an older version) or unreadable: commands stay off.
        isCommandControlEnabled = value(.isCommandControlEnabled, or: false)
        isBolusCommandEnabled = isCommandControlEnabled && value(.isBolusCommandEnabled, or: false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watchface, forKey: .watchface)
        try container.encode(datafields, forKey: .datafields)
        try container.encode(primaryAttributeChoice, forKey: .primaryAttributeChoice)
        try container.encode(secondaryAttributeChoice, forKey: .secondaryAttributeChoice)
        try container.encode(glucoseColorScheme, forKey: .glucoseColorScheme)
        try container.encode(isWatchfaceDataEnabled, forKey: .isWatchfaceDataEnabled)
        try container.encode(isCommandControlEnabled, forKey: .isCommandControlEnabled)
        try container.encode(isBolusCommandEnabled, forKey: .isBolusCommandEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case watchface
        case datafields
        /// The single datafield saved by older versions; read only.
        case datafield
        case primaryAttributeChoice
        case secondaryAttributeChoice
        case glucoseColorScheme
        case isWatchfaceDataEnabled
        case isCommandControlEnabled
        case isBolusCommandEnabled
    }
}

// MARK: - Devices

/// A Connect IQ device as saved in the plugin's `rawState`.
public struct GarminDevice: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let modelName: String
    public let friendlyName: String

    public init(iqDevice: IQDevice) {
        id = iqDevice.uuid
        modelName = iqDevice.modelName
        friendlyName = iqDevice.friendlyName
    }

    public var iqDevice: IQDevice {
        IQDevice(id: id, modelName: modelName, friendlyName: friendlyName)
    }
}
