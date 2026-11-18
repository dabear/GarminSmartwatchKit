import ConnectIQ
import Foundation
import Testing

@testable import GarminSmartwatchKit

/// Stands in for the Connect IQ SDK: records every registration and send, and answers sends with
/// scripted results, immediately or only when the test completes them. The protocol has no
/// app-status call, so there is nothing here to ask a watch for readiness.
/// Used from the main actor only.
final class SpyConnectIQClient: GarminConnectIQClient, @unchecked Sendable {
    struct Sent {
        let message: Any
        let appUUID: UUID
        let deviceUUID: UUID
    }

    /// Everything sent except command app notices, which are kept apart in `notices`: they go out with
    /// every registration, and the delivery counts below are about state, presets and acks.
    private(set) var sent: [Sent] = []
    private(set) var notices: [Sent] = []
    private(set) var registeredDevices: [UUID] = []
    private(set) var registeredApps: [(appUUID: UUID, deviceUUID: UUID)] = []
    /// Sends made off the main thread; delivery state lives on main, so this stays 0.
    private(set) var offMainSends = 0

    /// When on, a send is not answered until `completePending` is called.
    var holdsCompletions = false
    private var pending: [(sent: Sent, completion: (IQSendMessageResult) -> Void)] = []

    private var scripted: [String: [IQSendMessageResult]] = [:]
    private var persistent: [String: IQSendMessageResult] = [:]

    private func target(_ appUUID: UUID, _ deviceUUID: UUID) -> String { "\(appUUID)-\(deviceUUID)" }

    /// Consumed in order before falling back to the persistent result, then `.success`.
    func script(_ results: [IQSendMessageResult], for appUUID: UUID, on deviceUUID: UUID) {
        scripted[target(appUUID, deviceUUID), default: []] += results
    }

    func setResult(_ result: IQSendMessageResult?, for appUUID: UUID, on deviceUUID: UUID) {
        persistent[target(appUUID, deviceUUID)] = result
    }

    func registerDevice(_ device: IQDevice, delegate _: IQDeviceEventDelegate) {
        registeredDevices.append(device.uuid)
    }

    func registerApp(_ app: IQApp, delegate _: IQAppMessageDelegate) {
        let deviceUUID: UUID = app.device.uuid
        registeredApps.append((app.uuid, deviceUUID))
    }

    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void) {
        let deviceUUID: UUID = app.device.uuid
        let record = Sent(message: message, appUUID: app.uuid, deviceUUID: deviceUUID)
        if !Thread.isMainThread { offMainSends += 1 }
        if (message as? [String: Any])?["req"] as? String == "ownerMode" {
            notices.append(record)
        } else {
            sent.append(record)
        }
        if holdsCompletions {
            pending.append((record, completion))
            return
        }
        completion(nextResult(for: record))
    }

    private func nextResult(for record: Sent) -> IQSendMessageResult {
        let key = target(record.appUUID, record.deviceUUID)
        if var queue = scripted[key], !queue.isEmpty {
            let next = queue.removeFirst()
            scripted[key] = queue
            return next
        }
        return persistent[key] ?? .success
    }

    var pendingCount: Int { pending.count }

    /// Answers every held send with its scripted result, from a background queue as the SDK may.
    func completePending(onBackground: Bool = false) {
        let held = pending
        pending = []
        for entry in held {
            let result = nextResult(for: entry.sent)
            if onBackground {
                DispatchQueue.global().async { entry.completion(result) }
            } else {
                entry.completion(result)
            }
        }
    }
}

/// Shared with the threading tests.
@MainActor
final class DeliveryRig {
    let spy = SpyConnectIQClient()
    let manager = GarminSmartwatchManager()
    let deviceA = IQDevice(id: UUID(), modelName: "fenix 8", friendlyName: "A")!
    let deviceB = IQDevice(id: UUID(), modelName: "Enduro 3", friendlyName: "B")!

    let watchfaceUUID = GarminWatchface.complication.watchfaceUUID!
    let swissalpineUUID = GarminDatafield.swissalpine.datafieldUUID!
    let trioFieldUUID = GarminDatafield.trio.datafieldUUID!
    let loopgraphUUID = GarminDatafield.loopgraph.datafieldUUID!

    /// The complication watch app and the Swissalpine datafield on both devices unless told otherwise.
    init(
        watchface: GarminWatchface = .complication,
        isWatchfaceDataEnabled: Bool = true,
        datafields: [GarminDatafield] = [.swissalpine],
        devices: [Int] = [0, 1]
    ) {
        manager.connectIQClient = spy
        manager.sendRetryDelay = 0.05
        var settings = GarminWatchSettings()
        settings.watchface = watchface
        settings.isWatchfaceDataEnabled = isWatchfaceDataEnabled
        settings.datafields = datafields
        manager.settings = settings
        let all = [deviceA, deviceB]
        manager.updateDeviceList(devices.map { all[$0] })
    }

    func app(_ uuid: UUID, on device: IQDevice) -> IQApp {
        IQApp(uuid: uuid, store: UUID(), device: device)!
    }

    func key(_ uuid: UUID, on device: IQDevice) -> String {
        manager.deliveryKey(for: app(uuid, on: device))!
    }

    func payload(_ sgv: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: [["sgv": sgv, "direction": "Flat"]])
    }

    func broadcast(_ sgv: Int) {
        manager.broadcastWatchStateData(payload(sgv))
    }

    func sends(to appUUID: UUID? = nil, on device: IQDevice? = nil) -> [SpyConnectIQClient.Sent] {
        spy.sent.filter {
            (appUUID == nil || $0.appUUID == appUUID) && (device == nil || $0.deviceUUID == device?.uuid)
        }
    }

    /// A message from an app that is neither a status request nor a command, so it only proves the channel.
    func hearFrom(_ uuid: UUID, on device: IQDevice) {
        manager.receivedMessage(["v": 1, "req": "nothing"], from: app(uuid, on: device))
    }

    /// Lets queued main-queue work run before asserting that nothing more was sent.
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
}

@MainActor
@Suite("Garmin delivery by send result", .serialized) struct GarminDeliveryTests {
    // MARK: - Broadcast

    @Test("Each registered app gets one send per broadcast; a confirmed state is skipped, a changed one is sent")
    func oneSendPerApp() {
        let rig = DeliveryRig()
        #expect(rig.spy.registeredApps.count == 4)

        rig.broadcast(120)
        #expect(rig.spy.sent.count == 4)
        for device in [rig.deviceA, rig.deviceB] {
            #expect(rig.sends(to: rig.watchfaceUUID, on: device).count == 1)
            #expect(rig.sends(to: rig.swissalpineUUID, on: device).count == 1)
        }
        #expect(rig.manager.lastSentDataHashes.count == 4)

        rig.broadcast(120)
        #expect(rig.spy.sent.count == 4, "The same confirmed state is not sent again")

        rig.broadcast(121)
        #expect(rig.spy.sent.count == 8)
    }

    @Test("The payload goes out as the parsed JSON of the broadcast data")
    func payloadIsParsedJSON() throws {
        let rig = DeliveryRig(datafields: [], devices: [0])
        rig.broadcast(120)
        let message = try #require(rig.spy.sent.first?.message as? [[String: Any]])
        #expect(message.first?["sgv"] as? Int == 120)
    }

    @Test("Sends go straight out: there is no app-status call and no waiting before a send")
    func noStatusBeforeSending() {
        let rig = DeliveryRig()
        rig.broadcast(120)
        // Synchronously after the broadcast: every app was already sent to, nothing but sends happened.
        #expect(rig.spy.sent.count == 4)
        #expect(rig.spy.pendingCount == 0)
        // Registration is the only other traffic: two devices, four apps.
        #expect(rig.spy.registeredDevices.count == 2)
        #expect(rig.spy.registeredApps.count == 4)
    }

    @Test("A completion that arrives off the main queue still settles the delivery state")
    func completionHopsToMain() async {
        let rig = DeliveryRig(datafields: [], devices: [0])
        rig.spy.holdsCompletions = true
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 1)
        #expect(rig.manager.lastSentDataHashes.isEmpty, "Nothing is confirmed before the SDK answers")

        rig.spy.completePending(onBackground: true)
        #expect(await rig.eventually { rig.manager.lastSentDataHashes.count == 1 })

        rig.broadcast(120)
        #expect(rig.spy.sent.count == 1)
    }

    @Test("Without the watchface enabled only the datafields get sent to")
    func watchfaceDisabled() {
        let rig = DeliveryRig(isWatchfaceDataEnabled: false, devices: [0])
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 1)
        #expect(rig.sends(to: rig.watchfaceUUID).isEmpty)
        #expect(rig.sends(to: rig.swissalpineUUID).count == 1)
    }

    // MARK: - App not installed

    @Test("AppNotFound marks the app absent without a resend and keeps the state owed")
    func appNotFound() async {
        let rig = DeliveryRig()
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)

        let key = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        #expect(rig.spy.sent.count == 4)
        #expect(rig.manager.absentApps == [key])
        #expect(rig.manager.owedDeliveries[key]?.stateHash != nil)
        #expect(rig.manager.lastSentDataHashes[key] == nil)

        await rig.settle()
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 1, "No resend for an app that is not installed")
    }

    @Test("An absent app is skipped on later broadcasts while the others still get them")
    func absentAppSkipped() async {
        let rig = DeliveryRig()
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        rig.broadcast(121)
        await rig.settle()

        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 1)
        #expect(rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 2)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceB).count == 2)
        // The newest state is what it is owed.
        let key = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        #expect(rig.manager.owedDeliveries[key]?.stateHash != nil)
    }

    @Test("A message from an absent app clears it and delivers the owed state at once")
    func messageClearsAbsent() async {
        let rig = DeliveryRig()
        let key = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(rig.manager.absentApps == [key])

        rig.spy.setResult(nil, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.hearFrom(rig.swissalpineUUID, on: rig.deviceA)

        #expect(rig.manager.absentApps.isEmpty)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 2, "The owed state is sent right away")
        #expect(rig.manager.owedDeliveries[key] == nil)
        #expect(rig.manager.lastSentDataHashes[key] != nil)

        await rig.settle()
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 2)
        #expect(rig.spy.sent.count == 5, "Only the owed app was sent to again")
    }

    @Test("A message from an app that is not registered changes nothing")
    func messageFromUnregisteredApp() async {
        let rig = DeliveryRig()
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        let before = rig.spy.sent.count

        rig.hearFrom(rig.loopgraphUUID, on: rig.deviceA)
        rig.hearFrom(rig.swissalpineUUID, on: IQDevice(id: UUID(), modelName: "fenix 8", friendlyName: "Stranger")!)
        await rig.settle()

        #expect(rig.spy.sent.count == before)
        #expect(rig.manager.absentApps == [rig.key(rig.swissalpineUUID, on: rig.deviceA)])
    }

    @Test("Registering the devices again lets an absent app be tried")
    func reRegistrationClearsAbsent() {
        let rig = DeliveryRig()
        let key = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(rig.manager.absentApps == [key])

        rig.spy.setResult(nil, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.manager.updateDeviceList([rig.deviceA, rig.deviceB])
        #expect(rig.manager.absentApps.isEmpty)
        #expect(rig.manager.owedDeliveries[key] != nil, "Still owed: re-registration only gives permission to retry")

        // Registered apps get the next state even if it is unchanged.
        rig.broadcast(120)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 2)
        #expect(rig.manager.owedDeliveries[key] == nil)
        #expect(rig.manager.lastSentDataHashes[key] != nil)
    }

    // MARK: - Other failures

    @Test("Another failure is resent exactly once after the retry delay")
    func resendOnce() async {
        let rig = DeliveryRig(datafields: [], devices: [0])
        rig.spy.script([.failure_Timeout, .success], for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 1, "The resend waits for the delay")

        #expect(await rig.eventually { rig.spy.sent.count == 2 })
        let key = rig.key(rig.watchfaceUUID, on: rig.deviceA)
        #expect(await rig.eventually { rig.manager.lastSentDataHashes[key] != nil })
        #expect(rig.manager.owedDeliveries[key] == nil)

        await rig.settle()
        #expect(rig.spy.sent.count == 2)
    }

    @Test("When the resend fails too, no third attempt is made and the state stays owed")
    func failedResendStaysOwed() async {
        let rig = DeliveryRig(datafields: [], devices: [0])
        rig.spy.setResult(.failure_DeviceIsBusy, for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(await rig.eventually { rig.spy.sent.count == 2 })

        let key = rig.key(rig.watchfaceUUID, on: rig.deviceA)
        #expect(await rig.eventually { rig.manager.owedDeliveries[key]?.stateHash != nil })
        await rig.settle()
        #expect(rig.spy.sent.count == 2)
        #expect(rig.manager.lastSentDataHashes[key] == nil)
        #expect(rig.manager.absentApps.isEmpty)
    }

    @Test("A state that failed for good goes out with the next broadcast, even an unchanged one")
    func owedStateGoesOutWithNextBroadcast() async {
        let rig = DeliveryRig()
        rig.spy.script([.failure_Timeout, .failure_Timeout], for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(await rig.eventually { rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 2 })
        let key = rig.key(rig.watchfaceUUID, on: rig.deviceA)
        #expect(await rig.eventually { rig.manager.owedDeliveries[key] != nil })

        rig.broadcast(120)
        #expect(rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 3)
        #expect(rig.manager.owedDeliveries[key] == nil)
        #expect(rig.manager.lastSentDataHashes[key] != nil)
        await rig.settle()
        #expect(rig.spy.sent.count == 6, "Four first sends, one resend, and only the owed app sent the unchanged state again")
    }

    @Test("A reconnect delivers the state a device's app is owed")
    func characteristicsDeliverOwedState() async {
        let rig = DeliveryRig()
        rig.spy.script([.failure_Timeout, .failure_Timeout], for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        let key = rig.key(rig.watchfaceUUID, on: rig.deviceA)
        #expect(await rig.eventually { rig.manager.owedDeliveries[key] != nil })
        let before = rig.spy.sent.count

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        #expect(rig.spy.sent.count == before + 1)
        #expect(rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 3)
        #expect(rig.manager.owedDeliveries[key] == nil)
        #expect(rig.manager.lastSentDataHashes[key] != nil)
        #expect(rig.sends(on: rig.deviceB).count == 2, "The other device was not sent to again")
    }

    @Test("A newer confirmed state replaces what an app was owed")
    func newerStateSupersedesOwed() async {
        let rig = DeliveryRig(datafields: [], devices: [0])
        let key = rig.key(rig.watchfaceUUID, on: rig.deviceA)
        rig.spy.script([.failure_Timeout, .failure_Timeout], for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(await rig.eventually { rig.manager.owedDeliveries[key] != nil })
        #expect(rig.spy.sent.count == 2)

        rig.broadcast(121)
        #expect(rig.spy.sent.count == 3)
        #expect(rig.manager.owedDeliveries[key] == nil)
        let last = rig.spy.sent.last?.message as? [[String: Any]]
        #expect(last?.first?["sgv"] as? Int == 121)

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        await rig.settle()
        #expect(rig.spy.sent.count == 3, "The older owed state is not sent after the newer one")
    }

    // MARK: - Connection

    @Test("A disconnected device is skipped with its state owed; the others are sent to")
    func disconnectedDeviceSkipped() async {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(120)

        #expect(rig.sends(on: rig.deviceA).isEmpty, "No SDK traffic toward a disconnected watch")
        #expect(rig.sends(on: rig.deviceB).count == 2)
        #expect(rig.manager.owedDeliveries[rig.key(rig.watchfaceUUID, on: rig.deviceA)]?.stateHash != nil)
        #expect(rig.manager.owedDeliveries[rig.key(rig.swissalpineUUID, on: rig.deviceA)]?.stateHash != nil)
        #expect(rig.manager.owedDeliveries[rig.key(rig.watchfaceUUID, on: rig.deviceB)] == nil)

        rig.broadcast(121)
        await rig.settle()
        #expect(rig.sends(on: rig.deviceA).isEmpty)
        #expect(rig.sends(on: rig.deviceB).count == 4)
    }

    @Test("Characteristics discovered lets a disconnected device send again and flushes its owed state")
    func characteristicsReconnect() {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(120)
        #expect(rig.sends(on: rig.deviceA).isEmpty)

        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        #expect(rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 1)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 1)
        #expect(rig.manager.owedDeliveries.isEmpty)

        rig.broadcast(121)
        #expect(rig.sends(on: rig.deviceA).count == 4, "The device is no longer skipped")
    }

    @Test("A device reported connected again is sent to by the next broadcast")
    func connectedStatusReopensGate() {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(120)
        #expect(rig.sends(on: rig.deviceA).isEmpty)

        rig.manager.deviceStatusChanged(rig.deviceA, status: .connected)
        // It never confirmed this state, so the same payload still goes out.
        rig.broadcast(120)
        #expect(rig.sends(to: rig.watchfaceUUID, on: rig.deviceA).count == 1)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 1)
        #expect(rig.manager.owedDeliveries.isEmpty)
        #expect(rig.sends(on: rig.deviceB).count == 2, "Nothing more for the device that was never away")
    }

    @Test("Every status that is not connected stops sends, and connected restores them")
    func statusesThatStopSends() {
        let rig = DeliveryRig(datafields: [], devices: [0])
        let statuses: [IQDeviceStatus] = [.notConnected, .notFound, .bluetoothNotReady, .invalidDevice]
        for (index, status) in statuses.enumerated() {
            rig.manager.deviceStatusChanged(rig.deviceA, status: status)
            rig.broadcast(100 + index)
            #expect(rig.spy.sent.isEmpty)
        }
        rig.manager.deviceStatusChanged(rig.deviceA, status: .connected)
        rig.broadcast(200)
        #expect(rig.spy.sent.count == 1)
    }

    @Test("Readiness never gates: with no characteristics callback a connected device gets the broadcast")
    func readinessNeverGates() {
        let rig = DeliveryRig()
        // The SDK reported connected but never discovered characteristics.
        rig.manager.deviceStatusChanged(rig.deviceA, status: .connected)
        rig.broadcast(120)
        #expect(rig.sends(on: rig.deviceA).count == 2)
        #expect(rig.sends(on: rig.deviceB).count == 2, "A device with no callback at all is sent to as well")
    }

    // MARK: - Registration

    @Test("Owed entries for apps that are no longer registered are dropped on re-registration")
    func owedDroppedForUnregisteredApps() {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.manager.deviceStatusChanged(rig.deviceB, status: .notConnected)
        rig.broadcast(120)
        #expect(rig.manager.owedDeliveries.count == 4)

        // One device less.
        rig.manager.updateDeviceList([rig.deviceB])
        let kept = Set([rig.key(rig.watchfaceUUID, on: rig.deviceB), rig.key(rig.swissalpineUUID, on: rig.deviceB)])
        #expect(Set(rig.manager.owedDeliveries.keys) == kept)

        // One app less: the datafield is no longer chosen.
        var settings = rig.manager.settings
        settings.datafields = []
        rig.manager.settings = settings
        #expect(Set(rig.manager.owedDeliveries.keys) == [rig.key(rig.watchfaceUUID, on: rig.deviceB)])

        rig.manager.updateDeviceList([])
        #expect(rig.manager.owedDeliveries.isEmpty)
    }

    @Test("Registering again forgets what was confirmed, so the next broadcast reaches every app")
    func reRegistrationResends() {
        let rig = DeliveryRig()
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 4)

        rig.manager.updateDeviceList([rig.deviceA, rig.deviceB])
        #expect(rig.manager.lastSentDataHashes.isEmpty)
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 8)
    }

    // MARK: - Several datafields

    @Test("Each chosen datafield on each device gets its own send and its own delivery key")
    func severalDatafields() {
        let rig = DeliveryRig(isWatchfaceDataEnabled: false, datafields: [.trio, .swissalpine, .loopgraph])
        #expect(rig.spy.registeredApps.count == 6)

        rig.broadcast(120)
        #expect(rig.spy.sent.count == 6)
        let fields = [rig.trioFieldUUID, rig.swissalpineUUID, rig.loopgraphUUID]
        var keys = Set<String>()
        for uuid in fields {
            for device in [rig.deviceA, rig.deviceB] {
                #expect(rig.sends(to: uuid, on: device).count == 1)
                keys.insert(rig.key(uuid, on: device))
            }
        }
        #expect(keys.count == 6)
        #expect(Set(rig.manager.lastSentDataHashes.keys) == keys)
    }

    @Test("A datafield that fails does not hold back the others, which are confirmed on their own")
    func datafieldsFailIndependently() async {
        let rig = DeliveryRig(isWatchfaceDataEnabled: false, datafields: [.trio, .swissalpine, .loopgraph], devices: [0])
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.spy.script([.failure_Timeout, .failure_Timeout], for: rig.loopgraphUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)

        let trioKey = rig.key(rig.trioFieldUUID, on: rig.deviceA)
        let swissKey = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        let loopKey = rig.key(rig.loopgraphUUID, on: rig.deviceA)
        #expect(await rig.eventually { rig.manager.owedDeliveries[loopKey] != nil })

        #expect(rig.manager.lastSentDataHashes[trioKey] != nil)
        #expect(rig.manager.absentApps == [swissKey])
        #expect(rig.sends(to: rig.loopgraphUUID).count == 2)
        #expect(Set(rig.manager.owedDeliveries.keys) == [swissKey, loopKey])

        rig.broadcast(120)
        #expect(rig.sends(to: rig.trioFieldUUID).count == 1, "The confirmed datafield is not sent the unchanged state")
        #expect(rig.sends(to: rig.swissalpineUUID).count == 1, "The absent datafield is skipped")
        #expect(rig.sends(to: rig.loopgraphUUID).count == 3, "The owed datafield gets it again")
    }
}
