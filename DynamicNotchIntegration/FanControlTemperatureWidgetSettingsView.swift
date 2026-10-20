#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package): host-specific
// glue on top of FanControlUI.
//
// Per-widget options shown in Settings ▸ Widgets when "Temperature" is selected (wired in
// `WidgetsSettingsTabView`, PATCHES.md (c)). Added 2026-10-20 with the Temperature widget.

import SwiftUI
import FanControlCore
import FanControlKit
import FanControlUI

struct FanControlTemperatureWidgetSettingsView: View {

    @FanControlSetting(.temperatureWidget) private var settings
    /// The temperature unit is shared with the Fan Control widget.
    @FanControlSetting(.widget) private var fanWidgetSettings

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        Form {
            Section {
                Picker("Time Window", selection: $settings.historyWindow) {
                    ForEach(FanControlTemperatureWidgetSettings.HistoryWindow.allCases) { choice in
                        Text("\(choice.rawValue) min").tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } header: {
                Text("History")
            } footer: {
                Text("The history is kept while DynamicNotch runs (about 30 minutes) and is not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sensors") {
                ForEach(FanControlTemperatureWidgetSettings.seriesKeys, id: \.self) { key in
                    Toggle(isOn: isVisible(key)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(FanControlTemperatureSeries.color(for: key))
                                .frame(width: 8, height: 8)
                            Text(verbatim: label(for: key))
                            Spacer()
                            if let reading = manager.sensorReadings.first(where: { $0.id == key }) {
                                Text(verbatim: FanControlFormatting.temperature(reading, unit: fanWidgetSettings.temperatureUnit))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isOnlyVisible(key))
                }
            }

            Section {
                Picker("Temperature Unit", selection: $fanWidgetSettings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Show Highest and Lowest", isOn: $settings.showsMinMax)
                Toggle("Show Alert Threshold", isOn: $settings.showsAlertThreshold)
            } header: {
                Text("Display")
            } footer: {
                Text("The dashed line is the high-temperature alert threshold (\(FanControlFormatting.temperature(manager.safetyPolicy.highTemperatureAlert, unit: fanWidgetSettings.temperatureUnit))), set in Settings ▸ Fan Control ▸ General. CPU and GPU values turn orange within 10° below it and red at or above it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(for key: String) -> String {
        switch key {
        case SensorAggregator.ID.cpu: return NSLocalizedString("CPU (max)", comment: "Aggregate sensor name")
        case SensorAggregator.ID.gpu: return NSLocalizedString("GPU (max)", comment: "Aggregate sensor name")
        case "TH0x": return String(localized: "SSD")
        default: return key
        }
    }

    /// The last shown series cannot be turned off (an empty widget would be pointless).
    private func isOnlyVisible(_ key: String) -> Bool {
        settings.shownKeys == [key]
    }

    private func isVisible(_ key: String) -> Binding<Bool> {
        Binding(
            get: { settings.shownKeys.contains(key) },
            set: { visible in
                var keys = settings.shownKeys
                keys.removeAll { $0 == key }
                if visible { keys.append(key) }
                settings.visibleKeys = FanControlTemperatureWidgetSettings.seriesKeys.filter { keys.contains($0) }
            }
        )
    }
}
#endif
