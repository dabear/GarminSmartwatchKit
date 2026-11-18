import ConnectIQ
import Foundation
import LoopKit
import Testing

@testable import GarminSmartwatchKit

// MARK: - The command app of the settings

@Suite("Garmin command app") struct GarminCommandAppTests {
    private func settings(_ watchface: GarminWatchface, commands: Bool, isWatchfaceDataEnabled: Bool = true) -> GarminWatchSettings {
        var settings = GarminWatchSettings()
        settings.watchface = watchface
        settings.isCommandControlEnabled = commands
        settings.isWatchfaceDataEnabled = isWatchfaceDataEnabled
        return settings
    }

    @Test(
        "The watchface decides the command app; commands on pick WatchControls next to any other watchface",
        arguments: [
            (GarminWatchface.complication, true, GarminCommandApp.complication),
            (.complication, false, .complication),
            (.trio, true, .watchControls),
            (.swissalpine, true, .watchControls),
            (.trio, false, .none),
            (.swissalpine, false, .none)
        ]
    ) func fromSettings(watchface: GarminWatchface, commands: Bool, expected: GarminCommandApp) {
        #expect(GarminCommandApp(settings(watchface, commands: commands)) == expected)
        #expect(GarminCommandApp(settings(watchface, commands: commands, isWatchfaceDataEnabled: false)) == expected)
    }

    @Test("The bolus switch does not change the command app") func bolusSwitchIrrelevant() {
        var withBolus = settings(.trio, commands: true)
        withBolus.isBolusCommandEnabled = true
        #expect(GarminCommandApp(withBolus) == .watchControls)
    }

    @Test("Each command app has its app UUID; none has no UUID") func appUUIDs() {
        #expect(GarminCommandApp.complication.appUUID == GarminWatchface.complication.watchfaceUUID)
        #expect(GarminCommandApp.watchControls.appUUID == GarminWatchControls.appUUID)
        #expect(GarminCommandApp.none.appUUID == nil)
        #expect(GarminWatchControls.appUUID == UUID(uuidString: "d504737e-8315-48d4-b07e-4c421ffb6f54"))
        #expect(GarminCommandApp.appUUIDs == [GarminWatchface.complication.watchfaceUUID!, GarminWatchControls.appUUID!])
    }

    @Test("The owner the watch reads is the raw value") func rawValues() {
        #expect(GarminCommandApp.complication.rawValue == "complication")
        #expect(GarminCommandApp.watchControls.rawValue == "watchControls")
        #expect(GarminCommandApp.none.rawValue == "none")
        #expect(GarminCommandApp.watchControls.displayName == "Trio-WatchControls")
        #expect(GarminCommandApp.complication.displayName == GarminWatchface.complication.displayName)
    }
}

// MARK: - The manager

/// A minimal host: it answers every read with nothing, so the manager can build a preset list.
private final class FakeSmartwatchHost: SmartwatchManagerDelegate {
    func smartwatchManagerDidUpdateState(_: SmartwatchManager) {}
    func smartwatchManagerWantsDeletion(_: SmartwatchManager) async {}
    func deviceManager(_: DeviceManager, logEventForDeviceIdentifier _: String?, type _: DeviceLogEntryType, message _: String, completion _: ((Error?) -> Void)?) {}
    func issueAlert(_: Alert) async {}
    func retractAlert(identifier _: Alert.Identifier) async {}
    func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_: Alert, at _: Date) async throws {}
    func smartwatchManagerGlucoseDisplayUnit(_: SmartwatchManager) async -> LoopUnit { .milligramsPerDeciliter }
    func smartwatchManager(_: SmartwatchManager, glucoseSamplesSince _: Date) async throws -> [StoredGlucoseSample] { [] }
    func smartwatchManagerLoopState(_: SmartwatchManager) async -> SmartwatchLoopState {
        SmartwatchLoopState(lastLoopCompleted: nil, isClosedLoop: false)
    }
    func smartwatchManagerScheduledBasalRate(_: SmartwatchManager) async -> LoopQuantity? { nil }
    func smartwatchManagerTempBasal(_: SmartwatchManager) async -> DoseEntry? { nil }
    func smartwatchManagerInsulinSensitivity(_: SmartwatchManager) async -> LoopQuantity? { nil }
    func smartwatchManagerCorrectionRange(_: SmartwatchManager) async -> ClosedRange<LoopQuantity>? { nil }
    func smartwatchManagerOverridePresets(_: SmartwatchManager) async -> [TemporaryPreset] { [] }
    func smartwatchManagerActiveOverride(_: SmartwatchManager) async -> TemporaryScheduleOverride? { nil }
    func smartwatchManagerAlertMuteEnd(_: SmartwatchManager) async -> Date? { nil }
    func smartwatchManagerMaximumBolus(_: SmartwatchManager) async -> Double? { nil }
    func smartwatchManagerMaximumCarbEntry(_: SmartwatchManager) async -> Double? { nil }
    func smartwatchManagerSupportedBolusVolumes(_: SmartwatchManager) async -> [Double] { [] }
}

@MainActor private final class CommandAppRig {
    let spy = SpyConnectIQClient()
    let manager = GarminSmartwatchManager()
    /// The manager holds its delegate weakly.
    let host = FakeSmartwatchHost()
    let deviceA = IQDevice(id: UUID(), modelName: "fenix 8", friendlyName: "A")!
    let deviceB = IQDevice(id: UUID(), modelName: "Enduro 3", friendlyName: "B")!

    let complicationUUID = GarminWatchface.complication.watchfaceUUID!
    let trioUUID = GarminWatchface.trio.watchfaceUUID!
    let watchControlsUUID = GarminWatchControls.appUUID!
    let loopgraphUUID = GarminDatafield.loopgraph.datafieldUUID!

    /// No datafields, so the watchface and the command app are all there is to register.
    /// `disconnected` devices are reported not connected before the first registration.
    init(
        watchface: GarminWatchface = .trio,
        commands: Bool = true,
        devices: [Int] = [0, 1],
        disconnected: [Int] = []
    ) {
        manager.connectIQClient = spy
        manager.sendRetryDelay = 0.05
        var settings = GarminWatchSettings()
        settings.watchface = watchface
        settings.datafields = []
        settings.isCommandControlEnabled = commands
        manager.settings = settings
        let all = [deviceA, deviceB]
        for index in disconnected {
            manager.deviceStatusChanged(all[index], status: .notConnected)
        }
        manager.updateDeviceList(devices.map { all[$0] })
    }

    /// Lets the preset push the initial settings queued run first, as it finds no host yet.
    func attachHost() async {
        await settle(0.05)
        manager.smartwatchManagerDelegate = host
    }

    func app(_ uuid: UUID, on device: IQDevice) -> IQApp {
        IQApp(uuid: uuid, store: UUID(), device: device)!
    }

    func key(_ uuid: UUID, on device: IQDevice) -> String {
        manager.deliveryKey(for: app(uuid, on: device))!
    }

    func change(_ change: (inout GarminWatchSettings) -> Void) {
        var settings = manager.settings
        change(&settings)
        manager.settings = settings
    }

    func registrations(of uuid: UUID) -> [UUID] {
        spy.registeredApps.filter { $0.appUUID == uuid }.map(\.deviceUUID)
    }

    /// Everything sent, notices included.
    var allSent: [SpyConnectIQClient.Sent] { spy.sent + spy.notices }

    func sends(to appUUID: UUID, on device: IQDevice? = nil) -> [[String: Any]] {
        (spy.sent + spy.notices)
            .filter { $0.appUUID == appUUID && (device == nil || $0.deviceUUID == device?.uuid) }
            .compactMap { $0.message as? [String: Any] }
    }

    /// The notices an app got, as (active, owner), oldest first.
    func notices(to appUUID: UUID, on device: IQDevice? = nil) -> [Notice] {
        sends(to: appUUID, on: device)
            .filter { $0["req"] as? String == "ownerMode" }
            .map { Notice(active: $0["active"] as? Bool, owner: $0["owner"] as? String) }
    }

    func presets(to appUUID: UUID, on device: IQDevice? = nil) -> [[String: Any]] {
        sends(to: appUUID, on: device).filter { $0["req"] as? String == "presets" }
    }

    func hear(_ message: Any = ["v": 1, "req": "nothing"], from uuid: UUID, on device: IQDevice) {
        manager.receivedMessage(message, from: app(uuid, on: device))
    }

    func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func eventually(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    struct Notice: Equatable {
        let active: Bool?
        let owner: String?

        static func active(_ owner: String) -> Notice { Notice(active: true, owner: owner) }
        static func inactive(_ owner: String) -> Notice { Notice(active: false, owner: owner) }
    }
}

private func carbsCommand(id: String = "3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b") -> [String: Any] {
    [
        "v": 1,
        "req": "command",
        "requestId": id,
        "date": NSNumber(value: UInt64(Date().timeIntervalSince1970 * 1000)),
        "command": "carbs",
        "payload": ["carbs": 10]
    ]
}

@MainActor
@Suite("Garmin command app in the manager", .serialized) struct GarminCommandAppManagerTests {
    // MARK: - Registration

    @Test("WatchControls is registered on every device while commands are on next to a Trio watchface")
    func watchControlsRegistered() {
        let rig = CommandAppRig(watchface: .trio, commands: true)

        #expect(Set(rig.registrations(of: rig.watchControlsUUID)) == [rig.deviceA.uuid, rig.deviceB.uuid])
        #expect(rig.registrations(of: rig.watchControlsUUID).count == 2)
        #expect(rig.registrations(of: rig.trioUUID).count == 2)
        #expect(rig.registrations(of: rig.complicationUUID).isEmpty)
        #expect(rig.manager.currentCommandApp == .watchControls)
    }

    @Test("WatchControls is not registered with commands off, nor next to the Complication watchface")
    func watchControlsNotRegistered() {
        let commandsOff = CommandAppRig(watchface: .trio, commands: false)
        #expect(commandsOff.registrations(of: commandsOff.watchControlsUUID).isEmpty)
        #expect(commandsOff.manager.currentCommandApp == .none)

        let complication = CommandAppRig(watchface: .complication, commands: true)
        #expect(complication.registrations(of: complication.watchControlsUUID).isEmpty)
        #expect(complication.registrations(of: complication.complicationUUID).count == 2)
        #expect(complication.manager.currentCommandApp == .complication)
    }

    @Test("Turning commands on or off registers or drops WatchControls at once")
    func commandsToggleRegistration() {
        let rig = CommandAppRig(watchface: .trio, commands: false)
        #expect(rig.registrations(of: rig.watchControlsUUID).isEmpty)

        rig.change { $0.isCommandControlEnabled = true }
        #expect(rig.registrations(of: rig.watchControlsUUID).count == 2)

        rig.change { $0.isCommandControlEnabled = false }
        // re-registered without it; the SDK has no call to unregister, so the registrations stay at two
        #expect(rig.registrations(of: rig.watchControlsUUID).count == 2)
        #expect(rig.manager.currentCommandApp == .none)
    }

    // MARK: - Active notice

    @Test("The command app gets an active notice on registration, on each device")
    func activeNoticeOnRegistration() {
        let rig = CommandAppRig(watchface: .trio, commands: true)

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.watchControlsUUID, on: device) == [.active("watchControls")])
        }
        #expect(rig.notices(to: rig.trioUUID).isEmpty, "A watchface that is no command app gets no notice")
    }

    @Test("The notice is the v1 ownerMode message")
    func noticeShape() throws {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        let message = try #require(rig.sends(to: rig.watchControlsUUID).first)

        #expect(Set(message.keys) == ["v", "req", "active", "owner"])
        #expect(message["v"] as? Int == 1)
        #expect(message["req"] as? String == "ownerMode")
    }

    @Test("The Complication app is a command app too and gets its notice as the watchface")
    func complicationNotice() {
        let rig = CommandAppRig(watchface: .complication, commands: true)

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.complicationUUID, on: device) == [.active("complication")])
        }
    }

    @Test("Commands off: Complication as the watchface hears nothing but state")
    func complicationSilentWhileCommandsOff() {
        let rig = CommandAppRig(watchface: .complication, commands: false)

        #expect(rig.notices(to: rig.complicationUUID).isEmpty)
        #expect(rig.manager.announcedCommandApps.isEmpty)
    }

    @Test("Commands switched on and off with Complication as the watchface: active, then a stand-down naming no app")
    func complicationCommandsToggled() {
        let rig = CommandAppRig(watchface: .complication, commands: false)
        rig.change { $0.isCommandControlEnabled = true }
        rig.change { $0.isCommandControlEnabled = false }

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.complicationUUID, on: device) == [.active("complication"), .inactive("none")])
        }
        #expect(rig.manager.announcedCommandApps.isEmpty)
    }

    @Test("Without a command app nobody is told anything")
    func noNoticeWithoutCommandApp() {
        let rig = CommandAppRig(watchface: .trio, commands: false)
        #expect(rig.allSent.isEmpty)
    }

    @Test("Every registration repeats the active notice")
    func noticeOnEveryRegistration() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        rig.manager.updateDeviceList([rig.deviceA])
        rig.manager.updateDeviceList([rig.deviceA])

        #expect(rig.notices(to: rig.watchControlsUUID) == [.active("watchControls"), .active("watchControls"), .active("watchControls")])
    }

    @Test("Turning commands on tells WatchControls it is active")
    func commandsOnNotice() {
        let rig = CommandAppRig(watchface: .trio, commands: false)
        rig.change { $0.isCommandControlEnabled = true }

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.watchControlsUUID, on: device) == [.active("watchControls")])
        }
    }

    // MARK: - Inactive notice

    @Test("Commands turned off with a Trio watchface: WatchControls is told it is not the command app")
    func inactiveWhenCommandsOff() {
        let rig = CommandAppRig(watchface: .trio, commands: true)
        rig.change { $0.isCommandControlEnabled = false }

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.watchControlsUUID, on: device) == [.active("watchControls"), .inactive("none")])
        }
    }

    @Test("Switching to the Complication watchface: WatchControls stands down and Complication is activated")
    func inactiveWhenComplicationChosen() {
        let rig = CommandAppRig(watchface: .trio, commands: true)
        rig.change { $0.watchface = .complication }

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.watchControlsUUID, on: device) == [.active("watchControls"), .inactive("complication")])
            #expect(rig.notices(to: rig.complicationUUID, on: device) == [.active("complication")])
        }
        #expect(rig.notices(to: rig.trioUUID).isEmpty)
    }

    @Test("Switching from Complication to a Trio watchface: Complication stands down and WatchControls is activated")
    func inactiveWhenComplicationLeft() {
        let rig = CommandAppRig(watchface: .complication, commands: true)
        rig.change { $0.watchface = .trio }

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.notices(to: rig.complicationUUID, on: device) == [.active("complication"), .inactive("watchControls")])
            #expect(rig.notices(to: rig.watchControlsUUID, on: device) == [.active("watchControls")])
        }
    }

    @Test("Switching from Complication with commands off: it was never told it is active, so it is told nothing")
    func inactiveToNone() {
        let rig = CommandAppRig(watchface: .complication, commands: false)
        rig.change { $0.watchface = .swissalpine }

        #expect(rig.notices(to: rig.complicationUUID).isEmpty)
    }

    @Test("A change that keeps the command app tells it nothing new beyond the re-registration")
    func unchangedCommandApp() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        rig.change { $0.watchface = .swissalpine }

        #expect(rig.notices(to: rig.watchControlsUUID) == [.active("watchControls"), .active("watchControls")])
        #expect(rig.notices(to: rig.watchControlsUUID).allSatisfy { $0.active == true })
    }

    @Test("The inactive notice goes out even to a disconnected device, and is not owed")
    func inactiveNoticeNotOwed() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        let key = rig.key(rig.watchControlsUUID, on: rig.deviceA)
        rig.spy.setResult(.failure_Timeout, for: rig.watchControlsUUID, on: rig.deviceA.uuid)
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)

        rig.change { $0.isCommandControlEnabled = false }
        await rig.settle()

        #expect(rig.notices(to: rig.watchControlsUUID).filter { $0.active == false }.count == 2, "Sent, then once more after the failure")
        #expect(rig.manager.owedDeliveries[key] == nil)
    }

    // MARK: - Owed active notice

    @Test("An active notice for a disconnected device is owed and delivered when it reconnects")
    func owedUntilReconnect() {
        let rig = CommandAppRig(watchface: .trio, commands: true, disconnected: [0])
        let keyA = rig.key(rig.watchControlsUUID, on: rig.deviceA)

        #expect(rig.sends(to: rig.watchControlsUUID, on: rig.deviceA).isEmpty, "No traffic toward a disconnected watch")
        #expect(rig.notices(to: rig.watchControlsUUID, on: rig.deviceB) == [.active("watchControls")])
        #expect(rig.manager.owedDeliveries[keyA]?.commandApp == true)
        #expect(rig.manager.owedDeliveries[rig.key(rig.watchControlsUUID, on: rig.deviceB)] == nil)
        #expect(rig.manager.owedDeliveries[rig.key(rig.trioUUID, on: rig.deviceA)]?.commandApp != true)

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)

        #expect(rig.notices(to: rig.watchControlsUUID, on: rig.deviceA) == [.active("watchControls")])
        #expect(rig.manager.owedDeliveries[keyA] == nil)
        #expect(rig.notices(to: rig.watchControlsUUID, on: rig.deviceB) == [.active("watchControls")], "The other device is not told twice")
    }

    @Test("The owed notice is delivered once, not on every reconnect")
    func owedNoticeOnce() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0], disconnected: [0])

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)

        #expect(rig.notices(to: rig.watchControlsUUID) == [.active("watchControls")])
    }

    @Test("An active notice that failed twice stays owed, and the app's next message delivers it")
    func owedAfterFailure() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        let key = rig.key(rig.watchControlsUUID, on: rig.deviceA)
        // the registration's notice, then its resend, then more once the app is registered again
        rig.spy.setResult(.failure_Timeout, for: rig.watchControlsUUID, on: rig.deviceA.uuid)
        rig.manager.updateDeviceList([rig.deviceA])
        #expect(await rig.eventually { rig.manager.owedDeliveries[key]?.commandApp == true })
        let before = rig.notices(to: rig.watchControlsUUID).count

        rig.spy.setResult(nil, for: rig.watchControlsUUID, on: rig.deviceA.uuid)
        rig.hear(from: rig.watchControlsUUID, on: rig.deviceA)

        #expect(rig.notices(to: rig.watchControlsUUID).count == before + 1)
        #expect(rig.notices(to: rig.watchControlsUUID).last == .active("watchControls"))
        #expect(rig.manager.owedDeliveries[key] == nil)
    }

    @Test("An active notice for an app that is not installed stays owed")
    func owedWhenNotInstalled() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        let key = rig.key(rig.watchControlsUUID, on: rig.deviceA)
        rig.spy.setResult(.failure_AppNotFound, for: rig.watchControlsUUID, on: rig.deviceA.uuid)

        rig.manager.updateDeviceList([rig.deviceA])

        #expect(rig.manager.owedDeliveries[key]?.commandApp == true)
        #expect(rig.manager.absentApps.contains(key))
    }

    @Test("An owed notice is dropped when the app stops being the command app")
    func owedNoticeDropped() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0], disconnected: [0])
        let key = rig.key(rig.watchControlsUUID, on: rig.deviceA)
        #expect(rig.manager.owedDeliveries[key]?.commandApp == true)

        rig.change { $0.watchface = .complication }
        #expect(rig.manager.owedDeliveries[key] == nil)

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        #expect(rig.notices(to: rig.watchControlsUUID).allSatisfy { $0.active == false }, "Never told it is active after it stood down")
    }

    // MARK: - Messages from a command app that is not registered

    @Test("A message from the unregistered command app on a selected device is answered with an inactive notice")
    func unregisteredCommandAppTold() {
        let rig = CommandAppRig(watchface: .complication, commands: true)
        #expect(rig.sends(to: rig.watchControlsUUID).isEmpty)

        rig.hear(from: rig.watchControlsUUID, on: rig.deviceA)

        #expect(rig.notices(to: rig.watchControlsUUID, on: rig.deviceA) == [.inactive("complication")])
        #expect(rig.sends(to: rig.watchControlsUUID, on: rig.deviceB).isEmpty)
        #expect(rig.manager.owedDeliveries.isEmpty)
    }

    @Test("The notice names the current command app, none included", arguments: [
        (GarminWatchface.trio, false, GarminCommandApp.none, "complicationUUID"),
        (.complication, true, .complication, "watchControlsUUID"),
        (.trio, true, .watchControls, "complicationUUID")
    ])
    func noticeNamesCurrent(watchface: GarminWatchface, commands: Bool, current: GarminCommandApp, sender: String) {
        let rig = CommandAppRig(watchface: watchface, commands: commands, devices: [0])
        let uuid = sender == "complicationUUID" ? rig.complicationUUID : rig.watchControlsUUID

        rig.hear("status", from: uuid, on: rig.deviceA)

        // With commands off, an app never told it is active hears nothing but state.
        #expect(rig.notices(to: uuid) == (commands ? [.inactive(current.rawValue)] : []))
        #expect(rig.manager.currentCommandApp == current)
    }

    @Test("A message from a command app on a device that isn't selected is ignored")
    func unselectedDeviceIgnored() async {
        let rig = CommandAppRig(watchface: .complication, commands: true, devices: [0])

        rig.hear(from: rig.watchControlsUUID, on: rig.deviceB)
        rig.hear(carbsCommand(), from: rig.watchControlsUUID, on: rig.deviceB)
        rig.hear(carbsCommand(), from: rig.complicationUUID, on: rig.deviceB)
        await rig.settle()

        #expect(rig.sends(to: rig.watchControlsUUID).isEmpty)
        #expect(rig.allSent.filter { $0.deviceUUID == rig.deviceB.uuid }.isEmpty)
    }

    @Test("A message from an unregistered app that is no command app is ignored")
    func unregisteredOtherAppIgnored() async {
        let rig = CommandAppRig(watchface: .complication, commands: true, devices: [0])
        let before = rig.allSent.count

        rig.hear(from: rig.loopgraphUUID, on: rig.deviceA)
        rig.hear(carbsCommand(), from: rig.loopgraphUUID, on: rig.deviceA)
        rig.hear(from: rig.trioUUID, on: rig.deviceA)
        await rig.settle()

        #expect(rig.allSent.count == before)
    }

    @Test("A message from the registered command app is not answered with a notice")
    func registeredCommandAppNotTold() {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        let before = rig.allSent.count

        rig.hear(from: rig.watchControlsUUID, on: rig.deviceA)

        #expect(rig.allSent.count == before)
    }

    @Test("A command from the unregistered command app gets an inactive notice and a refusal ack")
    func unregisteredCommandAppCommandRefused() async throws {
        let rig = CommandAppRig(watchface: .complication, commands: true, devices: [0])
        let request = carbsCommand()

        rig.hear(request, from: rig.watchControlsUUID, on: rig.deviceA)

        #expect(rig.notices(to: rig.watchControlsUUID) == [.inactive("complication")])
        #expect(await rig.eventually { rig.sends(to: rig.watchControlsUUID).contains { $0["req"] as? String == "ack" } })
        let ack = try #require(rig.sends(to: rig.watchControlsUUID).first { $0["req"] as? String == "ack" })
        #expect(ack["requestId"] as? String == request["requestId"] as? String)
        #expect(ack["acknowledged"] as? Bool == false)
        #expect(ack["message"] as? String == "Commands are handled by another watch app.")
    }

    @Test("The unregistered command app's status and presets requests get a notice and nothing else")
    func unregisteredCommandAppReadsIgnored() async {
        let rig = CommandAppRig(watchface: .complication, commands: true, devices: [0])
        let before = rig.allSent.count

        rig.hear("status", from: rig.watchControlsUUID, on: rig.deviceA)
        rig.hear(["v": 1, "req": "status"], from: rig.watchControlsUUID, on: rig.deviceA)
        rig.hear(["v": 1, "req": "presets"], from: rig.watchControlsUUID, on: rig.deviceA)
        await rig.settle()

        let added = rig.allSent.dropFirst(before).compactMap { $0.message as? [String: Any] }
        #expect(added.count == 3)
        #expect(added.allSatisfy { $0["req"] as? String == "ownerMode" && $0["active"] as? Bool == false })
        #expect(rig.sends(to: rig.complicationUUID).filter { $0["req"] as? String != "ownerMode" }.isEmpty, "No state refresh")
    }

    // MARK: - Presets

    private func presetPushes(commandApp rig: CommandAppRig) async {
        await rig.attachHost()
        rig.manager.pushPresetsToCommandApp(triggeredBy: "Test")
        await rig.settle()
    }

    @Test("Presets go only to WatchControls when it is the command app, on every device")
    func presetsToWatchControls() async {
        let rig = CommandAppRig(watchface: .trio, commands: true)
        await presetPushes(commandApp: rig)

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.presets(to: rig.watchControlsUUID, on: device).count == 1)
        }
        #expect(rig.presets(to: rig.trioUUID).isEmpty)
        #expect(rig.presets(to: rig.complicationUUID).isEmpty)
    }

    @Test("Presets go only to Complication when it is the command app")
    func presetsToComplication() async {
        let rig = CommandAppRig(watchface: .complication, commands: true)
        await presetPushes(commandApp: rig)

        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.presets(to: rig.complicationUUID, on: device).count == 1)
        }
        #expect(rig.presets(to: rig.watchControlsUUID).isEmpty)
    }

    @Test("Without a command app no presets go out")
    func presetsToNobody() async {
        let rig = CommandAppRig(watchface: .trio, commands: false)
        await presetPushes(commandApp: rig)

        #expect(rig.allSent.isEmpty)
    }

    @Test("Commands off: Complication as the watchface gets no preset list, from a push or the host")
    func presetsSilentWhileCommandsOff() async {
        let rig = CommandAppRig(watchface: .complication, commands: false)
        await presetPushes(commandApp: rig)
        rig.manager.hostDataDidChange([.presets, .settings])
        await rig.settle()

        #expect(rig.presets(to: rig.complicationUUID).isEmpty)
        #expect(rig.manager.owedDeliveries.values.allSatisfy { !$0.presets })
    }

    @Test("Commands switched on with Complication as the watchface: it gets the preset list")
    func presetsWhenCommandsTurnedOn() async {
        let rig = CommandAppRig(watchface: .complication, commands: false, devices: [0])
        await rig.attachHost()

        rig.change { $0.isCommandControlEnabled = true }
        #expect(await rig.eventually { rig.presets(to: rig.complicationUUID).count == 1 })
    }

    @Test("Presets go only to registered apps on selected devices")
    func presetsToSelectedDevices() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [1])
        await presetPushes(commandApp: rig)

        #expect(rig.presets(to: rig.watchControlsUUID, on: rig.deviceB).count == 1)
        #expect(rig.presets(to: rig.watchControlsUUID, on: rig.deviceA).isEmpty)
    }

    @Test("Changing the command app sends the presets to the new one only")
    func presetsOnCommandAppChange() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        await rig.attachHost()

        rig.change { $0.watchface = .complication }
        #expect(await rig.eventually { rig.presets(to: rig.complicationUUID).count == 1 })
        await rig.settle()

        #expect(rig.presets(to: rig.complicationUUID).count == 1)
        #expect(rig.presets(to: rig.watchControlsUUID).isEmpty)
        #expect(rig.presets(to: rig.trioUUID).isEmpty)
    }

    @Test("Preset changes on the host reach only the command app")
    func presetsOnHostChange() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0])
        await rig.attachHost()

        rig.manager.hostDataDidChange(.presets)
        #expect(await rig.eventually { rig.presets(to: rig.watchControlsUUID).count == 1 })
        await rig.settle()

        #expect(rig.presets(to: rig.watchControlsUUID).count == 1)
        #expect(rig.presets(to: rig.trioUUID).isEmpty)
    }

    @Test("Presets that can't be delivered stay owed for the command app")
    func presetsOwedWhenDisconnected() async {
        let rig = CommandAppRig(watchface: .trio, commands: true, devices: [0], disconnected: [0])
        await presetPushes(commandApp: rig)

        let key = rig.key(rig.watchControlsUUID, on: rig.deviceA)
        #expect(rig.manager.owedDeliveries[key]?.presets == true)
        #expect(rig.manager.owedDeliveries[rig.key(rig.trioUUID, on: rig.deviceA)]?.presets != true)
        #expect(rig.presets(to: rig.watchControlsUUID).isEmpty)
    }
}
