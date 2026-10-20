#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// "Profiles" tab of the Fan Control settings pane (replaces the earlier
// profile editor dialogs, design doc §4.4).
// The profile set is fixed (`ProfileStore`): the presets Automatic,
// Constant Quiet, Constant High and Boost are shown read-only with their
// parameters; Custom 1 / Custom 2 are editable (per-fan mode, sensor,
// start / maximum temperature, constant RPM; rename) and can be reset to
// their default. No profiles are created or deleted. This is the only place
// where profiles are edited (the notch widget only selects one).

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlProfilesTabView: View {

    @Binding var actionError: String?
    /// Profile selected when the tab first appears (e.g. a deep link or the
    /// app's DEBUG preview hook); `nil` = the active profile.
    var initialSelection: UUID? = nil

    @Default(.fanControlWidgetSettings) private var widgetSettings
    /// Apply is disabled while the feature is off: applying a manual profile
    /// starts monitoring and opens the helper session.
    @Default(.fanControlGeneralSettings) private var general

    @State private var selectedID: UUID?
    /// Working copy of the selected profile with explicit per-fan modes
    /// (`FanProfile.resolved(for:)`); saved explicitly (custom slots only).
    @State private var draft: FanProfile?
    @State private var isConfirmingReset = false

    private var manager: FanControlManager { FanControlManager.shared }

    private var storedSelection: FanProfile? {
        selectedID.flatMap { manager.profileStore.profile(id: $0) }?.resolved(for: manager.fans)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileList(selectedID: $selectedID,
                        profiles: FanControlProfiles.all,
                        activeID: FanControlProfiles.activeID)
                .frame(width: 170)

            Divider()

            if let binding = Binding($draft) {
                ProfileEditor(
                    draft: binding,
                    isDirty: draft != storedSelection,
                    isModified: draft.map { manager.profileStore.isModified(id: $0.id, fans: manager.fans) } ?? false,
                    isActive: FanControlProfiles.activeID == draft?.id,
                    canApply: general.isEnabled,
                    fans: manager.fans,
                    sensors: manager.sensorReadings,
                    currentRPMs: manager.currentRPMs,
                    unit: widgetSettings.temperatureUnit,
                    emergencyTemperature: manager.safetyPolicy.emergencyTemperature,
                    onApply: applyDraft,
                    onSave: saveDraft,
                    onRevert: loadDraft,
                    onReset: { isConfirmingReset = true }
                )
            } else {
                Text("Select a profile")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onAppear {
            if selectedID == nil, let initialSelection, FanProfile.fixedProfileIDs.contains(initialSelection) {
                selectedID = initialSelection
            }
            if selectedID == nil {
                let active = FanControlProfiles.activeID
                selectedID = FanProfile.fixedProfileIDs.contains(active) ? active : FanProfile.BuiltInID.automatic
            }
            loadDraft()
        }
        .onChange(of: selectedID) { _, _ in loadDraft() }
        // Fans are discovered asynchronously; re-materialize an untouched draft.
        .onChange(of: manager.fans) { _, _ in
            if let draft, draft.modes.isEmpty || !draft.isCustomSlot { loadDraft() }
        }
        .confirmationDialog("Reset this profile to its default settings?", isPresented: $isConfirmingReset) {
            Button("Reset to Default", role: .destructive, action: resetDraft)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes to this profile, including its name, are discarded.")
        }
    }

    // MARK: Actions

    private func loadDraft() {
        draft = storedSelection
    }

    private func saveDraft() {
        guard let draft, draft.isCustomSlot else { return }
        manager.saveProfile(draft)
    }

    private func applyDraft() {
        guard let draft else { return }
        if draft.isCustomSlot, draft != storedSelection {
            manager.saveProfile(draft)
        }
        fanControlPerform($actionError) { try await FanControlProfiles.apply(draft) }
    }

    /// Restores the slot's default. If it is the active profile, the next poll
    /// applies the default content (as with any edit of the active profile).
    private func resetDraft() {
        guard let draft, draft.isCustomSlot, let fresh = FanProfile.fixedDefault(id: draft.id) else { return }
        manager.saveProfile(fresh)
        self.draft = fresh.resolved(for: manager.fans)
    }
}

// MARK: - Profile list

private struct ProfileList: View {
    @Binding var selectedID: UUID?
    let profiles: [FanProfile]
    let activeID: UUID?

    var body: some View {
        List(selection: $selectedID) {
            Section("Presets") {
                rows(profiles.filter { !$0.isCustomSlot })
            }
            Section("Custom") {
                rows(profiles.filter(\.isCustomSlot))
            }
        }
        .listStyle(.bordered)
    }

    private func rows(_ items: [FanProfile]) -> some View {
        ForEach(items) { profile in
            HStack {
                Text(verbatim: FanControlFormatting.profileName(profile))
                    .lineLimit(1)
                Spacer()
                if profile.id == activeID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                } else if !profile.isCustomSlot {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .tag(profile.id)
        }
    }
}

// MARK: - Profile editor

private struct ProfileEditor: View {
    @Binding var draft: FanProfile
    /// The draft differs from the stored profile (unsaved edits).
    let isDirty: Bool
    /// The stored profile differs from its factory default (Reset enabled).
    let isModified: Bool
    let isActive: Bool
    let canApply: Bool
    let fans: [FanDevice]
    let sensors: [SensorReading]
    let currentRPMs: [Int: Int]
    let unit: TemperatureUnit
    let emergencyTemperature: Double
    let onApply: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void
    let onReset: () -> Void

    private var isEditable: Bool { draft.isCustomSlot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isEditable {
                    TextField("Profile Name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(verbatim: FanControlFormatting.profileName(draft))
                        .font(.headline)
                }
                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }

            Text(verbatim: description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if fans.isEmpty {
                Text("No fans detected")
                    .foregroundStyle(.secondary)
            } else {
                // Curve + per-fan editors scroll inside the pane's fixed size.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        FanCurveView(profile: draft, fans: fans, sensors: sensors, currentRPMs: currentRPMs,
                                     unit: unit, emergencyTemperature: emergencyTemperature, style: .regular)
                            .frame(height: 110)
                        FanCurveLegend(fans: fans)
                        Divider()
                        ForEach(fans) { fan in
                            FanModeEditor(fan: fan, mode: modeBinding(for: fan), sensors: sensors, unit: unit)
                                .disabled(!isEditable)
                            Divider()
                        }
                    }
                    .padding(.trailing, 8)
                }
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
                if isEditable {
                    Button("Reset to Default", action: onReset)
                        .disabled(!isModified && !isDirty)
                    Button("Revert", action: onRevert)
                        .disabled(!isDirty)
                    Button("Save", action: onSave)
                        .disabled(!isDirty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the profile does (presets) or how to edit it (custom slots).
    private var description: String {
        switch draft.id {
        case FanProfile.BuiltInID.automatic:
            return String(localized: "macOS (the SMC) controls every fan. Fan control returns the fans to automatic.")
        case FanProfile.BuiltInID.constantQuiet, FanProfile.BuiltInID.constantHigh:
            let rpm: Int
            if case .constant(let value) = draft.defaultMode { rpm = value } else { rpm = 0 }
            return String(localized: "Every fan at a constant \(rpm.formatted()) RPM (limited to each fan's range). Read-only preset.")
        case FanProfile.BuiltInID.boost:
            let summary = draft.defaultMode.map { FanControlFormatting.modeSummary($0, sensors: sensors, unit: unit) } ?? ""
            return String(localized: "Every fan follows \(summary): minimum speed at the start temperature, maximum speed at the maximum temperature. Read-only preset.")
        default:
            return String(localized: "Editable profile. Choose a mode for each fan, then Save or Apply.")
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { FanControlFormatting.profileName(draft) },
            set: { draft.name = $0 }
        )
    }

    /// Explicit per-fan entries (also `.automatic`), so they override `defaultMode`.
    private func modeBinding(for fan: FanDevice) -> Binding<FanControlMode> {
        Binding(
            get: { draft.mode(for: fan) },
            set: { draft.modes[fan.id] = $0 }
        )
    }
}

/// Colour key of `FanCurveView` (one swatch per fan).
struct FanCurveLegend: View {
    let fans: [FanDevice]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(fans.enumerated()), id: \.element.id) { index, fan in
                HStack(spacing: 4) {
                    Circle().fill(FanCurveView.color(forFanAt: index)).frame(width: 7, height: 7)
                    Text(verbatim: fan.name)
                }
            }
            Spacer(minLength: 0)
            Text("Dot = current speed")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
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
            // Name on its own line: next to the fixed-size segmented picker it could be
            // squeezed to zero width and wrap one character per line (very tall pane).
            HStack {
                Text(verbatim: fan.name)
                    .bold()
                    .lineLimit(1)
                Text(verbatim: "\(fan.rpmRange.lowerBound.formatted())–\(fan.rpmRange.upperBound.formatted()) RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Picker("", selection: kind) {
                Text("Automatic").tag(Kind.automatic)
                Text("Constant").tag(Kind.constant)
                Text("Sensor-based").tag(Kind.sensor)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

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
                    .fixedSize()
                Spacer()
                Picker("", selection: sensorKeyBinding) {
                    if !sensors.contains(where: { $0.id == key }) {
                        Text("Unavailable sensor (\(key))").tag(key)
                    }
                    if aggregateSensors.isEmpty {
                        sensorRows(individualSensors)
                    } else {
                        Section("Aggregate") {
                            sensorRows(aggregateSensors)
                        }
                        Section("Individual Sensors") {
                            sensorRows(individualSensors)
                        }
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

    /// Aggregate sensors ("CPU (max)", …; `SensorAggregator`), listed first.
    private var aggregateSensors: [SensorReading] { sensors.filter(\.isAggregate) }
    private var individualSensors: [SensorReading] { sensors.filter { !$0.isAggregate } }

    private func sensorRows(_ rows: [SensorReading]) -> some View {
        ForEach(rows) { sensor in
            Text(verbatim: "\(FanControlFormatting.sensorName(sensor)) (\(sensor.id)) · \(FanControlFormatting.temperature(sensor, unit: unit))")
                .tag(sensor.id)
        }
    }

    private var sensorParameters: (key: String, start: Double, max: Double) {
        if case .sensor(let key, let start, let maxTemperature) = mode { return (key, start, maxTemperature) }
        return (defaultSensorKey, FanProfile.Preset.boostStartTemperature, FanProfile.Preset.boostMaxTemperature)
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
                    mode = .sensor(sensorKey: defaultSensorKey,
                                   startTemperature: FanProfile.Preset.boostStartTemperature,
                                   maxTemperature: FanProfile.Preset.boostMaxTemperature)
                }
            }
        )
    }

    /// The CPU (max) aggregate when present, else the hottest CPU/GPU sensor,
    /// else the first sensor, else empty.
    private var defaultSensorKey: String {
        if sensors.contains(where: { $0.id == SensorAggregator.ID.cpu }) { return SensorAggregator.ID.cpu }
        return FanControlEngine.hottestEmergencySensor(sensors, policy: .default)?.id ?? sensors.first?.id ?? ""
    }
}
#endif
