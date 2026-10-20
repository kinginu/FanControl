#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The Fan Control Nook widget (design doc §4.1). Dispatched from the Nook grid
// for `NookWidget.fanControl` (PATCHES.md (b)).
//
// Layouts (DynamicNotch width = gridSizeType × 50 pt):
//   - medium (2x1, 100 pt): fans stacked, key temperatures (CPU / GPU), profile selector.
//   - doubleWide (250 pt): fans + key temperatures (CPU / GPU / SSD) on the left,
//     the active profile's fan curve + profile selector on the right.
// The selector lists the six fixed profiles (`ProfileStore`) and applies the
// chosen one; editing happens only in Settings ▸ Fan Control ▸ Profiles.
// `FanCurveView` and `FanControlKeyTemperaturesView` are also used by the settings pane.

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlWidgetView: View {

    @Default(.fanControlWidgetSettings) private var settings
    @Default(.fanControlGeneralSettings) private var general

    /// Preview / debug rendering only (e.g. the app's DEBUG `preview:` hook):
    /// show this profile's curve and name instead of the active profile's.
    /// `nil` (the Nook grid) = the active profile. Nothing is applied.
    var previewProfile: FanProfile? = nil
    /// Preview / debug rendering only: layout size instead of the setting.
    var previewGridSize: FanControlWidgetSettings.GridSizeChoice? = nil

    private var manager: FanControlManager { FanControlManager.shared }

    private var gridSize: FanControlWidgetSettings.GridSizeChoice { previewGridSize ?? settings.gridSize }
    private var isCompact: Bool { gridSize == .medium }
    /// The profile drawn by the curve and named by the selector.
    private var displayedProfile: FanProfile { previewProfile ?? FanControlProfiles.active }

    var body: some View {
        content
            .frame(width: gridSize.widthInPoints)
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
                    sensorList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    if settings.showFanCurve {
                        FanCurveView(profile: displayedProfile,
                                     fans: settings.visibleFans(from: manager.fans),
                                     sensors: manager.sensorReadings,
                                     currentRPMs: manager.currentRPMs,
                                     unit: settings.temperatureUnit,
                                     emergencyTemperature: manager.safetyPolicy.emergencyTemperature,
                                     style: .compact)
                            .frame(height: 64)
                    }
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

    /// Key temperatures (CPU / GPU, + SSD when double-wide) unless the user
    /// picked sensors in the widget settings.
    private var sensorList: some View {
        FanControlKeyTemperaturesView(
            sensors: Array(settings.visibleSensors(from: manager.sensorReadings).prefix(isCompact ? 2 : 3)),
            unit: settings.temperatureUnit,
            policy: manager.safetyPolicy,
            style: .compact)
    }

    // MARK: Profile menu

    /// Selector among the six fixed profiles; the active one is checked and
    /// shown as the label. Choosing one applies it (no editing here).
    private var profileMenu: some View {
        let activeID = previewProfile?.id ?? FanControlProfiles.activeID
        let profiles = FanControlProfiles.all
        return Menu {
            ForEach(profiles) { profile in
                if profile.id == FanProfile.BuiltInID.custom1 { Divider() }
                Button {
                    Task { try? await FanControlProfiles.apply(profile) }
                } label: {
                    if profile.id == activeID {
                        Label(FanControlFormatting.profileName(profile), systemImage: "checkmark")
                    } else {
                        Text(verbatim: FanControlFormatting.profileName(profile))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if !isCompact {
                    Image(systemName: activeID == FanProfile.BuiltInID.automatic ? "fan" : "fan.fill")
                }
                Text(verbatim: FanControlFormatting.profileName(displayedProfile))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .menuStyle(.borderlessButton)
        .font(isCompact ? .caption2 : .caption)
        .fixedSize(horizontal: !isCompact, vertical: true)
        .frame(maxWidth: isCompact ? gridSize.widthInPoints : nil, alignment: .leading)
        .help(Text("Profile"))
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

// MARK: - Key temperatures

/// Rows of "label · temperature" (CPU / GPU / SSD, or the user's sensors).
/// Values at or above the high-temperature alert (CPU/GPU) are red.
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
            .foregroundStyle(FanControlFormatting.isAlertTemperature(sensor, policy: policy) ? Color.red : Color.primary)
    }
}

// MARK: - Fan curve

/// The fan curve of `profile`: x = temperature 30…100 °C, y = RPM from the
/// lowest fan minimum to the highest fan maximum. One line per fan (constant
/// = horizontal line, sensor-linked = flat at Mn up to the start temperature,
/// linear ramp, flat at Mx from the maximum temperature; automatic = no line).
/// The dot is the live operating point: the fan's measured RPM at the
/// temperature of the sensor its mode follows (CPU (max) for constant /
/// automatic modes). A dashed red line marks the emergency temperature.
/// Curves come from `FanControlEngine.targetRPM`, i.e. exactly what is applied
/// (before the emergency override).
struct FanCurveView: View {
    enum Style { case compact, regular }

    /// Temperature axis (°C).
    static let temperatureDomain: ClosedRange<Double> = 30...100

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

    private var rpmDomain: ClosedRange<Double> {
        let low = Double(fans.map(\.rpmRange.lowerBound).min() ?? 0)
        let high = Double(fans.map(\.rpmRange.upperBound).max() ?? 1)
        return high > low ? low...high : (low - 1)...(low + 1)
    }

    private var isAllAutomatic: Bool {
        fans.allSatisfy { !profile.mode(for: $0).isManual }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                draw(in: &context, size: size)
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
                Text(verbatim: FanControlFormatting.temperature(Self.temperatureDomain.lowerBound, unit: unit))
                Spacer(minLength: 2)
                if style == .regular {
                    Text("Temperature")
                    Spacer(minLength: 2)
                }
                Text(verbatim: FanControlFormatting.temperature(Self.temperatureDomain.upperBound, unit: unit))
            }
            .font(style == .compact ? .system(size: 8) : .caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fan Curve"))
    }

    private func point(temperature: Double, rpm: Double, size: CGSize) -> CGPoint {
        let t = Self.temperatureDomain
        let r = rpmDomain
        let x = (min(max(temperature, t.lowerBound), t.upperBound) - t.lowerBound) / (t.upperBound - t.lowerBound)
        let y = (min(max(rpm, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
        let inset: CGFloat = 3
        return CGPoint(x: inset + x * (size.width - 2 * inset),
                       y: size.height - inset - y * (size.height - 2 * inset))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Frame + grid (quarter lines).
        let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
        context.stroke(frame, with: .color(.primary.opacity(0.15)), lineWidth: 1)
        for fraction in [0.25, 0.5, 0.75] {
            var grid = Path()
            grid.move(to: CGPoint(x: size.width * fraction, y: 0))
            grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            context.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 0.5)
        }
        if style == .regular {
            let r = rpmDomain
            context.draw(Text(verbatim: "\(Int(r.upperBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: 6), anchor: .topLeading)
            context.draw(Text(verbatim: "\(Int(r.lowerBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: size.height - 6), anchor: .bottomLeading)
        }
        if let emergencyTemperature, Self.temperatureDomain.contains(emergencyTemperature) {
            var line = Path()
            line.move(to: point(temperature: emergencyTemperature, rpm: rpmDomain.upperBound, size: size))
            line.addLine(to: point(temperature: emergencyTemperature, rpm: rpmDomain.lowerBound, size: size))
            context.stroke(line, with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }

        let lineWidth: CGFloat = style == .compact ? 1.5 : 2
        for (index, fan) in fans.enumerated() {
            let mode = profile.mode(for: fan)
            let color = Self.color(forFanAt: index)
            if mode.isManual {
                var curve = Path()
                for (n, temperature) in Self.samples(for: mode).enumerated() {
                    let rpm = FanControlEngine.targetRPM(for: mode, fan: fan, sensorTemperature: temperature) ?? 0
                    let p = point(temperature: temperature, rpm: Double(rpm), size: size)
                    if n == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                // Offset overlapping curves of later fans by a hair so both stay visible.
                context.stroke(curve.offsetBy(dx: 0, dy: CGFloat(index) * 1.0), with: .color(color), lineWidth: lineWidth)
            }
            if let rpm = currentRPMs[fan.id], let temperature = operatingTemperature(for: mode) {
                let p = point(temperature: temperature, rpm: Double(rpm), size: size)
                let radius: CGFloat = style == .compact ? 2.5 : 4
                let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(dot, with: .color(color))
                context.stroke(dot, with: .color(.primary.opacity(0.8)), lineWidth: 0.75)
            }
        }
    }

    /// Temperatures at which the (piecewise linear) curve changes slope, plus the ends.
    static func samples(for mode: FanControlMode) -> [Double] {
        let domain = temperatureDomain
        var points = [domain.lowerBound, domain.upperBound]
        if case .sensor(_, let start, let maxTemperature) = mode {
            let epsilon = 0.001
            points += [start, maxTemperature, start - epsilon, maxTemperature - epsilon]
        }
        return Array(Set(points.filter { domain.contains($0) })).sorted()
    }

    /// The temperature the operating point is drawn at: the followed sensor,
    /// else CPU (max) (or the hottest key temperature).
    private func operatingTemperature(for mode: FanControlMode) -> Double? {
        if case .sensor(let key, _, _) = mode,
           let reading = sensors.first(where: { $0.id == key && $0.temperature.isFinite }) {
            return reading.temperature
        }
        return FanControlFormatting.keyTemperatures(sensors).first?.temperature
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
