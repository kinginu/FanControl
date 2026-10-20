#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The Fan Control Nook widget (design doc §4.1). Dispatched from the Nook grid
// for `NookWidget.fanControl` (PATCHES.md (b)).
//
// Layouts (DynamicNotch width = gridSizeType × 50 pt, cell height ≈ 202 pt):
//   - medium (2x1, 100 pt): header, fans stacked, then the profile list (all seven
//     profiles, one compact row each).
//   - doubleWide (5x1, 250 pt): header across the top; left column = profile list;
//     right column = fans, then the selected profile's details (name, type, fan curve with
//     the live operating point, per-fan target RPM).
//     With the profile list turned off: fans left, details right.
// Temperatures (CPU / GPU / SSD) are not shown here any more: they live in the Temperature
// widget (FanControlTemperatureWidgetView.swift, 2026-10-20). The header still turns red with
// a thermometer while the high-temperature alert is active.
// The list shows the seven fixed profiles (`ProfileStore`, Max included); the selected one is
// unmistakable (2026-10-20): accent checkmark + bold white text on a Liquid Glass pill
// (macOS 26; material fallback), the other rows are dimmer. Clicking a row applies that
// profile at once (spinner on the row while applying, a short error line on failure).
// Editing happens only in Settings ▸ Fan Control ▸ Profiles.
// Curves and targets come from the engine (`FanProfile.curve(for:)`, PCHIP; 
// `FanControlEngine.targetRPM(for: profile, …)`) at the smoothed control temperature
// (`FanControlManager.controlTemperature(for:)`), so Boost draws its real curve.
// `FanCurveView` and `FanControlKeyTemperaturesView` are also used by the settings pane.

import SwiftUI
import FanControlCore
import FanControlKit

struct FanControlWidgetView: View {

    @StoredSetting(.fanControlWidgetSettings) private var settings
    @StoredSetting(.fanControlGeneralSettings) private var general

    /// Preview / debug rendering only (e.g. the app's DEBUG `preview:` hook):
    /// select this profile in the list and show its details instead of the
    /// active profile's. `nil` (the Nook grid) = the active profile. Nothing is applied.
    var previewProfile: FanProfile? = nil
    /// Preview / debug rendering only: layout size instead of the setting.
    var previewGridSize: FanControlWidgetSettings.GridSizeChoice? = nil

    /// Transient apply failure shown in the widget (cleared after ~6 s or by the next successful apply).
    @State private var applyError: String? = nil
    @State private var isApplying = false
    @State private var errorClearTask: Task<Void, Never>? = nil
    /// The profile being applied (the pill moves to it at once; back on failure).
    @State private var pendingProfileID: UUID? = nil
    @Namespace private var selectionNamespace

    private var manager: FanControlManager { FanControlManager.shared }

    private var gridSize: FanControlWidgetSettings.GridSizeChoice { previewGridSize ?? settings.gridSize }
    private var isCompact: Bool { gridSize == .medium }

    /// The highlighted list row: the profile being applied, else the active one.
    private var selectedProfileID: UUID {
        pendingProfileID ?? previewProfile?.id ?? FanControlProfiles.activeID
    }

    /// The profile whose details are shown (the highlighted row).
    private var displayedProfile: FanProfile {
        if let pendingProfileID, let pending = FanControlProfiles.all.first(where: { $0.id == pendingProfileID }) {
            return pending
        }
        return previewProfile ?? FanControlProfiles.active
    }

    // Widget restyle (2026-10-20): typography / spacing / colours follow the other Nook widgets
    // (DynamicNotchApp NookWidgetChrome: 8 pt vertical inset, subheadline-semibold secondary
    // header, quaternary RPM track, hierarchical empty state).
    var body: some View {
        content
            .frame(width: gridSize.widthInPoints)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { FanControlWidgetPresence.widgetAppeared(isPreview: isPreview) }
            .onDisappear { FanControlWidgetPresence.widgetDisappeared(isPreview: isPreview) }
    }

    /// Preview / debug renders (DEBUG galleries) do not count as a shown widget.
    private var isPreview: Bool { previewProfile != nil || previewGridSize != nil }

    @ViewBuilder
    private var content: some View {
        if !general.isEnabled {
            FanControlEmptyState(systemImage: "fan", message: "Fan control disabled")
        } else if !manager.isSMCConnected {
            FanControlEmptyState(systemImage: "exclamationmark.triangle", message: "SMC unavailable")
        } else if manager.fans.isEmpty {
            FanControlEmptyState(systemImage: "fan", message: "No fans detected")
        } else if isCompact {
            VStack(alignment: .leading, spacing: 4) {
                header
                fanList
                if let applyError { errorLine(applyError) }
                if settings.showProfilePicker {
                    profileList
                        .padding(.top, 2)
                }
            }
        } else if settings.showProfilePicker {
            VStack(alignment: .leading, spacing: 6) {
                header
                HStack(alignment: .top, spacing: 8) {
                    profileList
                        .frame(width: 100, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 6) {
                        fanList
                        profileDetails
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    fanList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                profileDetails
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "fan")
                .symbolRenderingMode(.hierarchical)
            Text("Fans")
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if manager.highTempAlertActive {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(.red)
                    .help(Text("High temperature"))
                    .accessibilityLabel(Text("High temperature"))
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(manager.highTempAlertActive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
    }

    // MARK: Fans

    private var fanList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(settings.visibleFans(from: manager.fans)) { fan in
                FanRow(fan: fan,
                       currentRPM: manager.currentRPMs[fan.id],
                       targetRPM: settings.showTargetRPM ? manager.targetRPMs[fan.id] : nil,
                       isAnomalous: manager.anomalousFanIDs.contains(fan.id),
                       isCompact: isCompact)
            }
        }
    }

    // MARK: Profile list

    /// All seven fixed profiles, one row each; the selected row sits on a glass pill with an
    /// accent checkmark. Clicking a row applies that profile (no editing here).
    private var profileList: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : 1) {
            ForEach(FanControlProfiles.all) { profile in
                FanProfileListRow(title: FanControlFormatting.profileName(profile),
                                  isSelected: profile.id == selectedProfileID,
                                  isApplying: isApplying && profile.id == pendingProfileID,
                                  isCompact: isCompact,
                                  namespace: selectionNamespace) {
                    select(profile)
                }
                .disabled(isApplying)
            }
        }
        .animation(.snappy(duration: 0.25), value: selectedProfileID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Profiles"))
    }

    // MARK: Profile details

    @ViewBuilder
    private var profileDetails: some View {
        let profile = displayedProfile
        let fans = settings.visibleFans(from: manager.fans)
        VStack(alignment: .leading, spacing: 3) {
            FanProfileSummaryView(profile: profile, fans: fans, sensors: manager.sensorReadings,
                                  unit: settings.temperatureUnit, showsCurve: settings.showFanCurve)
            if settings.showFanCurve {
                FanCurveView(profile: profile,
                             fans: fans,
                             sensors: manager.sensorReadings,
                             currentRPMs: manager.currentRPMs,
                             unit: settings.temperatureUnit,
                             emergencyTemperature: manager.safetyPolicy.emergencyTemperature,
                             style: .compact)
                    .frame(minHeight: 36, maxHeight: 72)
            }
            FanTargetsView(profile: profile, fans: fans, policy: manager.safetyPolicy)
            if let applyError { errorLine(applyError) }
        }
    }

    /// Applies `profile` (moves the pill at once; back to the active profile on failure).
    /// A failure is shown as a short transient line instead of being swallowed.
    private func select(_ profile: FanProfile) {
        guard !isApplying, !isPreview, profile.id != FanControlProfiles.activeID else { return }
        isApplying = true
        pendingProfileID = profile.id
        Task { @MainActor in
            defer {
                isApplying = false
                pendingProfileID = nil
            }
            do {
                try await FanControlProfiles.apply(profile)
                showApplyError(nil)
            } catch {
                showApplyError(shortMessage(for: error))
            }
        }
    }

    private func shortMessage(for error: Error) -> String {
        if let fanError = error as? FanControlError, case .helperConnectionRejected = fanError {
            return String(localized: "Helper refused this build — see Settings")
        }
        return error.localizedDescription
    }

    private func showApplyError(_ message: String?) {
        errorClearTask?.cancel()
        applyError = message
        guard message != nil else { return }
        errorClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { applyError = nil }
        }
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 3) {
            Image(systemName: "exclamationmark.triangle")
            Text(verbatim: message)
                .lineLimit(isCompact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.red)
    }
}

// MARK: - Profile list row

/// One profile in the widget's list. The selected row is unmistakable: an accent checkmark,
/// bold white text and the glass pill (shared `matchedGeometryEffect`, so it slides between
/// rows). The other rows are dimmer (secondary, regular weight) with a faint hover fill. The
/// checkmark column is reserved on every row so the names stay aligned.
private struct FanProfileListRow: View {
    let title: String
    let isSelected: Bool
    let isApplying: Bool
    let isCompact: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// White in the (always dark) notch; primary in a light-mode preview.
    private var selectedTextStyle: AnyShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCompact ? 2 : 3) {
                ZStack {
                    if isApplying {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: isCompact ? 7 : 8, weight: .heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: isCompact ? 8 : 10)
                Text(verbatim: title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .font(isCompact ? .caption2 : .caption)
            .fontWeight(isSelected ? .bold : .regular)
            .foregroundStyle(isSelected ? selectedTextStyle : AnyShapeStyle(.secondary))
            .padding(.horizontal, isCompact ? 3 : 5)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 16 : 19, alignment: .leading)
            .contentShape(Capsule())
            .background {
                if isSelected {
                    FanControlSelectionPill()
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if isHovering {
                    Capsule().fill(.quinary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? Text("Active") : Text("Applies this profile"))
    }
}

/// The selection highlight: a Liquid Glass capsule on macOS 26 (Apple's selection style),
/// else an ultra-thin material capsule. Mirrors the host's `nookGlass` (NookWidgetChrome),
/// which the drop-in files cannot reference. `DN_DEBUG_NOGLASS=1` (DEBUG) forces the
/// fallback, because glass is not captured by offscreen `cacheDisplay` snapshots.
struct FanControlSelectionPill: View {
    #if DEBUG
    private static let forceFallback = ProcessInfo.processInfo.environment["DN_DEBUG_NOGLASS"] == "1"
    #else
    private static let forceFallback = false
    #endif

    var body: some View {
        if #available(macOS 26, *), !Self.forceFallback {
            Color.clear
                .glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(.tertiary))
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
    }
}

// MARK: - Profile details

/// Name and type of a profile: "Controlled by macOS", "Constant · 3,000 RPM",
/// "Sensor-based · CPU (max) 50–85°C · 5-point curve", or "Per-fan modes" when the fans differ.
/// For Automatic the type line is left out while the curve (which says
/// "Controlled by macOS" itself) is shown.
private struct FanProfileSummaryView: View {
    let profile: FanProfile
    let fans: [FanDevice]
    let sensors: [SensorReading]
    let unit: TemperatureUnit
    var showsCurve: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: FanControlFormatting.profileName(profile))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let typeDescription {
                Text(verbatim: typeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var typeDescription: String? {
        let modes = fans.map { profile.mode(for: $0) }
        let automatic = showsCurve ? nil : String(localized: "Controlled by macOS")
        guard let first = modes.first ?? profile.defaultMode else { return automatic }
        guard modes.allSatisfy({ $0 == first }) else {
            return String(localized: "Per-fan modes")
        }
        switch first {
        case .automatic:
            return automatic
        case .constant:
            return String(localized: "Constant") + " · "
                + FanControlFormatting.modeSummary(first, sensors: sensors, unit: unit)
        case .sensor:
            var text = String(localized: "Sensor-based") + " · "
                + FanControlFormatting.modeSummary(first, sensors: sensors, unit: unit)
            if let count = fans.first.flatMap({ profile.curve(for: $0) })?.normalized().points.count, count > 2 {
                text += " · " + String(localized: "\(count)-point curve")
            }
            return text
        }
    }
}

/// Per-fan target RPM of a profile at the current smoothed control temperature
/// (`FanControlEngine.targetRPM(for: profile, …)` on the profile's curve at
/// `FanControlManager.controlTemperature(for:)`, before the emergency override and the
/// stabilizer): "Target ● 3,000 ● 3,000", dots in the curve's fan colours, "Auto" for a fan
/// left to the SMC.
private struct FanTargetsView: View {
    let profile: FanProfile
    let fans: [FanDevice]
    let policy: SafetyPolicy

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        HStack(spacing: 6) {
            Text("Target")
                .foregroundStyle(.secondary)
            ForEach(Array(fans.enumerated()), id: \.element.id) { index, fan in
                HStack(spacing: 2) {
                    Circle()
                        .fill(FanCurveView.color(forFanAt: index))
                        .frame(width: 5, height: 5)
                    Text(verbatim: targetText(for: fan))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: fan.name))
                .accessibilityValue(Text(verbatim: accessibilityValue(for: fan)))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Target"))
    }

    private func target(for fan: FanDevice) -> Int?? {
        let mode = profile.mode(for: fan)
        guard mode.isManual else { return .some(nil) }
        var temperature: Double? = nil
        if case .sensor(let key, _, _) = mode {
            guard let value = manager.controlTemperature(for: key), value.isFinite else { return nil }
            temperature = value
        }
        return .some(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: temperature, policy: policy))
    }

    private func targetText(for fan: FanDevice) -> String {
        switch target(for: fan) {
        case .none: return "--"
        case .some(.none): return String(localized: "Auto")
        case .some(.some(let rpm)): return rpm.formatted()
        }
    }

    private func accessibilityValue(for fan: FanDevice) -> String {
        switch target(for: fan) {
        case .some(.some(let rpm)): return "\(rpm.formatted()) RPM"
        default: return targetText(for: fan)
        }
    }
}

// MARK: - Presence (pause fallback)

/// How many Fan Control widgets are on screen (one per screen whose Nook is open), and whether
/// the host reports Nook visibility itself. `hostReportsVisibility` is meant to be set by the
/// host hook (`FanControlNookVisibility.nookVisibilityChanged`, FanControlSettingsView.swift —
/// one line: `FanControlWidgetPresence.hostReportsVisibility = true`); until then the widget's
/// fallback pause only fires when the last visible widget disappears.
/// Shared by the Fan Control and Temperature widgets (both need live readings).
@MainActor
enum FanControlWidgetPresence {
    static var visibleCount = 0
    static var hostReportsVisibility = false

    /// A Fan Control / Temperature widget appeared: count it and (when the feature is on) make
    /// sure monitoring runs and is not paused. With "Start Monitoring at Launch" off, monitoring
    /// starts the first time a widget is shown (design doc §5.5 (b)).
    static func widgetAppeared(isPreview: Bool) {
        if !isPreview { visibleCount += 1 }
        guard SettingsStore[.fanControlGeneralSettings].isEnabled else { return }
        let manager = FanControlManager.shared
        if !manager.isMonitoring {
            manager.startMonitoring()
        }
        manager.setMonitoringPaused(false)
    }

    /// Fallback only (PATCHES.md (b-2)): pausing is driven by the host's
    /// FanControlNookVisibility hook, which sees every screen's Nook. A widget's own disappear
    /// runs after that hook (the Nook content fades out), so it must never re-pause while a
    /// Fan Control / Temperature widget is still shown on another screen, and it stays out of
    /// the way once a host has reported Nook visibility.
    static func widgetDisappeared(isPreview: Bool) {
        guard !isPreview else { return }
        visibleCount = max(visibleCount - 1, 0)
        if SettingsStore[.fanControlGeneralSettings].pauseWhenNookHidden,
           !hostReportsVisibility,
           visibleCount == 0 {
            FanControlManager.shared.setMonitoringPaused(true)
        }
    }
}

// MARK: - Fan row

private struct FanRow: View {
    let fan: FanDevice
    let currentRPM: Int?
    let targetRPM: Int?
    let isAnomalous: Bool
    let isCompact: Bool

    private var fraction: Double {
        guard let currentRPM, fan.rpmRange.upperBound > 0 else { return 0 }
        return min(max(Double(currentRPM) / Double(fan.rpmRange.upperBound), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if isAnomalous {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .help(Text("Fan stopped"))
                }
                Text(verbatim: fan.name)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: rpmText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(isAnomalous ? Color.red : Color.primary)

            RPMBar(fraction: fraction, tint: isAnomalous ? .red : .accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: fan.name))
        .accessibilityValue(Text(verbatim: rpmText + (isCompact ? " RPM" : "")))
    }

    /// "2,500" (compact) / "2,500 RPM", optionally "→ 3,000" for the target.
    private var rpmText: String {
        var text = FanControlFormatting.rpm(currentRPM)
        if !isCompact { text += " RPM" }
        if let targetRPM { text += " → \(FanControlFormatting.rpm(targetRPM))" }
        return text
    }
}

/// Thin current/max RPM bar.
private struct RPMBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

// MARK: - Key temperatures

/// Rows of "label · temperature" (CPU / GPU / SSD, or the user's sensors).
/// CPU/GPU values at or above the high-temperature alert are red, within 10 °C below it orange.
struct FanControlKeyTemperaturesView: View {
    enum Style { case compact, regular }

    let sensors: [SensorReading]
    let unit: TemperatureUnit
    let policy: SafetyPolicy
    var style: Style = .regular

    var body: some View {
        switch style {
        case .compact:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sensors) { sensor in
                    HStack(spacing: 4) {
                        Text(verbatim: FanControlFormatting.keyTemperatureLabel(sensor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        value(sensor)
                    }
                    .font(.caption2)
                }
            }
        case .regular:
            HStack(spacing: 24) {
                ForEach(sensors) { sensor in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: FanControlFormatting.keyTemperatureLabel(sensor))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        value(sensor)
                            .font(.title2.weight(.semibold))
                    }
                    .help(Text(verbatim: "\(FanControlFormatting.sensorName(sensor)) (\(sensor.id))"))
                }
                if sensors.isEmpty {
                    Text("No sensors found")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func value(_ sensor: SensorReading) -> some View {
        Text(verbatim: FanControlFormatting.temperature(sensor, unit: unit))
            .monospacedDigit()
            .foregroundStyle(FanControlFormatting.temperatureColor(sensor, policy: policy))
    }
}

extension FanControlFormatting {
    /// Red at/above the high-temperature alert, orange within `warmTemperatureMargin`
    /// below it (CPU/GPU sensors only), else primary.
    static func temperatureColor(_ sensor: SensorReading, policy: SafetyPolicy) -> Color {
        if isAlertTemperature(sensor, policy: policy) { return .red }
        if isWarmTemperature(sensor, policy: policy) { return .orange }
        return .primary
    }
}

// MARK: - Fan curve

/// The fan curve of `profile`: x = temperature 30…100 °C (wider when a curve point lies
/// outside), y = RPM from the lowest fan minimum to the highest fan maximum. One line per fan,
/// straight from the engine: a `.sensor` mode draws its `FanProfile.curve(for:)` (the stored
/// multi-point PCHIP curve, or the two-point linear ramp) sampled with
/// `FanCurve.sample(count: 48, rpmRange:temperatureDomain:)`, a constant mode a horizontal
/// line (`FanControlEngine.targetRPM(for: profile, …)`), automatic no line. Curve points are
/// marked (regular style). The dot is the live operating point: the fan's measured RPM at the
/// smoothed control temperature of the sensor its mode follows
/// (`FanControlManager.controlTemperature(for:)`; CPU (max) for constant / automatic modes).
/// A dashed red line marks the emergency temperature. Before the emergency override.
struct FanCurveView: View {
    enum Style { case compact, regular }

    /// Default temperature axis (°C).
    static let temperatureDomain: ClosedRange<Double> = 30...100
    /// Samples per curve (plus the curve's own points).
    static let sampleCount = 48

    let profile: FanProfile
    let fans: [FanDevice]
    let sensors: [SensorReading]
    let currentRPMs: [Int: Int]
    let unit: TemperatureUnit
    var emergencyTemperature: Double? = nil
    var style: Style = .regular

    /// Per-fan colours (fan order).
    static let palette: [Color] = [.accentColor, .orange, .green, .pink]

    static func color(forFanAt index: Int) -> Color { palette[index % palette.count] }

    private var manager: FanControlManager { FanControlManager.shared }

    private var rpmDomain: ClosedRange<Double> {
        let low = Double(fans.map(\.rpmRange.lowerBound).min() ?? 0)
        let high = Double(fans.map(\.rpmRange.upperBound).max() ?? 1)
        return high > low ? low...high : (low - 1)...(low + 1)
    }

    /// 30…100 °C, widened to every drawn curve point.
    private var domain: ClosedRange<Double> {
        let temperatures = fans.compactMap { profile.curve(for: $0) }.flatMap { $0.normalized().points.map(\.temperature) }
        let low = min(Self.temperatureDomain.lowerBound, temperatures.min() ?? .infinity)
        let high = max(Self.temperatureDomain.upperBound, temperatures.max() ?? -.infinity)
        return low...high
    }

    private var isAllAutomatic: Bool {
        fans.allSatisfy { !profile.mode(for: $0).isManual }
    }

    /// What is drawn for one fan (computed on the main actor, drawn by the Canvas).
    private struct FanTrace {
        var color: Color
        var line: [(temperature: Double, rpm: Double)]
        var points: [(temperature: Double, rpm: Double)]
        var operatingPoint: (temperature: Double, rpm: Double)?
    }

    private var traces: [FanTrace] {
        let domain = domain
        return fans.enumerated().map { index, fan in
            let mode = profile.mode(for: fan)
            var trace = FanTrace(color: Self.color(forFanAt: index), line: [], points: [], operatingPoint: nil)
            if let curve = profile.curve(for: fan) {
                trace.line = curve.sample(count: Self.sampleCount, rpmRange: fan.rpmRange, temperatureDomain: domain)
                    .map { ($0.temperature, $0.rpm) }
                trace.points = curve.resolved(for: fan).points.map { ($0.temperature, Double($0.rpm)) }
            } else if mode.isManual {
                trace.line = Self.samples(for: mode, domain: domain).map { temperature in
                    (temperature, Double(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: temperature,
                                                                    policy: manager.safetyPolicy) ?? 0))
                }
            }
            if let rpm = currentRPMs[fan.id], let temperature = operatingTemperature(for: mode) {
                trace.operatingPoint = (temperature, Double(rpm))
            }
            return trace
        }
    }

    var body: some View {
        let traces = traces
        let domain = domain
        let rpmDomain = rpmDomain
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                draw(traces, domain: domain, rpmDomain: rpmDomain, in: &context, size: size)
            }
            .overlay {
                if isAllAutomatic {
                    Text("Controlled by macOS")
                        .font(style == .compact ? .caption2 : .callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.background.opacity(0.6), in: Capsule())
                }
            }
            HStack(spacing: 0) {
                Text(verbatim: FanControlFormatting.temperature(domain.lowerBound, unit: unit))
                Spacer(minLength: 2)
                if style == .regular {
                    Text("Temperature")
                    Spacer(minLength: 2)
                }
                Text(verbatim: FanControlFormatting.temperature(domain.upperBound, unit: unit))
            }
            .font(style == .compact ? .system(size: 8) : .caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fan Curve"))
    }

    private func point(temperature: Double, rpm: Double, domain t: ClosedRange<Double>,
                       rpmDomain r: ClosedRange<Double>, size: CGSize) -> CGPoint {
        let x = (min(max(temperature, t.lowerBound), t.upperBound) - t.lowerBound) / (t.upperBound - t.lowerBound)
        let y = (min(max(rpm, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
        let inset: CGFloat = 3
        return CGPoint(x: inset + x * (size.width - 2 * inset),
                       y: size.height - inset - y * (size.height - 2 * inset))
    }

    private func draw(_ traces: [FanTrace], domain: ClosedRange<Double>, rpmDomain: ClosedRange<Double>,
                      in context: inout GraphicsContext, size: CGSize) {
        func p(_ temperature: Double, _ rpm: Double) -> CGPoint {
            point(temperature: temperature, rpm: rpm, domain: domain, rpmDomain: rpmDomain, size: size)
        }
        // Frame + grid (every 10 °C).
        let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
        context.stroke(frame, with: .color(.primary.opacity(0.15)), lineWidth: 1)
        var t = (domain.lowerBound / 10).rounded(.up) * 10
        while t < domain.upperBound {
            if t > domain.lowerBound {
                var grid = Path()
                grid.move(to: CGPoint(x: p(t, rpmDomain.lowerBound).x, y: 0))
                grid.addLine(to: CGPoint(x: p(t, rpmDomain.lowerBound).x, y: size.height))
                context.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 0.5)
            }
            t += 10
        }
        if style == .regular {
            context.draw(Text(verbatim: "\(Int(rpmDomain.upperBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: 6), anchor: .topLeading)
            context.draw(Text(verbatim: "\(Int(rpmDomain.lowerBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: size.height - 6), anchor: .bottomLeading)
        }
        if let emergencyTemperature, domain.contains(emergencyTemperature) {
            var line = Path()
            line.move(to: p(emergencyTemperature, rpmDomain.upperBound))
            line.addLine(to: p(emergencyTemperature, rpmDomain.lowerBound))
            context.stroke(line, with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }

        let lineWidth: CGFloat = style == .compact ? 1.5 : 2
        for (index, trace) in traces.enumerated() {
            // Offset overlapping curves of later fans by a hair so both stay visible.
            let dy = CGFloat(index) * 1.0
            if !trace.line.isEmpty {
                var curve = Path()
                for (n, sample) in trace.line.enumerated() {
                    let q = p(sample.temperature, sample.rpm)
                    if n == 0 { curve.move(to: q) } else { curve.addLine(to: q) }
                }
                context.stroke(curve.offsetBy(dx: 0, dy: dy), with: .color(trace.color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            if style == .regular {
                for point in trace.points where domain.contains(point.temperature) {
                    let q = p(point.temperature, point.rpm)
                    let r: CGFloat = 2.5
                    let marker = Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r + dy, width: 2 * r, height: 2 * r))
                    context.fill(marker, with: .style(.background))
                    context.stroke(marker, with: .color(trace.color), lineWidth: 1.25)
                }
            }
            if let operating = trace.operatingPoint {
                let q = p(operating.temperature, operating.rpm)
                let radius: CGFloat = style == .compact ? 2.5 : 4
                let dot = Path(ellipseIn: CGRect(x: q.x - radius, y: q.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(dot, with: .color(trace.color))
                context.stroke(dot, with: .color(.primary.opacity(0.8)), lineWidth: 0.75)
            }
        }
    }

    /// Temperatures at which a mode without a curve (constant, degenerate sensor ramp) changes
    /// value, plus the ends of `domain`.
    static func samples(for mode: FanControlMode, domain: ClosedRange<Double> = temperatureDomain) -> [Double] {
        var points = [domain.lowerBound, domain.upperBound]
        if case .sensor(_, let start, let maxTemperature) = mode {
            let epsilon = 0.001
            points += [start, maxTemperature, start - epsilon, maxTemperature - epsilon]
        }
        return Array(Set(points.filter { domain.contains($0) })).sorted()
    }

    /// The temperature the operating point is drawn at: the smoothed control temperature of the
    /// followed sensor, else CPU (max) (or the hottest key temperature).
    private func operatingTemperature(for mode: FanControlMode) -> Double? {
        if case .sensor(let key, _, _) = mode, let value = manager.controlTemperature(for: key), value.isFinite {
            return value
        }
        if let cpu = manager.controlTemperature(for: SensorAggregator.ID.cpu), cpu.isFinite { return cpu }
        return FanControlFormatting.keyTemperatures(sensors).first?.temperature
    }
}

// MARK: - Empty state

private struct FanControlEmptyState: View {
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
            Text(message)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
#endif
