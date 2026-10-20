#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// "General" tab of the Fan Control settings pane: feature switch, polling,
// lifecycle options, alerts, privileged helper and maintenance actions.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Defaults
// `Settings` (sindresorhus/Settings) clashes with SwiftUI's `Settings` scene.
// The scoped `import enum` makes `Settings.Container` / `Settings.Section`
// resolve to the package's namespace in this file (see PATCHES.md (d)).
import Settings
import enum Settings.Settings
import FanControlCore
import FanControlKit

struct FanControlGeneralTabView: View {

    @Binding var actionError: String?

    @Default(.fanControlGeneralSettings) private var general
    /// True while the SMC dump is being produced (button disabled).
    @State private var isExportingDump = false

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        Settings.Container(contentWidth: 480.0) {
            Settings.Section(label: { Text("Fan Control") }) {
                HStack {
                    Text("Enable Fan Control")
                    Spacer()
                    Toggle("", isOn: isEnabled)
                        .labelsHidden()
                }
                .padding(.vertical, 4)

                HStack {
                    Text("Polling Interval")
                    Spacer()
                    Picker("", selection: $general.pollingInterval) {
                        Text("1 second").tag(1.0 as TimeInterval)
                        Text("2 seconds").tag(2.0 as TimeInterval)
                        Text("5 seconds").tag(5.0 as TimeInterval)
                        Text("10 seconds").tag(10.0 as TimeInterval)
                        // A value set elsewhere (e.g. `defaults write`) stays selectable.
                        if !FanControlGeneralSettings.pollingIntervalChoices.contains(general.pollingInterval) {
                            Text("Custom (\(customIntervalText) s)").tag(general.pollingInterval)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 4)

                ToggleRow(title: "Start Monitoring at Launch", isOn: $general.autoStartMonitoring)
                ToggleRow(title: "Pause When Nook Is Hidden", isOn: $general.pauseWhenNookHidden)
                ToggleRow(title: "Re-apply Profile After Wake", isOn: $general.reapplyProfileAfterWake)
            }

            Settings.Section(label: { Text("Alerts") }) {
                ToggleRow(title: "High Temperature Alert", isOn: $general.highTemperatureAlertEnabled)
                ToggleRow(title: "Fan Stopped Alert", isOn: $general.fanAnomalyAlertEnabled)
            }

            Settings.Section(label: { Text("Helper") }) {
                HelperStatusRow(actionError: $actionError)
            }

            Settings.Section(label: { Text("Maintenance") }) {
                HStack {
                    Button("Restore Automatic Control") {
                        fanControlPerform($actionError) { try await manager.restoreDefaultControl() }
                    }
                    Button("Export SMC Dump…") {
                        exportSMCDump()
                    }
                    .disabled(isExportingDump)
                    if isExportingDump {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(0)
        // `pollingInterval` / `reapplyProfileAfterWake` reach the manager through
        // `FanControlAlertCoordinator.syncManagerSettings()` (Defaults.updates).
    }

    /// Turning the feature on starts monitoring; turning it off stops
    /// monitoring and hands every fan back to the SMC.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { general.isEnabled },
            set: { enabled in
                general.isEnabled = enabled
                if enabled {
                    manager.startMonitoring()
                } else {
                    // Restore first, then stop: `restoreDefaultControl()` needs the
                    // SMC reader (it would reopen one if monitoring were already
                    // stopped) and closes the write session itself.
                    fanControlPerform($actionError) {
                        defer { manager.stopMonitoring() }
                        try await manager.restoreDefaultControl()
                    }
                }
            }
        )
    }

    /// Stored polling interval without trailing zeros (e.g. "3", "0.5").
    private var customIntervalText: String {
        general.pollingInterval.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Produces the dump off the main thread (`await manager.exportSMCDump()`
    /// runs on the manager's poll queue; reading every key can take seconds),
    /// then writes it to a user-chosen text file via `NSSavePanel` on the main actor.
    private func exportSMCDump() {
        guard !isExportingDump else { return }
        isExportingDump = true
        Task { @MainActor in
            let dump = await manager.exportSMCDump()
            isExportingDump = false
            showSavePanel(for: dump)
        }
    }

    @MainActor
    private func showSavePanel(for dump: String) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export SMC Dump")
        panel.nameFieldStringValue = "SMC-Dump.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try dump.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Rows

private struct ToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// Helper install state, connection state and the matching action.
private struct HelperStatusRow: View {
    @Binding var actionError: String?

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Privileged Helper")
                Spacer()
                statusText
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Connection")
                Spacer()
                connectionText
                    .foregroundStyle(.secondary)
            }

            switch manager.helperStatus {
            case .enabled:
                EmptyView()
            case .installedManually:
                // Manual / personal mode (FanControl/Support/manual-install/): installed
                // by root, so the app offers no install/uninstall action.
                Text("The helper was installed manually with install.sh. After updating DynamicNotch, run sudo install.sh again; remove it with sudo uninstall.sh (FanControl/Support/manual-install/).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check Again") {
                    manager.refreshHelperStatus()
                }
            case .requiresApproval:
                Text("Allow “DynamicNotch” in System Settings ▸ General ▸ Login Items & Extensions (macOS 15) / Login Items (macOS 14) to let it change fan speeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Login Items") {
                        HelperInstaller.openSystemSettingsLoginItems()
                    }
                    Button("Check Again") {
                        manager.refreshHelperStatus()
                    }
                }
            case .notFound:
                // Packaging error: `SMAppService` cannot find the launchd plist,
                // so installing cannot succeed. No install button.
                Text("The helper’s launchd plist is missing from DynamicNotch.app. Reinstall DynamicNotch to change fan speeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notRegistered, .unknown:
                Text("Reading temperatures works without the helper. Changing fan speeds requires installing it (administrator approval is needed).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Helper…") {
                    fanControlPerform($actionError) {
                        try await manager.installHelper()
                        manager.refreshHelperStatus()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusText: some View {
        switch manager.helperStatus {
        case .notRegistered: Text("Not installed")
        case .enabled: Text("Installed")
        case .installedManually: Text("Installed manually (personal mode)")
        case .requiresApproval: Text("Waiting for approval")
        case .notFound: Text("Missing from app bundle")
        case .unknown(let detail): Text("Unknown (\(detail))")
        }
    }

    @ViewBuilder private var connectionText: some View {
        switch manager.helperConnectionState {
        case .disconnected: Text("Disconnected")
        case .connecting: Text("Connecting…")
        case .connected:
            if manager.isSMCWriteSessionOpen {
                Text("Connected (controlling fans)")
            } else {
                Text("Connected")
            }
        case .error(let detail): Text("Error: \(detail)")
        }
    }
}
#endif
