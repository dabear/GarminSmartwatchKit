import Foundation
import Testing

@testable import GarminSmartwatchKit

@Suite("Garmin watch settings") struct GarminWatchSettingsTests {
    private func decode(_ json: String) throws -> GarminWatchSettings {
        try JSONDecoder().decode(GarminWatchSettings.self, from: Data(json.utf8))
    }

    // MARK: - Settings saved by the previous version

    @Test("A saved single datafield becomes a one-element selection")
    func singleDatafieldMigrates() throws {
        let json = """
        {"watchface": "swissalpine", "datafield": "swissalpine", "primaryAttributeChoice": "isf", \
        "secondaryAttributeChoice": "eventualBG", "glucoseColorScheme": "dynamic", "isWatchfaceDataEnabled": false}
        """
        let settings = try decode(json)

        #expect(settings.datafields == [.swissalpine])
        #expect(settings.watchface == .swissalpine)
        #expect(settings.primaryAttributeChoice == .isf)
        #expect(settings.secondaryAttributeChoice == .eventualBG)
        #expect(settings.glucoseColorScheme == .dynamicColor)
        #expect(settings.isWatchfaceDataEnabled == false)
    }

    @Test("A saved datafield of none becomes an empty selection")
    func noneDatafieldMigratesToEmpty() throws {
        let settings = try decode(#"{"watchface": "trio", "datafield": "none"}"#)

        #expect(settings.datafields.isEmpty)
        #expect(settings.watchface == .trio)
    }

    @Test("A saved datafield that is no longer known takes the default")
    func unknownSingleDatafield() throws {
        let settings = try decode(#"{"datafield": "retired"}"#)

        #expect(settings.datafields == GarminWatchSettings().datafields)
    }

    @Test("The datafields key wins over the old single one")
    func datafieldsWinOverLegacyKey() throws {
        let settings = try decode(#"{"datafield": "trio", "datafields": ["loopgraph", "swissalpine"]}"#)

        #expect(settings.datafields == [.loopgraph, .swissalpine])
    }

    @Test("Missing keys take their defaults and commands stay off")
    func missingKeysDefault() throws {
        let settings = try decode("{}")
        let defaults = GarminWatchSettings()

        #expect(settings == defaults)
        #expect(settings.datafields == [.trio])
        #expect(settings.watchface == .trio)
        #expect(settings.primaryAttributeChoice == .cob)
        #expect(settings.secondaryAttributeChoice == .tbr)
        #expect(settings.glucoseColorScheme == .staticColor)
        #expect(settings.isWatchfaceDataEnabled)
        #expect(settings.isCommandControlEnabled == false)
        #expect(settings.isBolusCommandEnabled == false)
    }

    @Test("Settings from before commands existed keep their values and leave commands off")
    func previousVersionKeepsValues() throws {
        let json = """
        {"watchface": "complication", "datafield": "trio", "primaryAttributeChoice": "sensRatio", \
        "isWatchfaceDataEnabled": true}
        """
        let settings = try decode(json)

        #expect(settings.watchface == .complication)
        #expect(settings.datafields == [.trio])
        #expect(settings.primaryAttributeChoice == .sensRatio)
        #expect(settings.isCommandControlEnabled == false)
        #expect(settings.isBolusCommandEnabled == false)
    }

    @Test("A setting with an unreadable value takes its default without resetting the others")
    func unreadableValueTakesDefault() throws {
        let settings = try decode(#"{"watchface": "swissalpine", "primaryAttributeChoice": "retired", "isCommandControlEnabled": "yes"}"#)

        #expect(settings.watchface == .swissalpine)
        #expect(settings.primaryAttributeChoice == .cob)
        #expect(settings.isCommandControlEnabled == false)
    }

    @Test("A saved selection is sanitized when decoded")
    func decodedSelectionIsSanitized() throws {
        let settings = try decode(#"{"datafields": ["trio", "none", "trio", "loopgraph"]}"#)

        #expect(settings.datafields == [.trio, .loopgraph])
    }

    // MARK: - Round trip

    @Test("Settings survive an encode and decode round trip")
    func roundTrip() throws {
        var settings = GarminWatchSettings()
        settings.watchface = .swissalpine
        settings.datafields = [.loopgraph, .trio]
        settings.primaryAttributeChoice = .sensRatio
        settings.secondaryAttributeChoice = .eventualBG
        settings.glucoseColorScheme = .dynamicColor
        settings.isWatchfaceDataEnabled = false
        settings.isCommandControlEnabled = true
        settings.isBolusCommandEnabled = true

        let decoded = try JSONDecoder().decode(GarminWatchSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded == settings)
        #expect(decoded.datafields == [.loopgraph, .trio])
        #expect(decoded.isCommandControlEnabled)
        #expect(decoded.isBolusCommandEnabled)
    }

    @Test("An empty selection survives a round trip instead of reverting to the default")
    func emptySelectionRoundTrip() throws {
        var settings = GarminWatchSettings()
        settings.datafields = []

        let decoded = try JSONDecoder().decode(GarminWatchSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.datafields.isEmpty)
    }

    @Test("Encoding writes the datafields key and, for older versions, the first choice under the old single key")
    func encodesDatafieldsKey() throws {
        var settings = GarminWatchSettings()
        settings.datafields = [.loopgraph, .swissalpine]
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["datafields"] as? [String] == ["loopgraph", "swissalpine"])
        #expect(object["datafield"] as? String == "loopgraph")
    }

    @Test("An empty selection is written as none under the old single key, so an older version shows no datafield")
    func encodesEmptySelectionAsNone() throws {
        var settings = GarminWatchSettings()
        settings.datafields = []
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["datafields"] as? [String] == [])
        #expect(object["datafield"] as? String == "none")
    }

    @Test("Decoding what this version wrote still takes the full selection, not the legacy key")
    func decodingPrefersDatafieldsOverWrittenLegacyKey() throws {
        var settings = GarminWatchSettings()
        settings.datafields = [.swissalpine, .trio, .loopgraph]
        let decoded = try JSONDecoder().decode(GarminWatchSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.datafields == [.swissalpine, .trio, .loopgraph])
    }

    // MARK: - Datafield selection

    @Test("Only trio, swissalpine and loopgraph are selectable, and the cap is four")
    func selectableCases() {
        #expect(GarminDatafield.selectableCases == [.trio, .swissalpine, .loopgraph])
        #expect(GarminDatafield.maxSelectionCount == 4)
    }

    @Test("A sanitized selection drops none and duplicates and keeps the order")
    func sanitizedSelection() {
        #expect(GarminDatafield.sanitizedSelection([]).isEmpty)
        #expect(GarminDatafield.sanitizedSelection([.none]).isEmpty)
        #expect(GarminDatafield.sanitizedSelection([.loopgraph, .none, .trio, .loopgraph]) == [.loopgraph, .trio])
        #expect(GarminDatafield.sanitizedSelection([.swissalpine, .trio, .loopgraph]) == [.swissalpine, .trio, .loopgraph])
    }

    @Test("A sanitized selection never exceeds the cap")
    func sanitizedSelectionIsCapped() {
        let many = Array(repeating: GarminDatafield.selectableCases, count: 5).flatMap { $0 }

        let selection = GarminDatafield.sanitizedSelection(many)

        #expect(selection.count <= GarminDatafield.maxSelectionCount)
        #expect(Set(selection).count == selection.count)
    }

    @Test("Assigning datafields sanitizes them")
    func assigningSanitizes() {
        var settings = GarminWatchSettings()

        settings.datafields = [.trio, .trio, .none, .swissalpine]

        #expect(settings.datafields == [.trio, .swissalpine])
    }

    @Test("Toggling adds a datafield in the order chosen and removes one that is chosen")
    func toggleDatafield() {
        var settings = GarminWatchSettings()
        settings.datafields = []

        settings.toggleDatafield(.swissalpine)
        settings.toggleDatafield(.trio)
        #expect(settings.datafields == [.swissalpine, .trio])

        settings.toggleDatafield(.swissalpine)
        #expect(settings.datafields == [.trio])

        settings.toggleDatafield(.trio)
        #expect(settings.datafields.isEmpty)
    }

    @Test("Toggling none never selects it")
    func toggleNoneIgnored() {
        var settings = GarminWatchSettings()
        settings.datafields = [.trio]

        settings.toggleDatafield(.none)

        #expect(settings.datafields == [.trio])
    }

    @Test("Every selectable datafield can be chosen together and stays within the cap")
    func toggleAllSelectable() {
        var settings = GarminWatchSettings()
        settings.datafields = []

        for datafield in GarminDatafield.selectableCases {
            #expect(settings.canSelectDatafield(datafield))
            settings.toggleDatafield(datafield)
        }

        #expect(settings.datafields == GarminDatafield.selectableCases)
        #expect(settings.datafields.count <= GarminDatafield.maxSelectionCount)
        for datafield in GarminDatafield.selectableCases {
            #expect(settings.canSelectDatafield(datafield), "A chosen datafield can always be unchosen")
        }
    }

    // MARK: - Commands

    @Test("Commands are off by default")
    func commandsOffByDefault() {
        let settings = GarminWatchSettings()

        #expect(settings.isCommandControlEnabled == false)
        #expect(settings.isBolusCommandEnabled == false)
    }

    @Test("Turning the master switch off clears bolus, and turning it on does not bring bolus back")
    func masterOffClearsBolus() {
        var settings = GarminWatchSettings()
        settings.isCommandControlEnabled = true
        settings.isBolusCommandEnabled = true
        #expect(settings.isBolusCommandEnabled)

        settings.isCommandControlEnabled = false
        #expect(settings.isBolusCommandEnabled == false)

        settings.isCommandControlEnabled = true
        #expect(settings.isBolusCommandEnabled == false)
    }

    @Test("Bolus saved as on with the master switch off decodes as off")
    func bolusWithoutMasterDecodesOff() throws {
        let settings = try decode(#"{"isCommandControlEnabled": false, "isBolusCommandEnabled": true}"#)
        #expect(settings.isCommandControlEnabled == false)
        #expect(settings.isBolusCommandEnabled == false)

        let missingMaster = try decode(#"{"isBolusCommandEnabled": true}"#)
        #expect(missingMaster.isCommandControlEnabled == false)
        #expect(missingMaster.isBolusCommandEnabled == false)
    }

    @Test("Bolus saved as on with the master switch on decodes as on")
    func bolusWithMasterDecodesOn() throws {
        let settings = try decode(#"{"isCommandControlEnabled": true, "isBolusCommandEnabled": true}"#)
        #expect(settings.isCommandControlEnabled)
        #expect(settings.isBolusCommandEnabled)

        let commandsOnly = try decode(#"{"isCommandControlEnabled": true}"#)
        #expect(commandsOnly.isCommandControlEnabled)
        #expect(commandsOnly.isBolusCommandEnabled == false)
    }

    // MARK: - History span

    @Test("The history span is the longest any chosen watch app needs")
    func historySpan() {
        var settings = GarminWatchSettings()
        settings.watchface = .trio
        settings.datafields = [.trio]
        #expect(settings.historySpan == 0)

        settings.datafields = [.trio, .loopgraph]
        #expect(settings.historySpan == GarminDatafield.loopgraph.historySpan)
        #expect(settings.historySpan == 2 * 60 * 60)

        settings.datafields = []
        #expect(settings.historySpan == 0)

        settings.watchface = .swissalpine
        #expect(settings.historySpan == GarminWatchface.swissalpine.historySpan)

        settings.datafields = [.loopgraph]
        #expect(settings.historySpan == 2 * 60 * 60)
    }

    @Test("Only LoopGraph asks for history among the datafields")
    func datafieldHistorySpans() {
        #expect(GarminDatafield.trio.historySpan == 0)
        #expect(GarminDatafield.swissalpine.historySpan == 0)
        #expect(GarminDatafield.loopgraph.historySpan == 2 * 60 * 60)
        #expect(GarminDatafield.none.historySpan == 0)
        #expect(GarminDatafield.none.datafieldUUID == nil)
        #expect(GarminDatafield.loopgraph.datafieldUUID != nil)
    }

    // MARK: - Forecast formats

    @Test("Each watch app declares its forecast format: LoopGraph mountrcg's pairs, the others the cone")
    func declaredForecastFormats() {
        #expect(GarminWatchface.allCases.allSatisfy { $0.forecastFormat == .cone })
        #expect(GarminDatafield.trio.forecastFormat == .cone)
        #expect(GarminDatafield.swissalpine.forecastFormat == .cone)
        #expect(GarminDatafield.loopgraph.forecastFormat == .predictedPairs)
        #expect(GarminDatafield.none.forecastFormat == GarminForecastFormat.none)
    }

    @Test("The broadcast carries the formats of the chosen apps together")
    func combinedForecastFormats() {
        var settings = GarminWatchSettings()
        settings.watchface = .trio
        settings.isWatchfaceDataEnabled = true
        settings.datafields = [.loopgraph]
        #expect(settings.forecastFormats() == [.cone, .predictedPairs])

        settings.isWatchfaceDataEnabled = false
        #expect(settings.forecastFormats() == [.predictedPairs], "a watchface that gets no data adds no format")

        settings.datafields = []
        #expect(settings.forecastFormats().isEmpty)

        settings.datafields = [.trio, .swissalpine]
        #expect(settings.forecastFormats() == [.cone])
    }

    @Test("Forecasts off in code: no format for any app")
    func forecastsOff() {
        var settings = GarminWatchSettings()
        settings.datafields = [.loopgraph, .trio]
        settings.isWatchfaceDataEnabled = true
        #expect(settings.forecastFormats(isEnabled: false).isEmpty)
        #expect(GarminForecastFormat.isEnabled, "on in this build")
    }
}
