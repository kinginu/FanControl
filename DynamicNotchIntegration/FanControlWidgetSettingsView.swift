#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Per-widget options shown in Settings ▸ Widgets when "Fan Control" is selected
// (wired in `WidgetsSettingsTabView`, see PATCHES.md (c)). Design doc §4.3.

import SwiftUI
import Defaults
import FanControlCore
import FanControlKit

struct FanControlWidgetSettingsView: View {

    @Default(.fanControlWidgetSettings) private var settings

    /// `@Observable`, so SwiftUI tracks the properties read in `body`.
    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        // Grouped form (System Settings style), like the host's other widget settings views.
        Form {
            Section("Layout") {
                Picker("Grid Size", selection: $settings.gridSize) {
                    Text("2x1").tag(FanControlWidgetSettings.GridSizeChoice.medium)
                    Text("Double Wide").tag(FanControlWidgetSettings.GridSizeChoice.doubleWide)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Fans") {
                FanSelectionList(settings: $settings, fans: manager.fans)
            }

            Section("Sensors") {
                SensorSelectionList(settings: $settings,
                                    sensors: FanControlFormatting.aggregatesFirst(manager.sensorReadings))
            }

            Section("Display") {
                Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle("Show Profile List", isOn: $settings.showProfilePicker)
                Toggle("Show Fan Curve (Double Wide)", isOn: $settings.showFanCurve)
                Toggle("Show Target RPM", isOn: $settings.showTargetRPM)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Fan multi-select

private struct FanSelectionList: View {
    @Binding var settings: FanControlWidgetSettings
    let fans: [FanDevice]

    var body: some View {
        Toggle("Show All Fans", isOn: showAll)

        if fans.isEmpty {
            Text("No fans detected")
                .foregroundStyle(.secondary)
        } else if settings.visibleFanIDs != nil {
            ForEach(fans) { fan in
                Toggle(isOn: isVisible(fan)) { Text(verbatim: fan.name) }
            }
        }
    }

    /// On = `visibleFanIDs == nil`. Turning it off starts from "all fans selected".
    private var showAll: Binding<Bool> {
        Binding(
            get: { settings.visibleFanIDs == nil },
            set: { settings.visibleFanIDs = $0 ? nil : fans.map(\.id) }
        )
    }

    private func isVisible(_ fan: FanDevice) -> Binding<Bool> {
        Binding(
            get: { settings.visibleFanIDs?.contains(fan.id) ?? true },
            set: { visible in
                var ids = settings.visibleFanIDs ?? fans.map(\.id)
                ids.removeAll { $0 == fan.id }
                if visible { ids.append(fan.id) }
                // Keep hardware order.
                settings.visibleFanIDs = fans.map(\.id).filter { ids.contains($0) }
            }
        )
    }
}

// MARK: - Sensor multi-select

private struct SensorSelectionList: View {
    @Binding var settings: FanControlWidgetSettings
    let sensors: [SensorReading]

    var body: some View {
        Toggle("Show Key Temperatures", isOn: automatic)

        if sensors.isEmpty {
            Text("No sensors found")
                .foregroundStyle(.secondary)
        } else if settings.visibleSensorKeys != nil {
            ForEach(sensors) { sensor in
                Toggle(isOn: isVisible(sensor)) {
                    HStack {
                        Text(verbatim: FanControlFormatting.sensorName(sensor))
                            .lineLimit(1)
                        Text(verbatim: sensor.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: FanControlFormatting.temperature(sensor, unit: settings.temperatureUnit))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// On = `visibleSensorKeys == nil` (key temperatures: CPU / GPU / SSD).
    /// Turning it off starts from those so the widget does not suddenly go empty.
    private var automatic: Binding<Bool> {
        Binding(
            get: { settings.visibleSensorKeys == nil },
            set: { isAutomatic in
                settings.visibleSensorKeys = isAutomatic
                    ? nil
                    : FanControlWidgetSettings(visibleSensorKeys: nil).visibleSensors(from: sensors).map(\.id)
            }
        )
    }

    private func isVisible(_ sensor: SensorReading) -> Binding<Bool> {
        Binding(
            get: { settings.visibleSensorKeys?.contains(sensor.id) ?? false },
            set: { visible in
                var keys = settings.visibleSensorKeys ?? []
                keys.removeAll { $0 == sensor.id }
                if visible { keys.append(sensor.id) }
                settings.visibleSensorKeys = keys
            }
        )
    }
}
#endif
