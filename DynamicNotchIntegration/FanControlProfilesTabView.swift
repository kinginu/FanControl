#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// "Profiles" tab of the Fan Control settings pane: profile list, apply, and a
// per-fan mode editor for custom profiles (replaces the earlier
// profile editor dialogs, design doc §4.4).
// Built-in profiles are read-only; duplicate one to customize it.

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlProfilesTabView: View {

    @Binding var actionError: String?

    @Default(.fanControlWidgetSettings) private var widgetSettings
    /// Apply is disabled while the feature is off: applying a manual profile
    /// starts monitoring and opens the helper session.
    @Default(.fanControlGeneralSettings) private var general

    @State private var selectedID: UUID?
    /// Working copy of the selected profile; saved explicitly.
    @State private var draft: FanProfile?
    @State private var isConfirmingDelete = false

    private var manager: FanControlManager { FanControlManager.shared }

    private var storedSelection: FanProfile? {
        manager.availableProfiles.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileList(selectedID: $selectedID,
                        profiles: manager.availableProfiles,
                        activeID: manager.activeProfile?.id,
                        onAdd: addProfile)
                .frame(width: 170)

            Divider()

            if let binding = Binding($draft) {
                ProfileEditor(
                    draft: binding,
                    isDirty: draft != storedSelection,
                    isActive: manager.activeProfile?.id == draft?.id,
                    canApply: general.isEnabled,
                    fans: manager.fans,
                    sensors: manager.sensorReadings,
                    unit: widgetSettings.temperatureUnit,
                    onApply: applyDraft,
                    onSave: saveDraft,
                    onRevert: loadDraft,
                    onDuplicate: duplicateDraft,
                    onDelete: { isConfirmingDelete = true }
                )
            } else {
                Text("Select a profile")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onAppear {
            if selectedID == nil {
                selectedID = manager.activeProfile?.id ?? manager.availableProfiles.first?.id
            }
            loadDraft()
        }
        .onChange(of: selectedID) { _, _ in loadDraft() }
        .confirmationDialog("Delete this profile?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive, action: deleteDraft)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: Actions

    /// Loads the stored profile into the editor. Keeps a just-created draft if
    /// the manager has not published it in `availableProfiles` yet.
    private func loadDraft() {
        if let stored = storedSelection {
            draft = stored
        } else if draft?.id != selectedID {
            draft = nil
        }
    }

    private func saveDraft() {
        guard let draft, !draft.isBuiltIn else { return }
        manager.saveProfile(draft)
    }

    private func applyDraft() {
        guard let draft else { return }
        if !draft.isBuiltIn, draft != storedSelection {
            manager.saveProfile(draft)
        }
        fanControlPerform($actionError) { try await manager.applyProfile(draft) }
    }

    private func addProfile() {
        let profile = FanProfile(name: String(localized: "New Profile"))
        manager.saveProfile(profile)
        selectedID = profile.id
        draft = profile
    }

    private func duplicateDraft() {
        guard let draft else { return }
        let name = FanControlFormatting.profileName(draft)
        let copy = FanProfile(name: String(localized: "\(name) Copy"), modes: draft.modes, isBuiltIn: false)
        manager.saveProfile(copy)
        selectedID = copy.id
        self.draft = copy
    }

    private func deleteDraft() {
        guard let draft, !draft.isBuiltIn else { return }
        manager.deleteProfile(draft)
        selectedID = manager.availableProfiles.first?.id
        loadDraft()
    }
}

// MARK: - Profile list

private struct ProfileList: View {
    @Binding var selectedID: UUID?
    let profiles: [FanProfile]
    let activeID: UUID?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(profiles, selection: $selectedID) { profile in
                HStack {
                    Text(verbatim: FanControlFormatting.profileName(profile))
                        .lineLimit(1)
                    Spacer()
                    if profile.id == activeID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    } else if profile.isBuiltIn {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tag(profile.id)
            }
            .listStyle(.bordered)

            Button(action: onAdd) {
                Label("New Profile", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Profile editor

private struct ProfileEditor: View {
    @Binding var draft: FanProfile
    let isDirty: Bool
    let isActive: Bool
    let canApply: Bool
    let fans: [FanDevice]
    let sensors: [SensorReading]
    let unit: TemperatureUnit
    let onApply: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if draft.isBuiltIn {
                    Text(verbatim: FanControlFormatting.profileName(draft))
                        .font(.headline)
                } else {
                    TextField("Profile Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }

            if draft.isBuiltIn {
                Text("Built-in profiles are read-only. Duplicate one to customize it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if fans.isEmpty {
                Text("No fans detected")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(fans) { fan in
                            FanModeEditor(fan: fan, mode: modeBinding(for: fan), sensors: sensors, unit: unit)
                            Divider()
                        }
                    }
                }
                .disabled(draft.isBuiltIn)
            }

            Spacer(minLength: 0)

            if !canApply {
                Text("Turn on Fan Control in the General tab to apply profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Apply", action: onApply)
                    .disabled(!canApply)
                Spacer()
                Button("Duplicate", action: onDuplicate)
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(draft.isBuiltIn)
                Button("Revert", action: onRevert)
                    .disabled(draft.isBuiltIn || !isDirty)
                Button("Save", action: onSave)
                    .disabled(draft.isBuiltIn || !isDirty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.automatic` is stored as a missing entry (see `FanProfile.modes`).
    private func modeBinding(for fan: FanDevice) -> Binding<FanControlMode> {
        Binding(
            get: { draft.mode(for: fan) },
            set: { draft.modes[fan.id] = $0.isManual ? $0 : nil }
        )
    }
}

// MARK: - Per-fan mode editor

private struct FanModeEditor: View {

    private enum Kind: Hashable { case automatic, constant, sensor }

    let fan: FanDevice
    @Binding var mode: FanControlMode
    let sensors: [SensorReading]
    let unit: TemperatureUnit

    /// Temperature limits for the sensor-based mode (°C).
    private static let startRange: ClosedRange<Double> = 20...105
    private static let maxRange: ClosedRange<Double> = 21...110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: fan.name)
                    .bold()
                Text(verbatim: "\(fan.rpmRange.lowerBound.formatted())–\(fan.rpmRange.upperBound.formatted()) RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: kind) {
                    Text("Automatic").tag(Kind.automatic)
                    Text("Constant").tag(Kind.constant)
                    Text("Sensor-based").tag(Kind.sensor)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            switch mode {
            case .automatic:
                Text("Controlled by the system")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .constant(let rpm):
                constantEditor(rpm: rpm)
            case .sensor(let key, let start, let maxTemperature):
                sensorEditor(key: key, start: start, maxTemperature: maxTemperature)
            }
        }
    }

    // MARK: Constant

    @ViewBuilder
    private func constantEditor(rpm: Int) -> some View {
        let range = fan.rpmRange
        HStack {
            if range.lowerBound < range.upperBound {
                // Step 1 so both ends are reachable for any range; the binding
                // rounds to 10 RPM (clamped to the range).
                Slider(value: rpmBinding, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            }
            Text(verbatim: "\(FanControlEngine.clamp(rpm, to: fan).formatted()) RPM")
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
    }

    private var rpmBinding: Binding<Double> {
        Binding(
            get: {
                if case .constant(let rpm) = mode { return Double(FanControlEngine.clamp(rpm, to: fan)) }
                return Double(fan.rpmRange.lowerBound)
            },
            set: { value in
                let rounded = Int((value / 10).rounded()) * 10
                mode = .constant(rpm: Swift.min(Swift.max(rounded, fan.rpmRange.lowerBound), fan.rpmRange.upperBound))
            }
        )
    }

    // MARK: Sensor-based

    @ViewBuilder
    private func sensorEditor(key: String, start: Double, maxTemperature: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sensor")
                Spacer()
                Picker("", selection: sensorKeyBinding) {
                    if !sensors.contains(where: { $0.id == key }) {
                        Text("Unavailable sensor (\(key))").tag(key)
                    }
                    ForEach(sensors) { sensor in
                        Text(verbatim: "\(sensor.name) (\(sensor.id)) · \(FanControlFormatting.temperature(sensor, unit: unit))")
                            .tag(sensor.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Stepper(value: startBinding, in: Self.startRange, step: 1) {
                HStack {
                    Text("Start Temperature")
                    Spacer()
                    Text(verbatim: FanControlFormatting.temperature(start, unit: unit))
                        .monospacedDigit()
                }
            }
            Stepper(value: maxTemperatureBinding, in: Self.maxRange, step: 1) {
                HStack {
                    Text("Maximum Temperature")
                    Spacer()
                    Text(verbatim: FanControlFormatting.temperature(maxTemperature, unit: unit))
                        .monospacedDigit()
                }
            }
            Text("Minimum speed at or below the start temperature, maximum speed at or above the maximum temperature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sensorParameters: (key: String, start: Double, max: Double) {
        if case .sensor(let key, let start, let maxTemperature) = mode { return (key, start, maxTemperature) }
        return (defaultSensorKey, 50, 80)
    }

    private var sensorKeyBinding: Binding<String> {
        Binding(
            get: { sensorParameters.key },
            set: { key in
                let p = sensorParameters
                mode = .sensor(sensorKey: key, startTemperature: p.start, maxTemperature: p.max)
            }
        )
    }

    /// Keeps `start < max` by pushing the other bound.
    private var startBinding: Binding<Double> {
        Binding(
            get: { sensorParameters.start },
            set: { start in
                let p = sensorParameters
                mode = .sensor(sensorKey: p.key, startTemperature: start, maxTemperature: Swift.max(p.max, start + 1))
            }
        )
    }

    private var maxTemperatureBinding: Binding<Double> {
        Binding(
            get: { sensorParameters.max },
            set: { maxTemperature in
                let p = sensorParameters
                mode = .sensor(sensorKey: p.key, startTemperature: Swift.min(p.start, maxTemperature - 1), maxTemperature: maxTemperature)
            }
        )
    }

    // MARK: Kind switching

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch mode {
                case .automatic: return .automatic
                case .constant: return .constant
                case .sensor: return .sensor
                }
            },
            set: { newKind in
                switch newKind {
                case .automatic:
                    mode = .automatic
                case .constant:
                    if case .constant = mode { return }
                    let range = fan.rpmRange
                    mode = .constant(rpm: range.lowerBound + (range.upperBound - range.lowerBound) / 2)
                case .sensor:
                    if case .sensor = mode { return }
                    mode = .sensor(sensorKey: defaultSensorKey, startTemperature: 50, maxTemperature: 80)
                }
            }
        )
    }

    /// Hottest CPU/GPU sensor, else the first sensor, else empty.
    private var defaultSensorKey: String {
        FanControlEngine.hottestEmergencySensor(sensors, policy: .default)?.id ?? sensors.first?.id ?? ""
    }
}
#endif
