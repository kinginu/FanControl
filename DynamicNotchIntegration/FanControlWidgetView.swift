#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The Fan Control Nook widget (design doc §4.1). Dispatched from the Nook grid
// for `NookWidget.fanControl` (PATCHES.md (b)).
//
// Layouts (DynamicNotch width = gridSizeType × 50 pt):
//   - medium (2x1, 100 pt): fans stacked, then sensors, compact profile menu.
//   - doubleWide (250 pt): fans on the left, sensors + profile menu on the right.

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlWidgetView: View {

    @Default(.fanControlWidgetSettings) private var settings
    @Default(.fanControlGeneralSettings) private var general

    private var manager: FanControlManager { FanControlManager.shared }

    private var isCompact: Bool { settings.gridSize == .medium }

    var body: some View {
        content
            .frame(width: settings.gridSize.widthInPoints)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                guard general.isEnabled else { return }
                // With "Start Monitoring at Launch" off, monitoring starts the
                // first time the widget is shown (design doc §5.5 (b)).
                if !manager.isMonitoring {
                    manager.startMonitoring()
                }
                manager.setMonitoringPaused(false)
            }
            .onDisappear {
                if general.pauseWhenNookHidden { manager.setMonitoringPaused(true) }
            }
    }

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
                sensorList
                if settings.showProfilePicker { profileMenu }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    fanList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    sensorList
                    Spacer(minLength: 0)
                    if settings.showProfilePicker { profileMenu }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "fan")
            Text("Fans")
            Spacer(minLength: 0)
            if manager.highTempAlertActive {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(.red)
                    .help(Text("High temperature"))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(manager.highTempAlertActive ? Color.red : Color.secondary)
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

    // MARK: Sensors

    private var sensorList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isCompact {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                    Text("Temperatures")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            ForEach(settings.visibleSensors(from: manager.sensorReadings).prefix(isCompact ? 2 : 4)) { sensor in
                HStack(spacing: 4) {
                    Text(verbatim: sensor.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(verbatim: FanControlFormatting.temperature(sensor, unit: settings.temperatureUnit))
                        .monospacedDigit()
                        .foregroundStyle(FanControlFormatting.isAlertTemperature(sensor, policy: manager.safetyPolicy) ? Color.red : Color.primary)
                }
                .font(.caption2)
            }
        }
    }

    // MARK: Profile menu

    private var profileMenu: some View {
        Menu {
            ForEach(manager.availableProfiles) { profile in
                Button {
                    Task { try? await manager.applyProfile(profile) }
                } label: {
                    if profile.id == manager.activeProfile?.id {
                        Label(FanControlFormatting.profileName(profile), systemImage: "checkmark")
                    } else {
                        Text(verbatim: FanControlFormatting.profileName(profile))
                    }
                }
            }
        } label: {
            if let active = manager.activeProfile {
                Text(verbatim: FanControlFormatting.profileName(active))
            } else {
                Text("Profile")
            }
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .fixedSize()
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
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

// MARK: - Empty state

private struct FanControlEmptyState: View {
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(message)
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
