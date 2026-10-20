#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// "Sensors" tab of the Fan Control settings pane: the key temperatures
// (CPU (max), GPU (max), SSD `TH0x`) at the top, then every discovered sensor
// with its SMC key, name and temperature (replaces the earlier sensor table,
// design doc §4.4). Sensor names are community-sourced (`SensorCatalog`) and
// localized by `FanControlSensorNames` (label from Localizable.strings + the
// verbatim suffix, design doc §5.7); the raw SMC key stays in its own column.
// Aggregate sensors ("CPU (max)", …; `SensorAggregator`) are listed first,
// whatever the sort order, with a "sum" icon in the key column. Keys excluded
// from ranking (`SensorCatalog.isExcludedFromRanking`, e.g. `Tf*`: constant /
// probably not a temperature) stay listed, with a marker and tooltip, and go
// after the real sensors when sorting by temperature.

import SwiftUI
import FanControlCore
import FanControlKit

struct FanControlSensorsTabView: View {

    @StoredSetting(.fanControlWidgetSettings) private var widgetSettings

    @State private var sortOrder = [KeyPathComparator(\SensorReading.temperature, order: .reverse)]

    private var manager: FanControlManager { FanControlManager.shared }

    private var rows: [SensorReading] {
        let sorted = manager.sensorReadings.sorted(using: sortOrder)
        let sortedByTemperature = sortOrder.first?.keyPath == \SensorReading.temperature
        return FanControlFormatting.aggregatesFirst(
            sortedByTemperature ? FanControlFormatting.rankableFirst(sorted) : sorted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                FanControlKeyTemperaturesView(sensors: FanControlFormatting.keyTemperatures(manager.sensorReadings),
                                              unit: widgetSettings.temperatureUnit,
                                              policy: manager.safetyPolicy,
                                              style: .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } label: {
                Text("Key Temperatures")
            }

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Key", value: \.id) { sensor in
                    HStack(spacing: 4) {
                        if sensor.isAggregate {
                            Image(systemName: "sum")
                                .foregroundStyle(.secondary)
                                .help(Text("Aggregate"))
                        } else if sensor.isExcludedFromRanking {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.tertiary)
                                .help(Text("Constant or unreliable value, probably not a temperature. Not used for the hottest sensors."))
                        }
                        Text(verbatim: sensor.id)
                            .font(.body.monospaced())
                    }
                }
                .width(min: 50, ideal: 70, max: 110)

                TableColumn("Name", value: \.name) { sensor in
                    Text(verbatim: FanControlSensorNames.localized(sensor))
                }

                TableColumn("Temperature", value: \.temperature) { sensor in
                    Text(verbatim: FanControlFormatting.temperature(sensor, unit: widgetSettings.temperatureUnit))
                        .monospacedDigit()
                        .foregroundStyle(isHot(sensor) ? Color.red
                                         : sensor.isExcludedFromRanking ? Color.secondary : Color.primary)
                }
                .width(min: 80, ideal: 90, max: 110)
            }
            .overlay {
                if manager.sensorReadings.isEmpty {
                    Group {
                        if manager.isSMCConnected {
                            Text("No sensors found")
                        } else {
                            Text("SMC unavailable")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let lastUpdate = manager.lastUpdate {
                    Text("Last updated \(lastUpdate, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    manager.refreshNow()
                }
            }
        }
        .padding()
    }

    private func isHot(_ sensor: SensorReading) -> Bool {
        FanControlFormatting.isAlertTemperature(sensor, policy: manager.safetyPolicy)
    }
}

// MARK: - Localized sensor names

/// Localized sensor names (design doc §5.7), built from
/// `SensorCatalog.nameComponents(for:)`: the label key ("CPU Performance Core",
/// "Battery", …, "Sensor" for unknown keys, or an aggregate name such as
/// "CPU (max)") goes through Localizable.strings, the suffix (rest of the SMC
/// key, sensor index or raw key) is appended verbatim, e.g. `Tp09` →
/// "CPU 高性能コア 09". `SensorReading.name` / `SensorCatalog.displayName(for:)`
/// stay English (stored, legacy key).
///
/// Supersedes `FanControlFormatting.sensorName(_:)`, which localizes aggregate
/// names only; the widget files still call that one.
enum FanControlSensorNames {
    static func localized(_ sensor: SensorReading) -> String {
        localized(key: sensor.id)
    }

    static func localized(key: String) -> String {
        let components = SensorCatalog.nameComponents(for: key)
        return components.name(label: NSLocalizedString(components.labelKey, comment: "Sensor name label (SensorCatalog)"))
    }
}
#endif
