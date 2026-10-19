#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// "Sensors" tab of the Fan Control settings pane: every discovered sensor
// with its SMC key, name and temperature (replaces the earlier sensor table,
// design doc §4.4). Sensor names are community-sourced (`SensorCatalog`).

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlSensorsTabView: View {

    @Default(.fanControlWidgetSettings) private var widgetSettings

    @State private var sortOrder = [KeyPathComparator(\SensorReading.temperature, order: .reverse)]

    private var manager: FanControlManager { FanControlManager.shared }

    private var rows: [SensorReading] {
        manager.sensorReadings.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Key", value: \.id) { sensor in
                    Text(verbatim: sensor.id)
                        .font(.body.monospaced())
                }
                .width(min: 50, ideal: 60, max: 80)

                TableColumn("Name", value: \.name) { sensor in
                    Text(verbatim: sensor.name)
                }

                TableColumn("Temperature", value: \.temperature) { sensor in
                    Text(verbatim: FanControlFormatting.temperature(sensor, unit: widgetSettings.temperatureUnit))
                        .monospacedDigit()
                        .foregroundStyle(isHot(sensor) ? Color.red : Color.primary)
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
#endif
