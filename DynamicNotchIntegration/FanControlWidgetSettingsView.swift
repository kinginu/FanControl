#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Per-widget options shown in Settings ▸ Widgets when "Fan Control" is selected
// (wired in `WidgetsSettingsTabView`, see PATCHES.md (c)). Design doc §4.3.

import SwiftUI
import Defaults
import Settings
import FanControlCore
import FanControlKit

struct FanControlWidgetSettingsView: View {

    @Default(.fanControlWidgetSettings) private var settings

    /// `@Observable`, so SwiftUI tracks the properties read in `body`.
    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        Settings.Container(contentWidth: 480.0) {
            Settings.Section(label: { Text("Layout") }) {
                HStack {
                    Text("Grid Size")
                    Spacer()
                    Picker("", selection: $settings.gridSize) {
                        Text("2x1").tag(FanControlWidgetSettings.GridSizeChoice.medium)
                        Text("Double Wide").tag(FanControlWidgetSettings.GridSizeChoice.doubleWide)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
                .padding(.vertical, 4)
            }

            Settings.Section(label: { Text("Fans") }) {
                FanSelectionList(settings: $settings, fans: manager.fans)
            }

            Settings.Section(label: { Text("Sensors") }) {
                SensorSelectionList(settings: $settings, sensors: manager.sensorReadings)
            }

            Settings.Section(label: { Text("Display") }) {
                HStack {
                    Text("Temperature Unit")
                    Spacer()
                    Picker("", selection: $settings.temperatureUnit) {
                        Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                        Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.vertical, 4)

                HStack {
                    Text("Show Profile Picker")
                    Spacer()
                    Toggle("", isOn: $settings.showProfilePicker)
                        .labelsHidden()
                }
                .padding(.vertical, 4)

                HStack {
                    Text("Show Target RPM")
                    Spacer()
                    Toggle("", isOn: $settings.showTargetRPM)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(0)
    }
}

// MARK: - Fan multi-select

private struct FanSelectionList: View {
    @Binding var settings: FanControlWidgetSettings
    let fans: [FanDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Show All Fans")
                Spacer()
                Toggle("", isOn: showAll)
                    .labelsHidden()
            }
            .padding(.vertical, 4)

            if fans.isEmpty {
                Text("No fans detected")
                    .foregroundStyle(.secondary)
            } else if settings.visibleFanIDs != nil {
                ForEach(fans) { fan in
                    HStack {
                        Text(fan.name)
                        Spacer()
                        Toggle("", isOn: isVisible(fan))
                            .labelsHidden()
                    }
                }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Show 3 Hottest Sensors")
                Spacer()
                Toggle("", isOn: automatic)
                    .labelsHidden()
            }
            .padding(.vertical, 4)

            if sensors.isEmpty {
                Text("No sensors found")
                    .foregroundStyle(.secondary)
            } else if settings.visibleSensorKeys != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sensors) { sensor in
                            HStack {
                                Text(sensor.name)
                                    .lineLimit(1)
                                Text(verbatim: sensor.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(verbatim: FanControlFormatting.temperature(sensor, unit: settings.temperatureUnit))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Toggle("", isOn: isVisible(sensor))
                                    .labelsHidden()
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    /// On = `visibleSensorKeys == nil` (3 hottest). Turning it off starts from
    /// the currently hottest three so the widget does not suddenly go empty.
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
