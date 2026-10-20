#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package): host-specific
// glue on top of FanControlUI (`import FanControlUI`).
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
// `FanCurveView`, `FanControlSelectionPill`, `FanControlProfiles` and `FanControlFormatting` come
// from FanControlUI (shared with the settings pane); the appear / disappear fallback for "Pause
// When Nook Is Hidden" is `FanControlWidgetPresence` (FanControlNookHooks.swift).

import SwiftUI
import FanControlCore
import FanControlKit
import FanControlUI

struct FanControlWidgetView: View {

    @FanControlSetting(.widget) private var settings
    @FanControlSetting(.general) private var general

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
            FanControlAutomationIndicator()   // F3: "Auto: Boost (Xcode)" (FanControlUI)
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
