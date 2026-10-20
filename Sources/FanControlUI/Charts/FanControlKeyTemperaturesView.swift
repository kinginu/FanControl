#if os(macOS)
import SwiftUI
import FanControlCore
import FanControlKit

// MARK: - Key temperatures

/// Rows of "label · temperature" (CPU / GPU / SSD, or the user's sensors).
/// CPU/GPU values at or above the high-temperature alert are red, within 10 °C below it orange.
public struct FanControlKeyTemperaturesView: View {
    public enum Style: Sendable { case compact, regular }

    let sensors: [SensorReading]
    let unit: TemperatureUnit
    let policy: SafetyPolicy
    var style: Style = .regular

    public init(sensors: [SensorReading], unit: TemperatureUnit, policy: SafetyPolicy, style: Style = .regular) {
        self.sensors = sensors
        self.unit = unit
        self.policy = policy
        self.style = style
    }

    public var body: some View {
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
#endif
