//
//  GarminSettingsView.swift
//  GarminSmartwatchKitUI
//
//  The settings from Trio's Garmin screens (Trio contributors, MIT), for the plugin.
//

import Combine
import ConnectIQ
import GarminSmartwatchKit
import SwiftUI

@MainActor
final class GarminSettingsModel: ObservableObject {
    let manager: GarminSmartwatchManager
    @Published private(set) var devices: [IQDevice] = []
    @Published private(set) var isConnectMobileMissing = false
    @Published var settings: GarminWatchSettings {
        didSet { manager.settings = settings }
    }

    private var cancellables = Set<AnyCancellable>()

    init(manager: GarminSmartwatchManager) {
        self.manager = manager
        settings = manager.settings
        refresh()
        manager.stateDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        devices = manager.devices
        isConnectMobileMissing = manager.isConnectMobileMissing
        if settings != manager.settings { settings = manager.settings }
    }

    /// Opens Garmin Connect to choose the watches.
    func addDevices() {
        manager.selectDevices()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func removeDevices(at offsets: IndexSet) {
        var remaining = manager.devices
        remaining.remove(atOffsets: offsets)
        manager.updateDeviceList(remaining)
    }

    func removeDevice(_ device: IQDevice) {
        manager.updateDeviceList(manager.devices.filter { $0.uuid != device.uuid })
    }
}

struct GarminSettingsView: View {
    @ObservedObject var model: GarminSettingsModel
    let done: () -> Void

    @State private var confirmingRemoval = false
    @State private var confirmingWatchfaceSwitch = false
    @State private var confirmingBolusCommands = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                Text(LocalizedString("Experimental. The chosen Garmin watch apps show glucose, loop status and therapy values. The watch can send commands only when you turn them on below.", comment: "Garmin settings: what the plugin does"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.isConnectMobileMissing {
                Section {
                    Text(LocalizedString("Garmin Connect isn't installed. It's needed to choose watches and send to them.", comment: "Garmin settings: Garmin Connect missing"))
                        .foregroundStyle(.red)
                    Button(LocalizedString("Get Garmin Connect", comment: "Garmin settings: open the App Store")) {
                        model.manager.showAppStoreForConnectMobile()
                    }
                }
            }

            devicesSection
            watchAppSection
            commandsSection
            displaySection
            timeInRangeSection

            Section {
                Button(LocalizedString("Delete Garmin", comment: "Garmin settings: remove the plugin"), role: .destructive) {
                    confirmingRemoval = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle(GarminSmartwatchManager.localizedTitle)
        .environment(\.editMode, $editMode)
        .onChange(of: model.devices.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
        .toolbar {
            // Edit shows the delete control on each watch; while editing, its Done is the only one.
            ToolbarItem(placement: .topBarLeading) {
                if editMode.isEditing {
                    Button(LocalizedString("Done", comment: "Garmin settings: stop editing the watches")) {
                        withAnimation { editMode = .inactive }
                    }
                } else if !model.devices.isEmpty {
                    Button(LocalizedString("Edit", comment: "Garmin settings: edit the watches")) {
                        withAnimation { editMode = .active }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !editMode.isEditing {
                    Button(LocalizedString("Done", comment: "Garmin settings: close"), action: done)
                }
            }
        }
        .confirmationDialog(LocalizedString("Delete Garmin?", comment: "Garmin settings: confirm removal"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(LocalizedString("Delete", comment: "Garmin settings: confirm removal button"), role: .destructive) {
                Task {
                    await model.manager.delete()
                    done()
                }
            }
        } message: {
            Text(LocalizedString("Stops sending to your Garmin watches and forgets their settings. Watch commands are turned off, and the watch app taking commands is told so.", comment: "Garmin settings: confirm removal message"))
        }
        .alert(LocalizedString("Watchface Changed", comment: "Garmin settings: watchface switch title"), isPresented: $confirmingWatchfaceSwitch) {
            Button(LocalizedString("Resume Sending", comment: "Garmin settings: resume sending to the watchface")) {
                model.settings.isWatchfaceDataEnabled = true
            }
            Button(LocalizedString("Later", comment: "Garmin settings: switch later"), role: .cancel) {}
        } message: {
            Text(LocalizedString("Sending to the watchface is paused. Choose the new watch app on the watch, then tap Resume Sending.", comment: "Garmin settings: watchface switch message"))
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(model.devices, id: \.uuid) { device in
                // One text view: the swipe has less layout to get out of step with.
                Text("\(device.friendlyName ?? "")\n\(Text(device.modelName ?? "").font(.footnote).foregroundStyle(.secondary))")
                    .contextMenu {
                        Button(role: .destructive) {
                            model.removeDevice(device)
                        } label: {
                            Label(LocalizedString("Remove", comment: "Garmin settings: remove a watch"), systemImage: "trash")
                        }
                    }
            }
            .onDelete(perform: model.removeDevices)
            Button(LocalizedString("Add Garmin Watch", comment: "Garmin settings: choose watches in Garmin Connect"), action: model.addDevices)
        } header: {
            Text(LocalizedString("Watches", comment: "Garmin settings: devices section"))
        } footer: {
            Text(LocalizedString("Garmin Connect opens to choose the watches. Swipe, or tap Edit, to remove one.", comment: "Garmin settings: devices footer"))
        }
    }

    private var watchAppSection: some View {
        Section {
            Picker(LocalizedString("Watchface", comment: "Garmin settings: watchface picker"), selection: watchfaceBinding) {
                ForEach(GarminWatchface.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(LocalizedString("Send to Watchface", comment: "Garmin settings: watchface data toggle"), isOn: $model.settings.isWatchfaceDataEnabled)
            Text(LocalizedString("Datafields", comment: "Garmin settings: datafield selection heading"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(GarminDatafield.selectableCases) { datafield in
                Button {
                    model.settings.toggleDatafield(datafield)
                } label: {
                    HStack {
                        Text(datafield.displayName)
                            .foregroundStyle(model.settings.canSelectDatafield(datafield) ? Color.primary : Color.secondary)
                        Spacer()
                        if model.settings.datafields.contains(datafield) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!model.settings.canSelectDatafield(datafield))
                .accessibilityAddTraits(model.settings.datafields.contains(datafield) ? .isSelected : [])
            }
        } header: {
            Text(LocalizedString("Watch Apps", comment: "Garmin settings: watch apps section"))
        } footer: {
            Text(LocalizedString("Turn off Send to Watchface to use only datafields. Choose any of the datafields, or none. Complication is a watch app that puts the values in any watchface's complications. LoopGraph isn't in the Connect IQ store: install its build on the watch yourself.", comment: "Garmin settings: watch apps footer"))
        }
    }

    private var commandsSection: some View {
        Section {
            Toggle(LocalizedString("Enable Watch Commands", comment: "Garmin settings: commands master toggle"), isOn: $model.settings.isCommandControlEnabled)
            Toggle(LocalizedString("Allow Bolus Commands", comment: "Garmin settings: bolus commands toggle"), isOn: bolusCommandsBinding)
                .disabled(!model.settings.isCommandControlEnabled)
                .confirmationDialog(
                    LocalizedString("Allow Bolus Commands?", comment: "Garmin settings: confirm bolus commands title"),
                    isPresented: $confirmingBolusCommands,
                    titleVisibility: .visible
                ) {
                    Button(LocalizedString("Allow Bolus Commands", comment: "Garmin settings: confirm bolus commands button"), role: .destructive) {
                        model.settings.isBolusCommandEnabled = true
                    }
                    Button(LocalizedString("Cancel", comment: "Garmin settings: cancel bolus commands"), role: .cancel) {}
                } message: {
                    Text(LocalizedString("The watch will be able to deliver insulin without any confirmation on this phone. Only enable this if you keep your watch locked and under your control.", comment: "Garmin settings: confirm bolus commands message"))
                }
        } header: {
            Text(LocalizedString("Commands", comment: "Garmin settings: commands section"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedString("Lets your Garmin watch log carbs and start overrides. Allow Bolus Commands also lets it give boluses. Both are off by default.\n\nA watch bolus needs a glucose reading from the last 15 minutes and must come at least 6 minutes after the previous watch bolus. The app still applies its maximum bolus.", comment: "Garmin settings: commands footer"))
                Text(LocalizedString("Only turn this on if you keep your watch locked and with you.", comment: "Garmin settings: commands warning")).bold()
            }
        }
    }

    /// A new watchface and the pause of sending to it are one settings change, so the command
    /// app isn't switched twice. Already off on purpose: it stays off and nothing is asked.
    private var watchfaceBinding: Binding<GarminWatchface> {
        Binding(
            get: { model.settings.watchface },
            set: { newValue in
                guard newValue != model.settings.watchface else { return }
                var settings = model.settings
                settings.watchface = newValue
                let asks = settings.isWatchfaceDataEnabled
                settings.isWatchfaceDataEnabled = false
                model.settings = settings
                if asks { confirmingWatchfaceSwitch = true }
            }
        )
    }

    /// Turning bolus commands on asks first; turning them off does not.
    private var bolusCommandsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.isBolusCommandEnabled },
            set: { newValue in
                if newValue {
                    confirmingBolusCommands = true
                } else {
                    model.settings.isBolusCommandEnabled = false
                }
            }
        )
    }

    private var displaySection: some View {
        Section {
            Picker(LocalizedString("Primary Value", comment: "Garmin settings: primary attribute"), selection: $model.settings.primaryAttributeChoice) {
                ForEach(GarminPrimaryAttributeChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(LocalizedString("Secondary Value", comment: "Garmin settings: secondary attribute"), selection: $model.settings.secondaryAttributeChoice) {
                ForEach(GarminSecondaryAttributeChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(LocalizedString("Glucose Colors", comment: "Garmin settings: glucose colour scheme"), selection: $model.settings.glucoseColorScheme) {
                ForEach(GarminGlucoseColorScheme.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text(LocalizedString("Display", comment: "Garmin settings: display section"))
        } footer: {
            Text(LocalizedString("What the Trio and SwissAlpine watch apps show next to glucose. Sens Ratio is shown with Trio only; TBR is the temp basal rate, evBG the eventual glucose.", comment: "Garmin settings: display footer"))
        }
    }

    /// Its own section: one feature, its settings and its own note. Period and Range
    /// show only while it's on.
    private var timeInRangeSection: some View {
        Section {
            Toggle(LocalizedString("Show on Watch", comment: "Garmin settings: time in range on or off"), isOn: $model.settings.isTimeInRangeEnabled)
            if model.settings.isTimeInRangeEnabled {
                Picker(LocalizedString("Period", comment: "Garmin settings: time in range period"), selection: $model.settings.timeInRangePeriod) {
                    ForEach(GarminTimeInRangePeriod.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(LocalizedString("Range", comment: "Garmin settings: time in range bounds"), selection: $model.settings.timeInRangeTarget) {
                    ForEach(GarminTimeInRangeTarget.allCases) {
                        Text($0.displayName(isMillimolesPerLiter: model.manager.isMillimolesPerLiterHost)).tag($0)
                    }
                }
            }
        } header: {
            Text(LocalizedString("Time in Range", comment: "Garmin settings: time in range section"))
        } footer: {
            Text(LocalizedString("For watch apps that show it: the share of glucose readings below, in and above the range.", comment: "Garmin settings: time in range footer"))
        }
    }
}
