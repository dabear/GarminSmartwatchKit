import Foundation
import Testing

@testable import GarminSmartwatchKit

/// Records what the router asks of its processor and answers with a canned result.
private final class SpyProcessor: GarminCommandProcessing {
    var processed: [GarminWatchCommandRequest] = []
    var presetsRequested = 0
    var result = GarminWatchCommandResult.success(.carbsLogged, "Carbs logged.")
    var presetsResult = GarminWatchCommandPresets(overridePresets: [], tempTargetPresets: [])

    func process(_ request: GarminWatchCommandRequest) async -> GarminWatchCommandResult {
        processed.append(request)
        return result
    }

    func presets() async -> GarminWatchCommandPresets {
        presetsRequested += 1
        return presetsResult
    }
}

private final class LogCapture {
    var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}

@Suite("Garmin command router") struct GarminCommandRouterTests {
    let requestID = "3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b"
    // no digits that an amount below could be confused with
    let appUUID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    let milliseconds: UInt64 = 1_800_000_000_123

    private func envelope(command: String, payload: [String: Any]) -> [String: Any] {
        [
            "v": 1,
            "req": "command",
            "requestId": requestID,
            "date": NSNumber(value: milliseconds),
            "command": command,
            "payload": payload
        ]
    }

    private func route(
        _ message: Any,
        via processor: SpyProcessor,
        registered: Bool = true,
        isCommandApp: Bool = false,
        logs: LogCapture = LogCapture()
    ) async -> GarminCommandRouter.Outcome {
        let router = GarminCommandRouter(processor: processor, log: logs.record)
        return await router.route(message, from: appUUID, isRegistered: registered, isCommandApp: isCommandApp, appName: "test")
    }

    @Test("Status requests refresh the watch state and send no reply")
    func statusRouting() async {
        let messages: [Any] = ["status", ["v": 1, "req": "status"] as [String: Any]]
        for message in messages {
            let processor = SpyProcessor()
            let outcome = await route(message, via: processor)
            #expect(outcome.reply == nil)
            #expect(outcome.refreshesState)
            #expect(outcome.pushesPresets == false)
            #expect(processor.processed.isEmpty)
        }
    }

    @Test("Unregistered apps are ignored without executing or answering")
    func unregisteredApp() async {
        let processor = SpyProcessor()
        let messages: [Any] = [
            envelope(command: "carbs", payload: ["carbs": 10]),
            "status",
            ["v": 1, "req": "presets"] as [String: Any],
            ["v": 1, "req": "command", "requestId": requestID] as [String: Any]
        ]
        for message in messages {
            let outcome = await route(message, via: processor, registered: false)
            #expect(outcome.reply == nil)
            #expect(outcome.refreshesState == false)
            #expect(outcome.pushesPresets == false)
        }
        #expect(processor.processed.isEmpty)
        #expect(processor.presetsRequested == 0)
    }

    @Test("An unregistered command app's command reaches the processor and is answered")
    func unregisteredCommandApp() async throws {
        let processor = SpyProcessor()
        processor.result = .failure("Commands are handled by another watch app.")

        let outcome = await route(
            envelope(command: "carbs", payload: ["carbs": 10]), via: processor, registered: false, isCommandApp: true
        )

        let reply = try #require(outcome.reply)
        #expect(reply["req"] as? String == "ack")
        #expect(reply["requestId"] as? String == requestID)
        #expect(reply["acknowledged"] as? Bool == false)
        #expect(reply["message"] as? String == "Commands are handled by another watch app.")
        #expect(outcome.refreshesState == false)
        #expect(processor.processed.count == 1)
        #expect(processor.processed.first?.appUUID == appUUID)
        #expect(processor.processed.first?.command == .carbs(10))
    }

    @Test("An unregistered command app gets nothing but its commands through")
    func unregisteredCommandAppOtherMessages() async {
        let processor = SpyProcessor()
        let messages: [Any] = [
            "status",
            ["v": 1, "req": "status"] as [String: Any],
            ["v": 1, "req": "presets"] as [String: Any],
            ["v": 1, "req": "ack"] as [String: Any],
            ["v": 1, "req": "ownerMode", "requestId": requestID] as [String: Any],
            ["v": 1, "req": "command", "requestId": requestID] as [String: Any],
            envelope(command: "carbs", payload: ["carbs": "ten"]),
            42
        ]
        for message in messages {
            let outcome = await route(message, via: processor, registered: false, isCommandApp: true)
            #expect(outcome.reply == nil, "\(message)")
            #expect(outcome.refreshesState == false)
            #expect(outcome.pushesPresets == false)
        }
        #expect(processor.presetsRequested == 0)
        #expect(processor.processed.isEmpty)
    }

    @Test("An unregistered app that is not the command app is ignored, commands included")
    func unregisteredNonCommandApp() async {
        let processor = SpyProcessor()
        let messages: [Any] = [
            envelope(command: "carbs", payload: ["carbs": 10]),
            envelope(command: "bolus", payload: ["bolus": 1]),
            "status",
            ["v": 1, "req": "presets"] as [String: Any]
        ]
        for message in messages {
            let outcome = await route(message, via: processor, registered: false, isCommandApp: false)
            #expect(outcome.reply == nil)
            #expect(outcome.refreshesState == false)
            #expect(outcome.pushesPresets == false)
        }
        #expect(processor.processed.isEmpty)
        #expect(processor.presetsRequested == 0)
    }

    @Test("A command refused for an unregistered command app pushes no presets")
    func unregisteredCommandAppRefusalPushesNothing() async {
        let processor = SpyProcessor()
        processor.result = .failure("Commands are handled by another watch app.")
        let outcome = await route(
            envelope(command: "activateOverride", payload: ["name": "Sport"]), via: processor, registered: false, isCommandApp: true
        )
        #expect(outcome.pushesPresets == false)
        #expect(outcome.reply?["acknowledged"] as? Bool == false)
        #expect(processor.processed.count == 1)
    }

    @Test("A preset request gets a targeted presets reply and no refresh")
    func presetsReply() async throws {
        let processor = SpyProcessor()
        processor.presetsResult = GarminWatchCommandPresets(
            overridePresets: [GarminWatchPreset(name: "Sport", isEnabled: true)],
            tempTargetPresets: [GarminWatchPreset(name: "Walk", isEnabled: false)],
            capabilities: GarminWatchCommandCapabilities(
                isCommandControlEnabled: true,
                isBolusCommandEnabled: false,
                maxBolus: 5,
                maxCarbs: 120,
                bolusIncrement: 0.05
            )
        )

        let outcome = await route(["v": 1, "req": "presets"], via: processor)

        let reply = try #require(outcome.reply)
        #expect(reply["req"] as? String == "presets")
        #expect(reply["isCommandControlEnabled"] as? Bool == true)
        #expect(reply["maxCarbs"] as? Double == 120)
        let overrides = try #require(reply["overridePresets"] as? [[String: Any]])
        #expect(overrides.first?["name"] as? String == "Sport")
        let tempTargets = try #require(reply["tempTargetPresets"] as? [[String: Any]])
        #expect(tempTargets.first?["name"] as? String == "Walk")
        #expect(outcome.refreshesState == false)
        #expect(outcome.pushesPresets == false)
        #expect(processor.presetsRequested == 1)
        #expect(processor.processed.isEmpty)
    }

    @Test("A command is processed once and answered with the v1 ack carrying its request ID")
    func commandAck() async throws {
        let processor = SpyProcessor()

        let outcome = await route(envelope(command: "carbs", payload: ["carbs": 10]), via: processor)

        let reply = try #require(outcome.reply)
        #expect(Set(reply.keys) == ["v", "req", "requestId", "acknowledged", "ackCode", "message"])
        #expect(reply["req"] as? String == "ack")
        #expect(reply["requestId"] as? String == requestID)
        #expect(reply["acknowledged"] as? Bool == true)
        #expect(reply["ackCode"] as? String == "carbs_logged")
        #expect(outcome.refreshesState == false)

        #expect(processor.processed.count == 1)
        #expect(processor.processed.first?.appUUID == appUUID)
        #expect(processor.processed.first?.requestID == UUID(uuidString: requestID))
        #expect(processor.processed.first?.command == .carbs(10))
        #expect(processor.processed.first?.date == Date(timeIntervalSince1970: 1_800_000_000.123))
    }

    @Test("The processor's failure is relayed as a failed ack")
    func failureAck() async {
        let processor = SpyProcessor()
        processor.result = .failure("Watch commands are off. Turn them on in the Garmin settings on the phone.")

        let outcome = await route(envelope(command: "carbs", payload: ["carbs": 10]), via: processor)

        #expect(outcome.reply?["acknowledged"] as? Bool == false)
        #expect(outcome.reply?["ackCode"] as? String == "failure")
        #expect(outcome.reply?["message"] as? String == "Watch commands are off. Turn them on in the Garmin settings on the phone.")
        #expect(outcome.pushesPresets == false)
    }

    @Test("Only acknowledged preset commands push the preset list")
    func presetPushRules() async {
        let processor = SpyProcessor()

        processor.result = .success(.overrideStarted, "Override started.")
        #expect(await route(envelope(command: "activateOverride", payload: ["name": "Sport"]), via: processor).pushesPresets)

        processor.result = .success(.overrideStopped, "Override stopped.")
        #expect(await route(envelope(command: "cancelOverride", payload: [:]), via: processor).pushesPresets)

        processor.result = .success(.tempTargetStarted, "Temp target started.")
        #expect(await route(envelope(command: "activateTempTarget", payload: ["name": "Walk"]), via: processor).pushesPresets)

        processor.result = .success(.tempTargetStopped, "Temp target stopped.")
        #expect(await route(envelope(command: "cancelTempTarget", payload: [:]), via: processor).pushesPresets)

        processor.result = .failure("Override preset not found.")
        #expect(await route(envelope(command: "activateOverride", payload: ["name": "Sport"]), via: processor).pushesPresets == false)

        processor.result = .success(.carbsLogged, "Carbs logged.")
        #expect(await route(envelope(command: "carbs", payload: ["carbs": 10]), via: processor).pushesPresets == false)

        processor.result = .success(.genericSuccess, "Bolus delivered.")
        #expect(await route(envelope(command: "bolus", payload: ["bolus": 1]), via: processor).pushesPresets == false)

        processor.result = GarminWatchCommandResult(acknowledged: false, ackCode: .partialFailure, message: "Carbs logged.")
        let meal = envelope(command: "mealBolus", payload: ["carbs": 10, "bolus": 1])
        #expect(await route(meal, via: processor).pushesPresets == false)
    }

    @Test("Invalid commands are answered only when they name a request ID")
    func invalidReplies() async throws {
        let processor = SpyProcessor()

        let named = await route(envelope(command: "carbs", payload: ["carbs": "ten"]), via: processor)
        let reply = try #require(named.reply)
        #expect(reply["requestId"] as? String == requestID)
        #expect(reply["req"] as? String == "ack")
        #expect(reply["acknowledged"] as? Bool == false)
        #expect(reply["ackCode"] as? String == "failure")
        #expect(named.refreshesState == false)
        #expect(named.pushesPresets == false)

        let anonymous = await route(["v": 1, "req": "command"], via: processor)
        #expect(anonymous.reply == nil)
        #expect(anonymous.refreshesState == false)

        let garbage = await route(42, via: processor)
        #expect(garbage.reply == nil)

        #expect(processor.processed.isEmpty)
    }

    @Test("Logs name the message but never carry payload amounts")
    func logsHoldNoAmounts() async {
        let processor = SpyProcessor()
        let logs = LogCapture()
        let messages: [[String: Any]] = [
            envelope(command: "bolus", payload: ["bolus": 7.77]),
            envelope(command: "carbs", payload: ["carbs": 913]),
            envelope(command: "mealBolus", payload: ["carbs": 913, "bolus": 7.77]),
            envelope(command: "activateOverride", payload: ["name": "Sport"])
        ]

        for registered in [true, false] {
            for message in messages {
                _ = await route(message, via: processor, registered: registered, logs: logs)
            }
        }

        #expect(logs.lines.isEmpty == false)
        #expect(logs.lines.contains { $0.contains("bolus command") })
        #expect(logs.lines.contains { $0.contains("mealBolus command") })
        for line in logs.lines {
            #expect(!line.contains("7.77"), "\(line)")
            #expect(!line.contains("913"), "\(line)")
        }
    }

    @Test("A log line for an unregistered app names the app")
    func unregisteredLogNamesApp() async {
        let logs = LogCapture()
        _ = await route("status", via: SpyProcessor(), registered: false, logs: logs)

        #expect(logs.lines.contains { $0.contains(appUUID.uuidString) && $0.contains("unregistered") })
    }
}
