#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Per-widget options shown in Settings ▸ Widgets when "Fan Control" is selected
// (wired in `WidgetsSettingsTabView`, see PATCHES.md (c)). Design doc §4.3.
// The sensor selection was removed 2026-10-20: temperatures moved to the Temperature widget
// (FanControlTemperatureWidgetSettingsView.swift); `visibleSensorKeys` is kept in storage.

import SwiftUI
import FanControlCore
import FanControlKit

struct FanControlWidgetSettingsView: View {

    @StoredSetting(.fanControlWidgetSettings) private var settings

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

            Section {
                Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle("Show Profile List", isOn: $settings.showProfilePicker)
                Toggle("Show Fan Curve (Double Wide)", isOn: $settings.showFanCurve)
                Toggle("Show Target RPM", isOn: $settings.showTargetRPM)
            } header: {
                Text("Display")
            } footer: {
                // Temperatures moved to their own widget (2026-10-20).
                Text("CPU, GPU and SSD temperatures are shown by the Temperature widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
#endif
