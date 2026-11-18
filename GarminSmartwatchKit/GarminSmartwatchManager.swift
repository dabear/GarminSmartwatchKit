//
//  GarminSmartwatchManager.swift
//  GarminSmartwatchKit
//
//  From Trio's GarminManager (Trio contributors, MIT), as a SmartwatchManager plugin.
//

import Combine
import ConnectIQ
import Foundation
import LoopKit
#if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
    import UIKit
#endif

// MARK: - Connect IQ Client

/// The Connect IQ calls that register and reach watch apps, behind a protocol so delivery can be
/// tested without a watch. There is deliberately no app-status call: each one is a BLE round trip.
/// From mountrcg's Garmin delivery rework (MIT).
protocol GarminConnectIQClient: AnyObject {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate)
    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate)
    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void)
}

extension ConnectIQ: GarminConnectIQClient {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate) {
        register(forDeviceEvents: device, delegate: delegate)
    }

    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate) {
        register(forAppMessages: app, delegate: delegate)
    }

    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void) {
        sendMessage(message, to: app, progress: { _, _ in }, completion: completion)
    }
}

/// Garmin (Connect IQ) as a watch plugin. **Experimental.**
///
/// It sends the host's glucose, loop status and therapy values to the chosen
/// Connect IQ watchface or watch app and datafields, built only from what it
/// reads from the host. Watch apps can send commands (carbs, bolus, presets)
/// only while the user has turned them on (`GarminCommandProcessor`).
/// Devices and settings are saved in its `rawState`.
public final class GarminSmartwatchManager: NSObject {
    public static let pluginIdentifier = "GarminSmartwatchManager"
    public static let localizedTitle = LocalizedString("Garmin", comment: "Title of the Garmin watch manager")

    /// Connect IQ is set up once per launch, though the plugin may be added more than once.
    private static var isConnectIQInitialized = false

    public weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    /// Fires on the main queue when the devices, settings or Garmin Connect's
    /// availability change, for the settings screen.
    public let stateDidChange = PassthroughSubject<Void, Never>()

    /// Garmin ConnectIQ shared instance for watch interactions.
    private let connectIQ = ConnectIQ.sharedInstance()

    /// Keeps references to watch apps (both watchface & data field) for each registered device.
    private var watchApps: [IQApp] = []

    /// A set of Combine cancellables for managing the lifecycle of various subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// Holds a promise used when the user is selecting devices (via `showDeviceSelection()`).
    private var deviceSelectionPromise: Future<[IQDevice], Never>.Promise?

    /// Subject for debouncing watch state updates
    private let watchStateSubject = PassthroughSubject<Data, Never>()

    /// Registers and messages watch apps; the shared Connect IQ instance unless a test sets a spy.
    var connectIQClient: GarminConnectIQClient? = ConnectIQ.sharedInstance()

    /// Wait before the single resend of a failed message.
    var sendRetryDelay: TimeInterval = 2

    // MARK: - Delivery

    /// What an app is still owed after its send failed for good; the latest state wins. Main queue only.
    struct OwedDelivery: Equatable {
        var stateHash: Int?
        var presets = false
        /// The active command app notice.
        var commandApp = false
    }

    /// The send result is the readiness signal: readiness never gates a send, because a missed
    /// characteristics callback would otherwise block delivery until the next reconnect.
    private(set) var owedDeliveries: [String: OwedDelivery] = [:]

    /// Apps that answered `AppNotFound`, skipped until re-registration or a message from them.
    private(set) var absentApps: Set<String> = []

    /// The only send gate, set by the SDK's device status callbacks.
    private(set) var disconnectedDevices: Set<UUID> = []

    /// Latest broadcast payload, sent again to apps that are owed state.
    private var lastBroadcast: (payload: Any, hash: Int)?

    /// Command apps sent an active notice and not yet told to stand down, by `deliveryKey(for:)`.
    /// While commands are off, only these get a notice, so an app never told it is active hears
    /// nothing but state, as from Trio without the command app series. Saved in `rawState`, so a
    /// stand-down missed before a relaunch is still sent when the app next sends anything.
    private(set) var announcedCommandApps: Set<String> = [] {
        didSet {
            guard announcedCommandApps != oldValue, !isDeleted else { return }
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }

    /// Stand-downs that failed for good, with the app to tell (it may no longer be registered), by
    /// `deliveryKey(for:)`. Sent again on the next delivery, reconnect or message on that device.
    private(set) var owedStandDowns: [String: IQApp] = [:]

    /// Apps that asked for state: the next broadcast goes to them even when unchanged, whatever an
    /// older send's completion confirms in the meantime. Consumed by that broadcast.
    private(set) var forcedStateKeys: Set<String> = []

    /// Hash of the last state each app confirmed receiving, keyed by `deliveryKey(for:)`.
    private(set) var lastSentDataHashes: [String: Int] = [:]

    /// Set on the main queue by `delete()`: nothing is sent or retried after it, whatever is still queued.
    private(set) var isDeleted = false

    // MARK: - Commands

    /// Advanced when a command switch is turned off; commands admitted before then are refused.
    let commandAuthorization = GarminCommandAuthorization()

    /// Checks and runs the watch apps' commands; one per manager, so its request cache sees every request.
    @MainActor private lazy var commandProcessor = GarminCommandProcessor(
        host: self,
        authorization: commandAuthorization,
        log: { [weak self] in self?.log($0) }
    )

    /// Garmin Connect isn't installed: device selection and sending can't work.
    public private(set) var isConnectMobileMissing = false

    // MARK: - Host data

    /// What the plugin last read from the host, the only source of the watch state.
    /// Written when a read finishes, read where the watch state is prepared.
    private let hostDataLock = NSLock()
    private var storedHostData: GarminHostData?
    private var latestHostData: GarminHostData? {
        get { hostDataLock.withLock { storedHostData } }
        set { hostDataLock.withLock { storedHostData = newValue } }
    }

    /// Whether the host shows glucose in mmol/L, for the settings screen's labels;
    /// `false` before the host data is read.
    public var isMillimolesPerLiterHost: Bool {
        latestHostData?.displayUnit == .millimolesPerLiter
    }

    /// The read in progress; a newer change replaces it, as the read gets everything.
    private var readTask: Task<Void, Never>?

    /// The forecast lines last written to the device log; the loop state is read
    /// with every reading, the forecast is logged only when it changes.
    private var loggedForecast: [String] = []

    // MARK: - State

    /// The watch apps and display choices; changing them re-registers or resends as needed.
    public var settings: GarminWatchSettings {
        willSet {
            // Before the new value is stored, so a command already checked can't
            // pass its last check after a switch was turned off.
            commandAuthorization.settingsWillChange(from: settings, to: newValue)
        }
        didSet {
            guard settings != oldValue else { return }
            settingsDidChange(from: oldValue)
            stateDidChange.send()
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }

    /// Array of Garmin `IQDevice` objects currently tracked.
    /// Changing this property triggers re-registration and saves the devices.
    public private(set) var devices: [IQDevice] = [] {
        didSet {
            registerDevices(devices)
            stateDidChange.send()
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }

    // MARK: - Initialization

    public override init() {
        settings = GarminWatchSettings()
        super.init()
        start(devices: [])
    }

    public init?(rawState: RawStateValue) {
        let decoder = JSONDecoder()
        settings = (rawState["settings"] as? Data).flatMap { try? decoder.decode(GarminWatchSettings.self, from: $0) }
            ?? GarminWatchSettings()
        let saved = (rawState["devices"] as? Data).flatMap { try? decoder.decode([GarminDevice].self, from: $0) } ?? []
        announcedCommandApps = Set(rawState["announcedCommandApps"] as? [String] ?? [])
        super.init()
        start(devices: saved.map(\.iqDevice))
    }

    private func start(devices saved: [IQDevice]) {
        if !Self.isConnectIQInitialized {
            if let scheme = Self.hostURLScheme {
                connectIQ?.initialize(withUrlScheme: scheme, uiOverrideDelegate: self)
                Self.isConnectIQInitialized = true
            }
        }
        subscribeToWatchState()
        devices = saved
    }

    /// The host app's URL scheme, which Garmin Connect calls back with the chosen devices.
    static var hostURLScheme: String? {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return types?.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }

    /// The host's device log.
    private func log(type: DeviceLogEntryType = .connection, _ message: String) {
        smartwatchManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: nil, type: type, message: message, completion: nil)
    }

    // MARK: - Settings Helpers

    private var currentWatchface: GarminWatchface { settings.watchface }
    private var currentDatafields: [GarminDatafield] { settings.datafields }
    private var isWatchfaceDataEnabled: Bool { settings.isWatchfaceDataEnabled }

    /// The only watch app whose commands run, and the only one that gets the preset list.
    var currentCommandApp: GarminCommandApp { GarminCommandApp(settings) }

    /// Returns the display name for an app UUID (watchface or datafield).
    private func appDisplayName(for uuid: UUID) -> String {
        if uuid == currentWatchface.watchfaceUUID {
            return "watchface:\(currentWatchface.displayName)"
        } else if let datafield = currentDatafields.first(where: { $0.datafieldUUIDs.contains(uuid) }) {
            return "datafield:\(datafield.displayName)"
        } else if uuid == GarminWatchControls.appUUID {
            return "watch app:\(GarminWatchControls.displayName)"
        } else {
            return "unknown app"
        }
    }

    /// Returns the display name including UUID, for registration and errors.
    private func appDetailedName(for uuid: UUID) -> String {
        "\(appDisplayName(for: uuid)) (\(uuid.uuidString))"
    }

    // MARK: - Updates

    /// Prepares the watch state from the latest host data and sends it to the debounce subject.
    private func triggerWatchStateUpdate(triggeredBy trigger: String) {
        guard !isDeleted, !devices.isEmpty, let data = watchStateData() else { return }
        watchStateSubject.send(data)
    }

    /// The watch state as the watch apps read it; `nil` before the host data is read.
    func watchStateData() -> Data? {
        guard let host = latestHostData else { return nil }
        let options = GarminWatchState.DisplayOptions(
            primaryAttributeChoice: settings.primaryAttributeChoice.rawValue,
            secondaryAttributeChoice: settings.secondaryAttributeChoice.rawValue,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            historySpan: settings.historySpan,
            historySpacing: settings.watchface.historySpacing,
            // Each chosen watch app's forecast format; none when all are off.
            forecastFormats: settings.forecastFormats(),
            timeInRangePeriod: settings.isTimeInRangeEnabled ? settings.timeInRangePeriod : nil,
            timeInRangeTarget: settings.timeInRangeTarget
        )
        return try? JSONEncoder().encode(GarminWatchState.states(from: host, options: options))
    }

    /// Re-registers when the watch apps change; resends when what they show changes.
    private func settingsDidChange(from old: GarminWatchSettings) {
        let commandAppChanged = GarminCommandApp(settings) != GarminCommandApp(old)
        if settings.watchface != old.watchface || settings.datafields != old.datafields
            || settings.isWatchfaceDataEnabled != old.isWatchfaceDataEnabled || commandAppChanged
        {
            log("Garmin watchface or datafields changed, re-registering devices")
            registerDevices(devices)
        }
        triggerWatchStateUpdate(triggeredBy: "Settings")
        // Complication stays the command app when commands are switched, so it isn't
        // re-registered: tell it here.
        if settings.isCommandControlEnabled != old.isCommandControlEnabled, !commandAppChanged {
            for app in watchApps where app.uuid != nil && app.uuid == currentCommandApp.appUUID {
                sendCommandAppNotice(to: app, isActive: settings.isCommandControlEnabled)
            }
        }
        // The command app builds its menus from the switches.
        if settings.isCommandControlEnabled != old.isCommandControlEnabled
            || settings.isBolusCommandEnabled != old.isBolusCommandEnabled
            || settings.watchface != old.watchface || settings.isWatchfaceDataEnabled != old.isWatchfaceDataEnabled
            || commandAppChanged
        {
            Task { @MainActor in self.pushPresetsToCommandApp(triggeredBy: "Settings") }
        }
    }

    // MARK: - Device & App Registration

    /// Registers the given devices for ConnectIQ events (device status changes) and watch app messages.
    /// It also creates and registers watch apps (watchface + data field) for each device.
    /// - Parameter devices: The devices to register.
    private func registerDevices(_ devices: [IQDevice]) {
        guard !isDeleted else { return }
        let previousApps = watchApps
        watchApps.removeAll()

        // Newly registered apps get the next state even if it is unchanged.
        lastSentDataHashes.removeAll()
        // Re-registration is the retry permission for apps that answered AppNotFound.
        absentApps.removeAll()

        for device in devices {
            connectIQClient?.registerDevice(device, delegate: self)

            // Register watchface if enabled
            if isWatchfaceDataEnabled,
               let watchfaceUUID = currentWatchface.watchfaceUUID,
               let watchfaceApp = IQApp(uuid: watchfaceUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: watchfaceUUID))")
                watchApps.append(watchfaceApp)
                connectIQClient?.registerApp(watchfaceApp, delegate: self)
            } else if !isWatchfaceDataEnabled {
                log("Garmin watchface data disabled, watchface not registered")
            }

            // Every chosen datafield; all of them get the same broadcast.
            for datafieldUUID in currentDatafields.flatMap(\.datafieldUUIDs) {
                guard let datafieldApp = IQApp(uuid: datafieldUUID, store: UUID(), device: device) else { continue }
                log("Registered Garmin \(appDetailedName(for: datafieldUUID))")
                watchApps.append(datafieldApp)
                connectIQClient?.registerApp(datafieldApp, delegate: self)
            }

            // Trio-WatchControls only while it is the command app.
            if currentCommandApp == .watchControls,
               let watchControlsUUID = GarminWatchControls.appUUID,
               let watchControlsApp = IQApp(uuid: watchControlsUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: watchControlsUUID))")
                watchApps.append(watchControlsApp)
                connectIQClient?.registerApp(watchControlsApp, delegate: self)
            }
        }
        let registeredKeys = Set(watchApps.compactMap(deliveryKey(for:)))
        owedDeliveries = owedDeliveries.filter { registeredKeys.contains($0.key) }
        forcedStateKeys.formIntersection(registeredKeys)
        let deviceUUIDs = Set(devices.map(\.uuid))
        owedStandDowns = owedStandDowns.filter { $0.value.device.map { deviceUUIDs.contains($0.uuid) } == true }

        // Every registered command app is the current one; a command app no longer registered stands down.
        for app in watchApps where app.uuid.map(GarminCommandApp.appUUIDs.contains) == true {
            sendCommandAppNotice(to: app, isActive: true)
        }
        for app in previousApps where app.uuid.map(GarminCommandApp.appUUIDs.contains) == true {
            guard let key = deliveryKey(for: app), !registeredKeys.contains(key) else { continue }
            sendCommandAppNotice(to: app, isActive: false)
        }
    }

    /// Read by both command apps, Trio-WatchControls and Complication. The active notice is owed
    /// like state; a stand-down that failed is owed in `owedStandDowns`, and an app that missed it
    /// is told again as soon as it sends anything.
    ///
    /// While commands are off, no active notice goes out, and a stand-down only to an app that was
    /// told it is active or is owed one.
    private func sendCommandAppNotice(to app: IQApp, isActive: Bool) {
        guard !isDeleted, let key = deliveryKey(for: app), let device = app.device else { return }
        if isActive {
            guard settings.isCommandControlEnabled else { return }
            announcedCommandApps.insert(key)
            owedStandDowns[key] = nil
        } else {
            let wasOwed = owedStandDowns.removeValue(forKey: key) != nil
            guard announcedCommandApps.contains(key) || settings.isCommandControlEnabled || wasOwed else { return }
        }
        let appName = appDisplayName(for: app.uuid)
        // With commands off no app takes commands, whichever the watchface makes the command app.
        let owner = settings.isCommandControlEnabled ? currentCommandApp : .none
        let notice = GarminCommandEnvelope.commandAppNotice(isActive: isActive, commandApp: owner)
        guard !isActive || isReachable(key: key, device: device, appName: appName) else {
            recordOwed(for: key, commandApp: true)
            return
        }
        log("Sending command app notice to Garmin \(appName), \(isActive ? "active" : "inactive")")
        sendMessage(notice, to: app, appName: appName, announcesCommandApp: isActive, standsDownCommandApp: !isActive)
    }

    // MARK: - Simulator Support

    #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
        /// Mock IQDevice class for simulator testing
        /// Minimal implementation just for testing - no actual Garmin functionality
        public class MockIQDevice: IQDevice {
            private let _uuid: UUID
            private let _friendlyName: String
            private let _modelName: String

            public override var uuid: UUID { _uuid }
            public override var friendlyName: String { _friendlyName }
            public override var modelName: String { _modelName }
            public var status: IQDeviceStatus { .connected }

            public init(uuid: UUID, friendlyName: String, modelName: String) {
                _uuid = uuid
                _friendlyName = friendlyName
                _modelName = modelName
                super.init()
            }

            @available(*, unavailable) required init?(coder _: NSCoder) {
                fatalError("init(coder:) not implemented for mock device")
            }

            /// Shared simulated device UUID for consistency across the app
            public static let simulatedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                ?? UUID()

            /// Creates the standard simulated Enduro 3 device
            public static func createSimulated() -> MockIQDevice {
                MockIQDevice(
                    uuid: simulatedUUID,
                    friendlyName: "Enduro 3 Sim",
                    modelName: "Enduro 3"
                )
            }

            /// A mock Garmin Connect's answer: `<scheme>://device-select-resp?name=…&model=…&uuid=…`.
            static func parseSelection(from url: URL) -> [IQDevice] {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                guard let name = value("name") else { return [] }
                return [MockIQDevice(
                    uuid: value("uuid").flatMap(UUID.init(uuidString:)) ?? simulatedUUID,
                    friendlyName: name,
                    modelName: value("model") ?? name
                )]
            }
        }

        /// Garmin Connect can't run in the simulator (and a local test build can set
        /// `GARMIN_MOCK_CONNECT` to use the mock on a phone): a mock Garmin Connect app
        /// (`garminconnect-mock://`) answers through the host's URL scheme like the real one,
        /// so the app switch and the callback are the same. Without it, the simulated watch is chosen.
        private func showMockDeviceSelection() {
            let scheme = Self.hostURLScheme ?? ""
            let fallback = URL(string: "\(scheme)://device-select-resp?name=Enduro%203%20Sim&model=Enduro%203")!
            guard let mock = URL(string: "garminconnect-mock://device-select?scheme=\(scheme)") else { return }
            UIApplication.shared.open(mock) { [weak self] opened in
                guard !opened else { return }
                _ = self?.hostDidReceiveURL(fallback)
            }
        }
    #endif

    // MARK: - Combine Subscriptions

    /// Subscribes to watch state updates with debouncing
    private func subscribeToWatchState() {
        watchStateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] data in
                self?.broadcastWatchStateData(data)
            }
            .store(in: &cancellables)
    }

    // MARK: - Parsing & Broadcasting

    /// Parses devices from Garmin Connect's device-selection callback (via the host) and
    /// updates our `devices` property.
    /// - Parameter url: The URL provided by Garmin Connect containing device selection info.
    private func parseDevices(for url: URL) {
        connectMobileIsAvailable()
        #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
            let parsed: [IQDevice]? = MockIQDevice.parseSelection(from: url)
        #else
            let parsed = connectIQ?.parseDeviceSelectionResponse(from: url) as? [IQDevice]
        #endif
        devices = parsed ?? []
        deviceSelectionPromise?(.success(devices))
        deviceSelectionPromise = nil
    }

    /// Sends the state once to every registered app that hasn't confirmed this exact state yet.
    func broadcastWatchStateData(_ data: Data) {
        guard !isDeleted else { return }
        // Stable content-based hash (sorted JSON bytes)
        let currentHash: Int
        if let sortedData = try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: data, options: []),
            options: [.sortedKeys]
        ) {
            currentHash = sortedData.base64EncodedString().hashValue
        } else {
            currentHash = data.count // Fallback
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            log(type: .error, "Garmin watch state is not valid JSON")
            return
        }
        lastBroadcast = (jsonObject, currentHash)

        for app in watchApps {
            guard let key = deliveryKey(for: app), let device = app.device else { continue }
            let appName = appDisplayName(for: app.uuid)

            if lastSentDataHashes[key] == currentHash, owedDeliveries[key]?.stateHash == nil, !forcedStateKeys.contains(key) {
                log("Garmin \(appName) skipped, data unchanged")
                continue
            }
            // An unreachable app is owed this state instead.
            forcedStateKeys.remove(key)
            guard isReachable(key: key, device: device, appName: appName) else {
                recordOwed(for: key, stateHash: currentHash)
                continue
            }
            log("Sending state to Garmin \(appName)")
            sendMessage(jsonObject, to: app, appName: appName, stateHash: currentHash)
        }
    }

    // MARK: - Delivery

    func deliveryKey(for app: IQApp) -> String? {
        guard let appUUID = app.uuid, let deviceUUID = app.device?.uuid else { return nil }
        return "\(appUUID.uuidString)-\(deviceUUID.uuidString)"
    }

    /// SDK completions aren't documented to arrive on main; delivery state lives there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Skipping keeps whatever the app is owed for the next trigger.
    private func isReachable(key: String, device: IQDevice, appName: String) -> Bool {
        if absentApps.contains(key) {
            log("Garmin \(appName) skipped, app not installed")
            return false
        }
        if disconnectedDevices.contains(device.uuid) {
            log("Garmin \(appName) skipped, device disconnected")
            return false
        }
        return true
    }

    /// Acks are never owed: the watch expires an unanswered command itself.
    private func recordOwed(for key: String, stateHash: Int? = nil, presets: Bool = false, commandApp: Bool = false) {
        guard stateHash != nil || presets || commandApp else { return }
        var owed = owedDeliveries[key] ?? OwedDelivery()
        if let stateHash { owed.stateHash = stateHash }
        owed.presets = owed.presets || presets
        owed.commandApp = owed.commandApp || commandApp
        owedDeliveries[key] = owed
    }

    /// A stand-down not delivered stays owed, unless the app is the command app again meanwhile or its
    /// device is no longer selected.
    private func recordOwedStandDown(to app: IQApp, key: String) {
        guard !isEntitledCommandApp(app), devices.contains(where: { $0.uuid == app.device?.uuid }) else { return }
        owedStandDowns[key] = app
    }

    /// Any delivered message proves the channel, so what the app is still owed goes out now.
    private func flushOwed(to app: IQApp, key: String, appName: String) {
        guard !isDeleted, let owed = owedDeliveries.removeValue(forKey: key) else { return }
        if owed.stateHash != nil, let broadcast = lastBroadcast, lastSentDataHashes[key] != broadcast.hash {
            log("Sending owed state to Garmin \(appName)")
            sendMessage(broadcast.payload, to: app, appName: appName, stateHash: broadcast.hash)
        }
        if owed.commandApp, app.uuid == currentCommandApp.appUUID {
            sendCommandAppNotice(to: app, isActive: true)
        }
        if owed.presets {
            Task { @MainActor in self.pushPresets(to: [app], triggeredBy: "OwedDelivery") }
        }
    }

    /// Sends again on the triggers that occur anyway (broadcast, reconnect, a message from the app)
    /// instead of timers.
    private func flushOwed(on device: IQDevice) {
        guard !isDeleted else { return }
        for app in watchApps where app.device?.uuid == device.uuid {
            guard let key = deliveryKey(for: app), !absentApps.contains(key) else { continue }
            flushOwed(to: app, key: key, appName: appDisplayName(for: app.uuid))
        }
        flushStandDowns(on: device.uuid)
    }

    /// The device is reachable, so command apps on it that missed their stand-down are told again.
    private func flushStandDowns(on deviceUUID: UUID) {
        guard !isDeleted else { return }
        for (key, app) in owedStandDowns where app.device?.uuid == deviceUUID {
            guard !isEntitledCommandApp(app) else {
                owedStandDowns[key] = nil
                continue
            }
            sendCommandAppNotice(to: app, isActive: false)
        }
    }

    /// The registered current command app while commands are on: the only app whose commands run.
    private func isEntitledCommandApp(_ app: IQApp) -> Bool {
        guard settings.isCommandControlEnabled, let uuid = app.uuid, uuid == currentCommandApp.appUUID else { return false }
        return watchApps.contains { $0.uuid == uuid && $0.device?.uuid == app.device?.uuid }
    }

    /// An app installed or updated while the host runs answers again after a reconnect, so the
    /// device's apps are tried again instead of waiting for a re-registration.
    private func clearAbsentMarks(on deviceUUID: UUID) {
        let keys = watchApps.filter { $0.device?.uuid == deviceUUID }.compactMap(deliveryKey(for:))
        absentApps.subtract(keys)
    }

    // MARK: - Devices

    /// Prompts the user to select one or more Garmin devices, returning a publisher that emits
    /// the final array of selected devices once the user finishes selection.
    /// - Returns: An `AnyPublisher` emitting `[IQDevice]` on success, or empty array on error/timeout.
    public func selectDevices() -> AnyPublisher<[IQDevice], Never> {
        Future { [weak self] promise in
            guard let self = self else {
                promise(.success([]))
                return
            }
            self.deviceSelectionPromise = promise
            #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
                self.showMockDeviceSelection()
            #else
                self.connectIQ?.showDeviceSelection()
            #endif
        }
        .timeout(.seconds(120), scheduler: DispatchQueue.main)
        .replaceEmpty(with: [])
        .eraseToAnyPublisher()
    }

    /// Updates the manager's list of devices, typically after user selection or manual changes.
    /// - Parameter devices: The new array of `IQDevice` objects to track.
    public func updateDeviceList(_ devices: [IQDevice]) {
        self.devices = devices
    }

    /// Sends the given watch state data to the debounce subject for eventual broadcast.
    /// - Parameter data: JSON-encoded data representing the latest watch state.
    public func sendWatchStateData(_ data: Data) {
        watchStateSubject.send(data)
    }

    // MARK: - Helper: Sending Messages

    /// Sends with one resend after `sendRetryDelay` for other failures; a final failure leaves the
    /// state or preset list owed. `AppNotFound` is never resent: the app isn't installed.
    func sendMessage(
        _ msg: Any,
        to app: IQApp,
        appName: String,
        stateHash: Int? = nil,
        isPresets: Bool = false,
        announcesCommandApp: Bool = false,
        standsDownCommandApp: Bool = false,
        isRetry: Bool = false
    ) {
        // Covers a resend still waiting for its delay and anything queued before `delete()`.
        guard !isDeleted else { return }
        connectIQClient?.send(msg, to: app) { [weak self] result in
            self?.onMain {
                // A late completion after `delete()` must not flush owed sends.
                guard let self, !self.isDeleted, let key = self.deliveryKey(for: app) else { return }
                switch result {
                case .success:
                    self.log("Sent to Garmin \(appName)")
                    self.absentApps.remove(key)
                    if let stateHash { self.lastSentDataHashes[key] = stateHash }
                    if standsDownCommandApp { self.announcedCommandApps.remove(key) }
                    self.flushOwed(to: app, key: key, appName: appName)
                    if let deviceUUID = app.device?.uuid { self.flushStandDowns(on: deviceUUID) }
                case .failure_AppNotFound:
                    self.log("Garmin \(appName) not installed, skipped until re-registered or heard from")
                    self.absentApps.insert(key)
                    self.recordOwed(for: key, stateHash: stateHash, presets: isPresets, commandApp: announcesCommandApp)
                default:
                    let reason = NSStringFromSendMessageResult(result) ?? "\(result.rawValue)"
                    if isRetry {
                        self.log(type: .error, "Sending to Garmin \(appName) failed after retry (\(reason))")
                        self.recordOwed(for: key, stateHash: stateHash, presets: isPresets, commandApp: announcesCommandApp)
                        if standsDownCommandApp { self.recordOwedStandDown(to: app, key: key) }
                    } else {
                        self.log(type: .error, "Sending to Garmin \(appName) failed, retrying (\(reason))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.sendRetryDelay) { [weak self] in
                            self?.sendMessage(
                                msg,
                                to: app,
                                appName: appName,
                                stateHash: stateHash,
                                isPresets: isPresets,
                                announcesCommandApp: announcesCommandApp,
                                standsDownCommandApp: standsDownCommandApp,
                                isRetry: true
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Connect IQ delegates

extension GarminSmartwatchManager: IQUIOverrideDelegate, IQDeviceEventDelegate, IQAppMessageDelegate {
    // MARK: - IQUIOverrideDelegate

    /// Garmin Connect isn't installed: a host alert (device selection and sending
    /// can't work without it), and a warning with a link in the settings.
    public func needsToInstallConnectMobile() {
        log(type: .error, "Garmin Connect app not available; install it from the App Store")
        if let delegate = smartwatchManagerDelegate {
            let alert = Self.connectMobileMissingAlertContent()
            Task { await delegate.issueAlert(alert) }
        }
        DispatchQueue.main.async {
            self.isConnectMobileMissing = true
            self.stateDidChange.send()
        }
    }

    static let connectMobileMissingAlertIdentifier = Alert.Identifier(
        managerIdentifier: pluginIdentifier,
        alertIdentifier: "connectMobileMissing"
    )

    /// Garmin Connect missing: a warning, so time-sensitive (a host shows a plugin's alerts at most that).
    static func connectMobileMissingAlertContent() -> Alert {
        let content = Alert.Content(
            title: LocalizedString("Garmin Connect isn't installed", comment: "Garmin alert title: Garmin Connect missing"),
            body: LocalizedString("Install Garmin Connect from the App Store to choose Garmin watches and send them glucose.", comment: "Garmin alert body: Garmin Connect missing"),
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Garmin alert acknowledge button")
        )
        return Alert(
            identifier: connectMobileMissingAlertIdentifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        )
    }

    /// Withdraws the alert from the host.
    private func retractConnectMobileMissingAlert() {
        guard let delegate = smartwatchManagerDelegate else { return }
        Task { await delegate.retractAlert(identifier: Self.connectMobileMissingAlertIdentifier) }
    }

    /// Garmin Connect answered, so it's installed: the alert no longer applies.
    private func connectMobileIsAvailable() {
        guard isConnectMobileMissing else { return }
        isConnectMobileMissing = false
        retractConnectMobileMissingAlert()
        stateDidChange.send()
    }

    /// Opens Garmin Connect in the App Store.
    public func showAppStoreForConnectMobile() {
        connectIQ?.showAppStoreForConnectMobile()
    }

    // MARK: - IQDeviceEventDelegate

    /// Called whenever the status of a registered Garmin device changes (e.g., connected, not found, etc.).
    /// Only a lost connection stops sends; nothing here costs a round trip to the watch.
    /// - Parameters:
    ///   - device: The device whose status has changed.
    ///   - status: The new status for the device.
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        // The SDK's callback thread is undocumented; delivery state lives on main.
        nonisolated(unsafe) let device = device
        onMain { [weak self] in self?.handleDeviceStatus(device, status: status) }
    }

    private func handleDeviceStatus(_ device: IQDevice, status: IQDeviceStatus) {
        // Always log connection state changes - critical for diagnosing SDK issues
        switch status {
        case .invalidDevice:
            log(type: .error, "Garmin device invalid")
            disconnectedDevices.insert(device.uuid)
        case .bluetoothNotReady:
            log("Garmin device unavailable, Bluetooth not ready")
            disconnectedDevices.insert(device.uuid)
        case .notFound:
            log("Garmin device not found")
            disconnectedDevices.insert(device.uuid)
        case .notConnected:
            log("Garmin device disconnected")
            disconnectedDevices.insert(device.uuid)
        case .connected:
            log("Garmin device connected")
            disconnectedDevices.remove(device.uuid)
            clearAbsentMarks(on: device.uuid)
        @unknown default:
            log("Garmin device status unknown (\(status.rawValue))")
        }
    }

    /// Called when device characteristics are discovered (SDK 1.8+). It doesn't gate sends,
    /// but a reconnect is a good moment to send what the watch apps are owed.
    /// - Parameter device: The device whose characteristics have been discovered.
    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        nonisolated(unsafe) let device = device
        onMain { [weak self] in self?.handleCharacteristicsDiscovered(device) }
    }

    private func handleCharacteristicsDiscovered(_ device: IQDevice) {
        guard !isDeleted else { return }
        log("Garmin device connected and ready")
        disconnectedDevices.remove(device.uuid)
        // A datafield or watchface installed or updated meanwhile gets what it is owed now.
        clearAbsentMarks(on: device.uuid)
        flushOwed(on: device)

        // Trigger a data send now that device is ready
        // This ensures newly connected devices get data promptly
        triggerWatchStateUpdate(triggeredBy: "DeviceReady")
    }

    // MARK: - IQAppMessageDelegate

    /// Called when a message arrives from a Garmin watch app (watchface, datafield or
    /// command app). Status requests refresh the broadcast state; preset requests
    /// and commands are answered only to the app that sent them.
    /// - Parameters:
    ///   - message: The message content from the watch app.
    ///   - app: The watch app sending the message.
    public func receivedMessage(_ message: Any, from app: IQApp) {
        // The SDK's callback thread is undocumented; the registered apps and delivery state live on main.
        // Connect IQ messages are plain property-list values.
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let app = app
        onMain { [weak self] in self?.handleMessage(message, from: app) }
    }

    private func handleMessage(_ message: Any, from app: IQApp) {
        guard !isDeleted else { return }
        guard let appUUID = app.uuid else {
            log("Ignored message from Garmin app without UUID")
            return
        }
        let appName = appDisplayName(for: appUUID)
        let registered = watchApps.first { $0.uuid == appUUID && $0.device?.uuid == app.device?.uuid }
        let isRegistered = registered != nil
        let registeredKey = registered.flatMap(deliveryKey(for:))

        // A message from the app proves the channel, so it gets what it is owed right away.
        let isOnSelectedDevice = devices.contains { $0.uuid == app.device?.uuid }
        let isCommandAppUUID = GarminCommandApp.appUUIDs.contains(appUUID)
        if let registered, let registeredKey {
            absentApps.remove(registeredKey)
            // A registered command app with commands off may have missed its stand-down (before a
            // relaunch, too); it hears one only if it was told it is active or is owed one.
            if isCommandAppUUID, !isEntitledCommandApp(registered) {
                sendCommandAppNotice(to: registered, isActive: false)
            }
            flushOwed(to: registered, key: registeredKey, appName: appName)
        } else if isCommandAppUUID, isOnSelectedDevice {
            // It still acts as the command app, so it missed the notice to stand down.
            sendCommandAppNotice(to: app, isActive: false)
        }
        if isOnSelectedDevice, let deviceUUID = app.device?.uuid {
            flushStandDowns(on: deviceUUID)
        }
        // Only on a selected device: any other watch must not reach the processor.
        let isCommandApp = GarminCommandApp.appUUIDs.contains(appUUID) && isOnSelectedDevice
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let app = app

        Task { @MainActor [weak self] in
            guard let self, !self.isDeleted else { return }
            let router = GarminCommandRouter(processor: self.commandProcessor, log: { [weak self] in self?.log($0) })
            let outcome = await router.route(
                message,
                from: appUUID,
                isRegistered: isRegistered,
                isCommandApp: isCommandApp,
                appName: appName
            )
            guard !self.isDeleted else { return }

            if let reply = outcome.reply {
                let isPresetsReply = reply[GarminMessageKey.request] as? String == GarminCommandEnvelope.Request.presets.rawValue
                if isPresetsReply, !self.settings.isCommandControlEnabled {
                    // While commands are off the watch apps get only state, as from upstream Trio.
                    self.log("Garmin presets request from \(appName) not answered, commands are off")
                } else if isPresetsReply, appUUID != self.currentCommandApp.appUUID {
                    // Only the command app gets the preset list.
                    self.log("Garmin presets request from \(appName) not answered, it isn't the command app")
                } else {
                    self.sendTargetedResponse(reply, to: app, appName: appName)
                }
            }
            if outcome.refreshesState {
                // The app is asking, so answer even when nothing changed: a freshly opened
                // watch app or glance has no data until it gets a send. A flag rather than
                // clearing the confirmed hash, which an older send's success could write back.
                if let registeredKey { self.forcedStateKeys.insert(registeredKey) }
                self.triggerWatchStateUpdate(triggeredBy: "WatchRequest")
            }
            if outcome.pushesPresets {
                self.pushPresetsToCommandApp(triggeredBy: "WatchCommand")
            }
        }
    }

    /// Sends the preset list, switches and limits to the command app on every device.
    @MainActor func pushPresetsToCommandApp(triggeredBy trigger: String) {
        guard let commandAppUUID = currentCommandApp.appUUID else { return }
        pushPresets(to: watchApps.filter { $0.uuid == commandAppUUID }, triggeredBy: trigger)
    }

    /// Targeted like an ack, so it never touches the state broadcast or its duplicate check.
    /// A push that can't be delivered stays owed like state.
    /// Nothing while commands are off: the watch apps then get only state.
    @MainActor private func pushPresets(to targets: [IQApp], triggeredBy trigger: String) {
        guard !isDeleted, !targets.isEmpty, smartwatchManagerDelegate != nil, settings.isCommandControlEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let response = GarminCommandEnvelope.presetsResponse(await self.commandProcessor.presets())
            guard !self.isDeleted else { return }
            self.log("Sending Garmin preset list (\(trigger))")
            for app in targets {
                guard let key = self.deliveryKey(for: app), let device = app.device else { continue }
                let appName = self.appDisplayName(for: app.uuid)
                guard self.isReachable(key: key, device: device, appName: appName) else {
                    self.recordOwed(for: key, presets: true)
                    continue
                }
                self.sendTargetedResponse(response, to: app, appName: appName, isPresets: true)
            }
        }
    }

    /// Answers one app directly. Never routed through `broadcastWatchStateData`, whose
    /// duplicate check would otherwise suppress the next state update or send command
    /// data to other apps.
    private func sendTargetedResponse(_ response: [String: Any], to app: IQApp, appName: String, isPresets: Bool = false) {
        let kind = response[GarminMessageKey.request] as? String ?? "response"
        log("Sending Garmin \(kind) to \(appName)")
        sendMessage(response, to: app, appName: appName, isPresets: isPresets)
    }
}

// MARK: - SmartwatchManager

extension GarminSmartwatchManager: SmartwatchManager {
    public var rawState: RawStateValue {
        let encoder = JSONEncoder()
        var state: RawStateValue = [:]
        state["settings"] = try? encoder.encode(settings)
        state["devices"] = try? encoder.encode(devices.map(GarminDevice.init))
        state["announcedCommandApps"] = Array(announcedCommandApps).sorted()
        return state
    }

    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }
    public var isOnboarded: Bool { true }
    // A watch has no signal or operable state of its own here.
    public var inSignalLoss: Bool { false }
    public var isInoperable: Bool { false }

    @MainActor
    public func hostDataDidChange(_ changes: SmartwatchHostDataChange) {
        // The watch shows glucose, loop output, basal, sensitivity, target and the display unit.
        guard !isDeleted, !changes.isDisjoint(with: [.glucose, .loop, .presets, .settings]),
              let delegate = smartwatchManagerDelegate
        else { return }
        // Presets or limits (maximum bolus, maximum carbs) may have changed.
        if !changes.isDisjoint(with: [.presets, .settings]) {
            pushPresetsToCommandApp(triggeredBy: "Host")
        }
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            let host = await self.readHostData(from: delegate)
            guard !Task.isCancelled else { return }
            self.latestHostData = host
            self.logForecast(host?.loopState.predictedGlucose ?? [])
            self.triggerWatchStateUpdate(triggeredBy: "Host")
        }
    }

    /// Device log only, to check the cone sent against the host's forecasts.
    @MainActor
    private func logForecast(_ curves: [[PredictedGlucoseValue]]) {
        let lines = GarminWatchState.forecastLogLines(curves)
        guard lines != loggedForecast else { return }
        loggedForecast = lines
        lines.forEach { log($0) }
    }

    /// Reads what the watch shows; `nil` when the readings can't be read.
    private func readHostData(from delegate: SmartwatchManagerDelegate) async -> GarminHostData? {
        let samples: [StoredGlucoseSample]
        do {
            samples = try await delegate.smartwatchManager(self, glucoseSamplesSince: GarminHostData.readingsStart())
        } catch {
            log(type: .error, "Garmin could not read glucose: \(error.localizedDescription)")
            return nil
        }
        return GarminHostData(
            displayUnit: await delegate.smartwatchManagerGlucoseDisplayUnit(self),
            glucoseSamples: samples,
            loopState: await delegate.smartwatchManagerLoopState(self),
            scheduledBasalRate: await delegate.smartwatchManagerScheduledBasalRate(self),
            tempBasal: await delegate.smartwatchManagerTempBasal(self),
            insulinSensitivity: await delegate.smartwatchManagerInsulinSensitivity(self),
            correctionRange: await delegate.smartwatchManagerCorrectionRange(self),
            glucoseDisplayLimits: await delegate.smartwatchManagerGlucoseDisplayLimits(self)
        )
    }

    /// Garmin Connect's device-selection callback.
    @MainActor
    public func hostDidReceiveURL(_ url: URL) -> Bool {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.host == "device-select-resp" else { return false }
        parseDevices(for: url)
        return true
    }

    /// Stops sending: the watch apps get nothing more from the host. The delivery state lives on the
    /// main queue, so it is torn down there; `isDeleted` stops retries, queued pushes and late send
    /// completions from sending anything afterwards.
    public func delete() async {
        await MainActor.run {
            // First: a command waiting in the processor (a bolus in the insulin lane) is refused
            // at its final check instead of reaching the host, which still has this manager.
            commandAuthorization.revokeAll()
            // Command apps told they are active stand down, so their commands aren't left
            // unanswered; sent once, nothing waits for or retries it.
            let notice = GarminCommandEnvelope.commandAppNotice(isActive: false, commandApp: .none)
            for app in watchApps {
                guard let key = deliveryKey(for: app), announcedCommandApps.contains(key) else { continue }
                let appName = appDisplayName(for: app.uuid)
                log("Sending command app notice to Garmin \(appName), inactive (plugin deleted)")
                connectIQClient?.send(notice, to: app) { _ in }
            }
            isDeleted = true
            readTask?.cancel()
            readTask = nil
            cancellables.removeAll()
            connectIQ?.unregister(forAllDeviceEvents: self)
            connectIQ?.unregister(forAllAppMessages: self)
            watchApps.removeAll()
            owedDeliveries.removeAll()
            lastBroadcast = nil
            absentApps.removeAll()
            announcedCommandApps.removeAll()
            lastSentDataHashes.removeAll()
            owedStandDowns.removeAll()
            forcedStateKeys.removeAll()
        }
        latestHostData = nil
        await smartwatchManagerDelegate?.retractAlert(identifier: Self.connectMobileMissingAlertIdentifier)
        await smartwatchManagerDelegate?.smartwatchManagerWantsDeletion(self)
    }

    public func initializationComplete(for _: [Pluggable]) {}

    public override var debugDescription: String {
        "## GarminSmartwatchManager\n* devices: \(devices.count)\n* settings: \(settings)\n* host data: \(latestHostData == nil ? "none" : "received")"
    }

    /// Nothing to do: the alert only points to the App Store, and it goes away
    /// when Garmin Connect answers.
    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws {}

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}

// MARK: - GarminCommandHost

/// The watch apps' commands reach the host through its delegate. Without one
/// (being deleted), every action is refused and every read is empty.
extension GarminSmartwatchManager: GarminCommandHost {
    var commandSettings: GarminWatchSettings { settings }

    private func actionDelegate() throws -> SmartwatchManagerDelegate {
        guard let delegate = smartwatchManagerDelegate else { throw SmartwatchActionError.notAllowed }
        return delegate
    }

    func deliverBolus(_ units: Double) async throws -> Double {
        try await actionDelegate().smartwatchManager(self, deliverBolus: units)
    }

    func addCarbEntry(_ grams: Double, date: Date) async throws -> Double {
        try await actionDelegate().smartwatchManager(self, addCarbEntry: grams, absorptionTime: nil, date: date)
    }

    func enactOverride(_ presetID: String?) async throws {
        try await actionDelegate().smartwatchManager(self, enactOverride: presetID)
    }

    func enactTempTarget(_ presetID: String?) async throws {
        try await actionDelegate().smartwatchManager(self, enactTempTarget: presetID)
    }

    func overridePresets() async -> [TemporaryPreset] {
        await smartwatchManagerDelegate?.smartwatchManagerOverridePresets(self) ?? []
    }

    func activeOverride() async -> TemporaryScheduleOverride? {
        await smartwatchManagerDelegate?.smartwatchManagerActiveOverride(self)
    }

    func tempTargetPresets() async -> [TemporaryPreset]? {
        await smartwatchManagerDelegate?.smartwatchManagerTempTargetPresets(self)
    }

    func activeTempTarget() async -> TemporaryScheduleOverride? {
        await smartwatchManagerDelegate?.smartwatchManagerActiveTempTarget(self)
    }

    func maximumBolus() async -> Double? {
        await smartwatchManagerDelegate?.smartwatchManagerMaximumBolus(self)
    }

    func maximumCarbEntry() async -> Double? {
        await smartwatchManagerDelegate?.smartwatchManagerMaximumCarbEntry(self)
    }

    func supportedBolusVolumes() async -> [Double] {
        await smartwatchManagerDelegate?.smartwatchManagerSupportedBolusVolumes(self) ?? []
    }
}
