#if os(macOS)
// "Profiles" tab of the Fan Control settings pane.
// The profile set is fixed (`ProfileStore`): the presets Automatic,
// Constant Quiet, Constant High, Boost and Max are shown read-only with their
// parameters (Boost with its real multi-point curve); Custom 1 / Custom 2 are
// editable (per-fan mode, sensor, multi-point fan curve — `FanCurveEditorView`,
// 2026-10-20, replaces the start / maximum temperature steppers —, constant RPM; rename)
// and can be reset to their default. No profiles are created or deleted. This is the only
// place where profiles are edited (the notch widget only selects one).

import SwiftUI
import FanControlCore
import FanControlKit

public struct FanControlProfilesTabView: View {

    @Binding var actionError: String?
    /// Profile selected when the tab first appears (e.g. a deep link or the
    /// app's DEBUG preview hook); `nil` = the active profile.
    var initialSelection: UUID? = nil

    public init(actionError: Binding<String?>, initialSelection: UUID? = nil) {
        _actionError = actionError
        self.initialSelection = initialSelection
    }

    @StoredSetting(.fanControlWidgetSettings) private var widgetSettings
    /// Apply is disabled while the feature is off: applying a manual profile
    /// starts monitoring and opens the helper session.
    @StoredSetting(.fanControlGeneralSettings) private var general

    @State private var selectedID: UUID?
    /// Working copy of the selected profile with explicit per-fan modes
    /// (`FanProfile.resolved(for:)`); saved explicitly (custom slots only).
    @State private var draft: FanProfile?
    @State private var isConfirmingReset = false

    private var manager: FanControlManager { FanControlManager.shared }

    private var storedSelection: FanProfile? {
        selectedID.flatMap { manager.profileStore.profile(id: $0) }?.resolved(for: manager.fans)
    }

    public var body: some View {
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
                    policy: manager.safetyPolicy,
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
                    Text("Preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    let policy: SafetyPolicy
    let onApply: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void
    let onReset: () -> Void

    private var isEditable: Bool { draft.isCustomSlot }

    /// A sensor-based fan's curve has a blocking validation error (Save / Apply disabled).
    private var hasCurveErrors: Bool {
        isEditable && fans.contains { fan in
            guard case .sensor = draft.mode(for: fan), let curve = draft.curve(for: fan) else { return false }
            return FanCurveEditorView.hasErrors(curve, fan: fan)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isEditable {
                    TextField("Profile Name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(verbatim: FanControlFormatting.profileName(draft))
                        .font(.headline)
                    Text("Preset (read-only)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        ForEach(Array(fans.enumerated()), id: \.element.id) { index, fan in
                            FanModeEditor(fan: fan, color: FanCurveView.color(forFanAt: index), draft: $draft,
                                          isEditable: isEditable, sensors: sensors, unit: unit,
                                          emergencyTemperature: emergencyTemperature,
                                          currentRPM: currentRPMs[fan.id])
                            Divider()
                        }
                    }
                    .padding(.trailing, 8)
                }
            }

            Spacer(minLength: 0)

            if hasCurveErrors {
                Label("Fix the fan curve before saving.", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !canApply {
                Text("Turn on Fan Control in the General tab to apply profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Apply", action: onApply)
                    .disabled(!canApply || hasCurveErrors)
                Spacer()
                if isEditable {
                    Button("Reset to Default", action: onReset)
                        .disabled(!isModified && !isDirty)
                    Button("Revert", action: onRevert)
                        .disabled(!isDirty)
                    Button("Save", action: onSave)
                        .disabled(!isDirty || hasCurveErrors)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the profile does (presets) or how to edit it (custom slots). Preset descriptions
    /// say what their curve looks like (2026-10-20).
    private var description: String {
        switch draft.id {
        case FanProfile.BuiltInID.automatic:
            return String(localized: "macOS (the SMC) controls every fan, so there is no curve. Fan control returns the fans to automatic.")
        case FanProfile.BuiltInID.constantQuiet, FanProfile.BuiltInID.constantHigh:
            let rpm: Int
            if case .constant(let value) = draft.defaultMode { rpm = value } else { rpm = 0 }
            return String(localized: "Every fan at a constant \(rpm.formatted()) RPM (limited to each fan's range): the curve is a flat line. Read-only preset.")
        case FanProfile.BuiltInID.max:
            let rpm: Int
            if case .constant(let value) = draft.defaultMode { rpm = value } else { rpm = FanProfile.Preset.maxRPM }
            return String(localized: "Every fan at full speed (\(rpm.formatted()) RPM, limited to each fan's maximum): a flat line at the top of the chart. The loudest setting. Read-only preset.")
        case FanProfile.BuiltInID.boost:
            return boostDescription
        default:
            return String(localized: "Editable profile. Choose a mode for each fan; a sensor-based fan follows its own curve (drag the points or use the rows below). Then Save or Apply.")
        }
    }

    /// Boost: the sensor, the curve's points, and how loud it is at idle (`agg:cpu` is the
    /// hottest core and idles at ≈ 72–78 °C on Apple Silicon, so Boost is loud even when idle),
    /// with the live value when the sensor is readable.
    private var boostDescription: String {
        let sensorName: String
        if case .sensor(let key, _, _)? = draft.defaultMode {
            sensorName = sensors.first { $0.id == key }.map(FanControlFormatting.sensorName)
                ?? NSLocalizedString("CPU (max)", comment: "Aggregate sensor name")
        } else {
            sensorName = NSLocalizedString("CPU (max)", comment: "Aggregate sensor name")
        }
        let curve = draft.defaultCurve ?? FanProfile.Preset.boostCurve
        let points = FanControlFormatting.curvePointsSummary(curve, unit: unit)
        var text = String(localized: "Every fan follows \(sensorName) on a smooth curve through \(points), reaching full speed well before the emergency threshold. Read-only preset.")
        text += " " + String(localized: "Note: CPU (max) is the hottest core, which idles at about 72–78 °C on Apple Silicon, so Boost runs the fans at about 5,500 RPM or more even when the Mac is idle.")
        if case .sensor(let key, _, _)? = draft.defaultMode, let fan = fans.first,
           let temperature = FanControlManager.shared.controlTemperature(for: key), temperature.isFinite,
           let rpm = FanControlEngine.targetRPM(for: draft, fan: fan, sensorTemperature: temperature, policy: policy) {
            text += " " + String(localized: "Now: \(FanControlFormatting.temperature(temperature, unit: unit)) → \(rpm.formatted()) RPM.")
        }
        return text
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { FanControlFormatting.profileName(draft) },
            set: { draft.name = $0 }
        )
    }
}

/// Colour key of `FanCurveView` (one swatch per fan).
public struct FanCurveLegend: View {
    let fans: [FanDevice]

    public init(fans: [FanDevice]) {
        self.fans = fans
    }

    public var body: some View {
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

/// Mode of one fan in the draft: automatic, constant (slider) or sensor-based (sensor picker +
/// multi-point curve, `FanCurveEditorView`). Edits go to the draft with explicit per-fan entries
/// (`modes[fan.id]`, also `.automatic`, so they override `defaultMode`); a sensor-based fan's
/// curve is stored with `FanProfile.setCurve`, other modes drop the fan's curve.
private struct FanModeEditor: View {

    private enum Kind: Hashable { case automatic, constant, sensor }

    let fan: FanDevice
    let color: Color
    @Binding var draft: FanProfile
    let isEditable: Bool
    let sensors: [SensorReading]
    let unit: TemperatureUnit
    let emergencyTemperature: Double
    let currentRPM: Int?

    private var mode: FanControlMode { draft.mode(for: fan) }

    private func setMode(_ mode: FanControlMode) {
        draft.modes[fan.id] = mode
        draft.curves[fan.id] = nil
    }

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
            .disabled(!isEditable)

            switch mode {
            case .automatic:
                Text("Controlled by the system")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .constant(let rpm):
                constantEditor(rpm: rpm)
                    .disabled(!isEditable)
            case .sensor(let key, _, _):
                sensorEditor(key: key)
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
                setMode(.constant(rpm: Swift.min(Swift.max(rounded, fan.rpmRange.lowerBound), fan.rpmRange.upperBound)))
            }
        )
    }

    // MARK: Sensor-based

    @ViewBuilder
    private func sensorEditor(key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            .disabled(!isEditable)
            // The multi-point curve replaces the old start / maximum temperature steppers
            // (its first / last points are the mode's start / maximum temperature).
            FanCurveEditorView(fan: fan, color: color, sensorKey: key, curve: curveBinding, unit: unit,
                               emergencyTemperature: emergencyTemperature, currentRPM: currentRPM,
                               isEditable: isEditable)
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

    private var sensorKey: String {
        if case .sensor(let key, _, _) = mode { return key }
        return defaultSensorKey
    }

    /// The curve that drives the fan (stored multi-point curve, or the mode's linear ramp).
    private var currentCurve: FanCurve {
        draft.curve(for: fan) ?? FanCurve.boost.resolved(for: fan)
    }

    private var curveBinding: Binding<FanCurve> {
        Binding(
            get: { currentCurve },
            set: { draft.setCurve($0, sensorKey: sensorKey, forFan: fan.id) }
        )
    }

    private var sensorKeyBinding: Binding<String> {
        Binding(
            get: { sensorKey },
            set: { key in draft.setCurve(currentCurve, sensorKey: key, forFan: fan.id) }
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
                    setMode(.automatic)
                case .constant:
                    if case .constant = mode { return }
                    let range = fan.rpmRange
                    setMode(.constant(rpm: range.lowerBound + (range.upperBound - range.lowerBound) / 2))
                case .sensor:
                    if case .sensor = mode { return }
                    // New sensor-based fans start from the Boost curve (resolved for this fan).
                    draft.setCurve(FanCurve.boost.resolved(for: fan), sensorKey: defaultSensorKey, forFan: fan.id)
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
