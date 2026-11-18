import Foundation
import Testing

@testable import GarminSmartwatchKit

@Suite("Garmin command envelope") struct GarminCommandEnvelopeTests {
    let requestID = "3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b"
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

    private func parsedCommand(_ message: Any) -> GarminWatchCommand? {
        guard case let .command(_, _, _, command) = GarminCommandEnvelope.parse(message) else { return nil }
        return command
    }

    // MARK: - Read requests

    @Test("Bare status string is the legacy status request, any other string is invalid")
    func legacyStatus() {
        #expect(GarminCommandEnvelope.parse("status") == .legacyStatus)
        #expect(GarminCommandEnvelope.parse("bolus") == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse("") == .invalid(requestID: nil))
    }

    @Test("Messages that are neither a string nor a dictionary are invalid")
    func otherMessageTypes() {
        #expect(GarminCommandEnvelope.parse(1) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse([1, 2]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(NSNull()) == .invalid(requestID: nil))
    }

    @Test("v1 status and presets requests carry no other fields")
    func readRequests() {
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "status"]) == .status)
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "presets"]) == .presets)
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "presets", "extra": true]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "status", "requestId": requestID]) == .invalid(requestID: requestID))
    }

    @Test("A version other than the number 1 is rejected, even with a request ID to answer")
    func wrongVersion() {
        #expect(GarminCommandEnvelope.parse(["v": 2, "req": "status"]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["v": "1", "req": "status"]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["v": NSNumber(value: true), "req": "status"]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["req": "status"]) == .invalid(requestID: nil))

        var command = envelope(command: "cancelOverride", payload: [:])
        command["v"] = 2
        #expect(GarminCommandEnvelope.parse(command) == .invalid(requestID: requestID))
    }

    @Test("An unknown request, or an inbound ack, is invalid")
    func unknownRequests() {
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "reboot"]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": 1]) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "ack", "requestId": requestID]) == .invalid(requestID: requestID))
    }

    @Test("An inbound ownerMode notice is invalid: only the phone sends it")
    func inboundOwnerModeInvalid() {
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "ownerMode"]) == .invalid(requestID: nil))
        #expect(
            GarminCommandEnvelope.parse(["v": 1, "req": "ownerMode", "active": true, "owner": "watchControls"])
                == .invalid(requestID: nil)
        )
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "ownerMode", "requestId": requestID]) == .invalid(requestID: requestID))
        #expect(GarminCommandEnvelope.parse(GarminCommandEnvelope.commandAppNotice(isActive: true, commandApp: .complication)) == .invalid(requestID: nil))
        #expect(GarminCommandEnvelope.parse(GarminCommandEnvelope.commandAppNotice(isActive: false, commandApp: .none)).logName == "invalid message")
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "ownerMode"]).isCommand == false)
    }

    @Test("Only a command is a command")
    func isCommand() {
        #expect(GarminCommandEnvelope.parse(envelope(command: "cancelOverride", payload: [:])).isCommand)
        #expect(GarminCommandEnvelope.parse(envelope(command: "carbs", payload: ["carbs": "ten"])).isCommand == false)
        #expect(GarminCommandEnvelope.parse("status").isCommand == false)
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "status"]).isCommand == false)
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "presets"]).isCommand == false)
        #expect(GarminCommandEnvelope.parse(7).isCommand == false)
    }

    // MARK: - Commands

    @Test("Every command parses with its exact payload")
    func commands() {
        #expect(parsedCommand(envelope(command: "bolus", payload: ["bolus": 1.5])) == .bolus(1.5))
        #expect(parsedCommand(envelope(command: "bolus", payload: ["bolus": 2])) == .bolus(2))
        #expect(parsedCommand(envelope(command: "carbs", payload: ["carbs": 45])) == .carbs(45))
        #expect(
            parsedCommand(envelope(command: "mealBolus", payload: ["carbs": 45, "bolus": 3.25]))
                == .mealBolus(carbs: 45, bolus: 3.25)
        )
        #expect(
            parsedCommand(envelope(command: "activateOverride", payload: ["name": "Sport"])) == .activateOverride(name: "Sport")
        )
        #expect(parsedCommand(envelope(command: "cancelOverride", payload: [:])) == .cancelOverride)
        #expect(
            parsedCommand(envelope(command: "activateTempTarget", payload: ["name": "Walk"])) == .activateTempTarget(name: "Walk")
        )
        #expect(parsedCommand(envelope(command: "cancelTempTarget", payload: [:])) == .cancelTempTarget)
    }

    @Test("A whole number sent as a float counts as an integer number of grams")
    func wholeFloatGrams() {
        #expect(parsedCommand(envelope(command: "carbs", payload: ["carbs": NSNumber(value: 20.0)])) == .carbs(20))
    }

    @Test("The command date is read as Unix milliseconds and the request ID is echoed")
    func dateAndRequestID() {
        guard case let .command(echoedID, uuid, date, _) = GarminCommandEnvelope.parse(
            envelope(command: "cancelOverride", payload: [:])
        ) else {
            Issue.record("Expected a command")
            return
        }
        #expect(echoedID == requestID)
        #expect(uuid == UUID(uuidString: requestID))
        #expect(abs(date.timeIntervalSince1970 - 1_800_000_000.123) < 0.000_1)
    }

    @Test("The request ID is echoed in the case it arrived in")
    func requestIDEchoedVerbatim() {
        var message = envelope(command: "cancelOverride", payload: [:])
        message["requestId"] = requestID.uppercased()
        guard case let .command(echoedID, uuid, _, _) = GarminCommandEnvelope.parse(message) else {
            Issue.record("Expected a command")
            return
        }
        #expect(echoedID == requestID.uppercased())
        #expect(uuid == UUID(uuidString: requestID))
    }

    @Test("A Monkey C Float bolus is rounded to 0.001 U")
    func floatRounding() {
        let payload: [String: Any] = ["bolus": NSNumber(value: Float(0.1))]
        #expect(parsedCommand(envelope(command: "bolus", payload: payload)) == .bolus(Decimal(string: "0.1")!))

        let meal: [String: Any] = ["carbs": 30, "bolus": NSNumber(value: Float(2.35))]
        #expect(parsedCommand(envelope(command: "mealBolus", payload: meal)) == .mealBolus(carbs: 30, bolus: Decimal(string: "2.35")!))
    }

    @Test("Booleans are not numbers")
    func booleansRejectedAsNumbers() {
        let yes = NSNumber(value: true)
        let no = NSNumber(value: false)
        #expect(GarminCommandEnvelope.parse(envelope(command: "bolus", payload: ["bolus": yes])) == .invalid(requestID: requestID))
        #expect(GarminCommandEnvelope.parse(envelope(command: "carbs", payload: ["carbs": yes])) == .invalid(requestID: requestID))
        #expect(GarminCommandEnvelope.parse(envelope(command: "carbs", payload: ["carbs": no])) == .invalid(requestID: requestID))
        #expect(
            GarminCommandEnvelope.parse(envelope(command: "mealBolus", payload: ["carbs": 20, "bolus": yes]))
                == .invalid(requestID: requestID)
        )

        var asDate = envelope(command: "cancelOverride", payload: [:])
        asDate["date"] = yes
        #expect(GarminCommandEnvelope.parse(asDate) == .invalid(requestID: requestID))
    }

    @Test("Grams must be whole numbers")
    func nonIntegerGramsRejected() {
        let values: [Any] = [12.5, NSNumber(value: Float(0.5)), "12", NSNumber(value: Double.nan), NSNumber(value: Double.infinity)]
        for grams in values {
            #expect(
                GarminCommandEnvelope.parse(envelope(command: "carbs", payload: ["carbs": grams])) == .invalid(requestID: requestID),
                "carbs \(grams)"
            )
            #expect(
                GarminCommandEnvelope.parse(envelope(command: "mealBolus", payload: ["carbs": grams, "bolus": 1]))
                    == .invalid(requestID: requestID),
                "mealBolus carbs \(grams)"
            )
        }
    }

    @Test("A non-finite bolus is rejected")
    func nonFiniteBolusRejected() {
        for units in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(
                GarminCommandEnvelope.parse(envelope(command: "bolus", payload: ["bolus": NSNumber(value: units)]))
                    == .invalid(requestID: requestID)
            )
        }
    }

    @Test("Payloads must have exactly the keys of their command")
    func strictPayloadKeys() {
        let cases: [(command: String, payload: [String: Any])] = [
            ("bolus", ["bolus": 1, "note": "x"]),
            ("bolus", ["carbs": 1]),
            ("bolus", [:]),
            ("carbs", ["carbs": 10, "bolus": 1]),
            ("carbs", [:]),
            ("mealBolus", ["carbs": 20]),
            ("mealBolus", ["bolus": 2]),
            ("mealBolus", ["carbs": 20, "bolus": 2, "name": "x"]),
            ("activateOverride", ["name": "Sport", "extra": 1]),
            ("activateOverride", [:]),
            ("activateTempTarget", [:]),
            ("cancelOverride", ["name": "Sport"]),
            ("cancelTempTarget", ["name": "Walk"])
        ]
        for (command, payload) in cases {
            #expect(
                GarminCommandEnvelope.parse(envelope(command: command, payload: payload)) == .invalid(requestID: requestID),
                "\(command) with \(payload.keys.sorted())"
            )
        }
    }

    @Test("Wrongly typed payload values are rejected")
    func wronglyTypedPayloads() {
        let cases: [(command: String, payload: [String: Any])] = [
            ("bolus", ["bolus": "1"]),
            ("carbs", ["carbs": "12"]),
            ("activateOverride", ["name": 3]),
            ("activateTempTarget", ["name": NSNull()])
        ]
        for (command, payload) in cases {
            #expect(
                GarminCommandEnvelope.parse(envelope(command: command, payload: payload)) == .invalid(requestID: requestID),
                "\(command) with \(payload)"
            )
        }
    }

    @Test("Unknown commands are rejected")
    func unknownCommands() {
        for name in ["requestBolusRecommendation", "unknown", "", "Bolus"] {
            #expect(GarminCommandEnvelope.parse(envelope(command: name, payload: [:])) == .invalid(requestID: requestID), "\(name)")
        }
    }

    // MARK: - Command envelopes

    @Test("Malformed command envelopes are rejected but keep their request ID for the ack")
    func malformedEnvelopes() {
        var extraField = envelope(command: "cancelOverride", payload: [:])
        extraField["auth"] = ["scheme": "hmac-sha256"]
        #expect(GarminCommandEnvelope.parse(extraField) == .invalid(requestID: requestID))

        var missingDate = envelope(command: "cancelOverride", payload: [:])
        missingDate["date"] = nil
        #expect(GarminCommandEnvelope.parse(missingDate) == .invalid(requestID: requestID))

        var negativeDate = envelope(command: "cancelOverride", payload: [:])
        negativeDate["date"] = -1
        #expect(GarminCommandEnvelope.parse(negativeDate) == .invalid(requestID: requestID))

        var fractionalDate = envelope(command: "cancelOverride", payload: [:])
        fractionalDate["date"] = 1.5
        #expect(GarminCommandEnvelope.parse(fractionalDate) == .invalid(requestID: requestID))

        var stringDate = envelope(command: "cancelOverride", payload: [:])
        stringDate["date"] = "1800000000123"
        #expect(GarminCommandEnvelope.parse(stringDate) == .invalid(requestID: requestID))

        var badPayload = envelope(command: "cancelOverride", payload: [:])
        badPayload["payload"] = "none"
        #expect(GarminCommandEnvelope.parse(badPayload) == .invalid(requestID: requestID))

        var missingPayload = envelope(command: "cancelOverride", payload: [:])
        missingPayload["payload"] = nil
        #expect(GarminCommandEnvelope.parse(missingPayload) == .invalid(requestID: requestID))

        var numericCommand = envelope(command: "cancelOverride", payload: [:])
        numericCommand["command"] = 7
        #expect(GarminCommandEnvelope.parse(numericCommand) == .invalid(requestID: requestID))
    }

    @Test("A command envelope without a request ID is invalid and has nothing to answer")
    func invalidWithoutRequestID() {
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "command"]) == .invalid(requestID: nil))

        var missing = envelope(command: "cancelOverride", payload: [:])
        missing["requestId"] = nil
        #expect(GarminCommandEnvelope.parse(missing) == .invalid(requestID: nil))

        var notAString = envelope(command: "cancelOverride", payload: [:])
        notAString["requestId"] = 42
        #expect(GarminCommandEnvelope.parse(notAString) == .invalid(requestID: nil))
    }

    @Test("A command whose request ID is not an RFC 4122 UUID is invalid but is answered with that ID")
    func nonRFC4122RequestID() {
        // variant nibble 'c' is the Microsoft layout, not RFC 4122
        let microsoft = "3f2b8c1e-4a5d-4e6f-ca7b-1c2d3e4f5a6b"
        var message = envelope(command: "cancelOverride", payload: [:])
        message["requestId"] = microsoft
        #expect(GarminCommandEnvelope.parse(message) == .invalid(requestID: microsoft))

        message["requestId"] = "not-a-uuid"
        #expect(GarminCommandEnvelope.parse(message) == .invalid(requestID: "not-a-uuid"))
    }

    @Test("Request IDs must be RFC 4122 UUIDs")
    func requestIDFormat() {
        #expect(GarminCommandEnvelope.rfc4122UUID(requestID) != nil)
        #expect(GarminCommandEnvelope.rfc4122UUID(requestID.uppercased()) != nil)
        #expect(GarminCommandEnvelope.rfc4122UUID("3f2b8c1e-4a5d-4e6f-ca7b-1c2d3e4f5a6b") == nil)
        #expect(GarminCommandEnvelope.rfc4122UUID("3f2b8c1e4a5d4e6f9a7b1c2d3e4f5a6b") == nil)
        #expect(GarminCommandEnvelope.rfc4122UUID("not-a-uuid") == nil)
        #expect(GarminCommandEnvelope.rfc4122UUID("") == nil)
    }

    // MARK: - Log names

    @Test("Log names describe the message without its values")
    func logNames() {
        #expect(GarminCommandEnvelope.parse("status").logName == "legacy status request")
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "status"]).logName == "status request")
        #expect(GarminCommandEnvelope.parse(["v": 1, "req": "presets"]).logName == "presets request")
        #expect(GarminCommandEnvelope.parse(envelope(command: "bolus", payload: ["bolus": 7.77])).logName == "bolus command")
        #expect(GarminCommandEnvelope.parse(envelope(command: "bolus", payload: ["bolus": "x"])).logName == "invalid message")
    }

    // MARK: - Responses

    @Test("An acknowledgment has exactly the v1 keys")
    func acknowledgmentShape() {
        let reply = GarminCommandEnvelope.acknowledgment(
            requestID: requestID,
            result: .success(.carbsLogged, "Carbs logged.")
        )
        #expect(Set(reply.keys) == ["v", "req", "requestId", "acknowledged", "ackCode", "message"])
        #expect(reply["v"] as? Int == 1)
        #expect(reply["req"] as? String == "ack")
        #expect(reply["requestId"] as? String == requestID)
        #expect(reply["acknowledged"] as? Bool == true)
        #expect(reply["ackCode"] as? String == "carbs_logged")
        #expect(reply["message"] as? String == "Carbs logged.")
    }

    @Test(
        "A command app notice has exactly the v1 notice keys",
        arguments: [
            (true, GarminCommandApp.watchControls, "watchControls"),
            (false, .watchControls, "watchControls"),
            (true, .complication, "complication"),
            (false, .complication, "complication"),
            (false, .none, "none")
        ]
    )
    func commandAppNoticeShape(isActive: Bool, commandApp: GarminCommandApp, owner: String) {
        let notice = GarminCommandEnvelope.commandAppNotice(isActive: isActive, commandApp: commandApp)

        #expect(Set(notice.keys) == ["v", "req", "active", "owner"])
        #expect(notice["v"] as? Int == 1)
        #expect(notice["req"] as? String == "ownerMode")
        #expect(notice["active"] as? Bool == isActive)
        #expect(notice["owner"] as? String == owner)
        #expect(notice["requestId"] == nil)
    }

    @Test("A command app notice reads as a plist boolean and a string")
    func commandAppNoticeTypes() throws {
        let notice = GarminCommandEnvelope.commandAppNotice(isActive: true, commandApp: .complication)
        let data = try PropertyListSerialization.data(fromPropertyList: notice, format: .binary, options: 0)
        let decoded = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(decoded["active"] as? Bool == true)
        #expect((decoded["active"] as? NSNumber).map { CFGetTypeID($0) } == CFBooleanGetTypeID())
        #expect(decoded["owner"] as? String == "complication")
    }

    @Test("A failed or partial result is acknowledged as not acknowledged with its own code")
    func failureAcknowledgment() {
        let failed = GarminCommandEnvelope.acknowledgment(requestID: requestID, result: .failure("Nope."))
        #expect(failed["acknowledged"] as? Bool == false)
        #expect(failed["ackCode"] as? String == "failure")
        #expect(failed["message"] as? String == "Nope.")

        let partial = GarminCommandEnvelope.acknowledgment(
            requestID: requestID,
            result: GarminWatchCommandResult(acknowledged: false, ackCode: .partialFailure, message: "Carbs logged.")
        )
        #expect(partial["acknowledged"] as? Bool == false)
        #expect(partial["ackCode"] as? String == "partial_failure")
    }

    @Test("The ack codes keep their wire names")
    func ackCodeWireNames() {
        #expect(GarminAckCode.carbsLogged.rawValue == "carbs_logged")
        #expect(GarminAckCode.overrideStarted.rawValue == "override_started")
        #expect(GarminAckCode.overrideStopped.rawValue == "override_stopped")
        #expect(GarminAckCode.tempTargetStarted.rawValue == "temp_target_started")
        #expect(GarminAckCode.tempTargetStopped.rawValue == "temp_target_stopped")
        #expect(GarminAckCode.genericSuccess.rawValue == "success")
        #expect(GarminAckCode.genericFailure.rawValue == "failure")
        #expect(GarminAckCode.partialFailure.rawValue == "partial_failure")
        #expect(GarminAckCode.inProgress.rawValue == "in_progress")
    }

    @Test("A presets response lists the presets and the capabilities, amounts as doubles")
    func presetsResponseShape() throws {
        let presets = GarminWatchCommandPresets(
            overridePresets: [GarminWatchPreset(name: "Sport", isEnabled: true)],
            tempTargetPresets: [GarminWatchPreset(name: "Walk", isEnabled: false), GarminWatchPreset(name: "Eat", isEnabled: false)],
            capabilities: GarminWatchCommandCapabilities(
                isCommandControlEnabled: true,
                isBolusCommandEnabled: false,
                maxBolus: 5,
                maxCarbs: 120,
                bolusIncrement: 0.05
            )
        )

        let reply = GarminCommandEnvelope.presetsResponse(presets)

        #expect(Set(reply.keys) == [
            "v", "req", "overridePresets", "tempTargetPresets",
            "isCommandControlEnabled", "isBolusCommandEnabled", "maxBolus", "maxCarbs", "bolusIncrement"
        ])
        #expect(reply["v"] as? Int == 1)
        #expect(reply["req"] as? String == "presets")
        #expect(reply["isCommandControlEnabled"] as? Bool == true)
        #expect(reply["isBolusCommandEnabled"] as? Bool == false)
        #expect(reply["maxBolus"] as? Double == 5)
        #expect(reply["maxCarbs"] as? Double == 120)
        #expect(abs((reply["bolusIncrement"] as? Double ?? 0) - 0.05) < 1E-9)

        let overrides = try #require(reply["overridePresets"] as? [[String: Any]])
        #expect(overrides.count == 1)
        #expect(Set(overrides[0].keys) == ["name", "isEnabled"])
        #expect(overrides[0]["name"] as? String == "Sport")
        #expect(overrides[0]["isEnabled"] as? Bool == true)

        let tempTargets = try #require(reply["tempTargetPresets"] as? [[String: Any]])
        #expect(tempTargets.compactMap { $0["name"] as? String } == ["Walk", "Eat"])
        #expect(tempTargets.compactMap { $0["isEnabled"] as? Bool } == [false, false])
    }

    @Test("Presets without capabilities describe a phone that accepts nothing")
    func presetsResponseDefaults() throws {
        let reply = GarminCommandEnvelope.presetsResponse(GarminWatchCommandPresets(overridePresets: [], tempTargetPresets: []))

        #expect(try #require(reply["overridePresets"] as? [[String: Any]]).isEmpty)
        #expect(try #require(reply["tempTargetPresets"] as? [[String: Any]]).isEmpty)
        #expect(reply["isCommandControlEnabled"] as? Bool == false)
        #expect(reply["isBolusCommandEnabled"] as? Bool == false)
        #expect(reply["maxBolus"] as? Double == 0)
        #expect(reply["maxCarbs"] as? Double == 0)
        #expect(reply["bolusIncrement"] as? Double == 0)
    }
}
