#if os(macOS)
// "General" tab of the Fan Control settings pane: feature switch, polling,
// lifecycle options, alerts, temperature thresholds (FanControlThresholdSettings,
// own stored-setting key), privileged helper and maintenance actions.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FanControlCore
import FanControlKit

public struct FanControlGeneralTabView: View {

    @Binding var actionError: String?

    public init(actionError: Binding<String?>) {
        _actionError = actionError
    }

    @StoredSetting(.fanControlGeneralSettings) private var general
    @StoredSetting(.fanControlThresholdSettings) private var thresholdSettings
    /// For `temperatureUnit` only: the thresholds are shown and stepped in the
    /// widget's unit (°C / °F) but stored in °C.
    @StoredSetting(.fanControlWidgetSettings) private var widgetSettings
    /// True while the SMC dump is being produced (button disabled).
    @State private var isExportingDump = false

    private var manager: FanControlManager { FanControlManager.shared }

    public var body: some View {
        // Grouped form (System Settings style); scrolls inside the pane's fixed size
        // (FanControlSettingsView.contentSize).
        Form {
            // Another fan control app (FanFi) is running: both writing override each other.
            if !manager.conflictingControllers.isEmpty {
                Section {
                    Label {
                        Text("Another fan control app (\(conflictingNames)) is running. If both write at the same time they will override each other.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }

            Section("Fan Control") {
                Toggle("Enable Fan Control", isOn: isEnabled)

                Picker("Polling Interval", selection: $general.pollingInterval) {
                    Text("1 second").tag(1.0 as TimeInterval)
                    Text("2 seconds").tag(2.0 as TimeInterval)
                    Text("5 seconds").tag(5.0 as TimeInterval)
                    Text("10 seconds").tag(10.0 as TimeInterval)
                    // A value set elsewhere (e.g. `defaults write`) stays selectable.
                    if !FanControlGeneralSettings.pollingIntervalChoices.contains(general.pollingInterval) {
                        Text("Custom (\(customIntervalText) s)").tag(general.pollingInterval)
                    }
                }

                Toggle("Slow Down Polling on Battery (10 s)", isOn: $general.slowPollingOnBattery)
                Toggle("Start Monitoring at Launch", isOn: $general.autoStartMonitoring)
                Toggle("Pause When Nook Is Hidden", isOn: $general.pauseWhenNookHidden)
                Toggle("Re-apply Profile After Wake", isOn: $general.reapplyProfileAfterWake)
            }

            Section("Alerts") {
                Toggle("High Temperature Alert", isOn: $general.highTemperatureAlertEnabled)
                Toggle("Fan Stopped Alert", isOn: $general.fanAnomalyAlertEnabled)
            }

            Section("Temperature Thresholds") {
                thresholdStepper("High Temperature Alert", value: \.highTemperatureAlert,
                                 kind: .absolute, range: ThresholdBounds.alertRange,
                                 set: ThresholdBounds.settingHighTemperatureAlert)
                thresholdStepper("Emergency (All Fans Maximum)", value: \.emergencyTemperature,
                                 kind: .absolute, range: ThresholdBounds.emergencyOverallRange,
                                 set: ThresholdBounds.settingEmergencyTemperature)
                thresholdStepper("Hysteresis", value: \.alertHysteresis,
                                 kind: .delta, range: ThresholdBounds.hysteresisRange,
                                 set: ThresholdBounds.settingAlertHysteresis)
                Text("The alert and the all-fans-maximum override turn on when the hottest CPU/GPU sensor reaches these temperatures, and off again once it has cooled by the hysteresis.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset to Defaults") {
                    thresholdSettings = FanControlThresholdSettings()
                }
                .disabled(thresholdSettings.thresholds == .default)
            }

            Section("Helper") {
                HelperStatusRows(actionError: $actionError)
            }

            Section("Maintenance") {
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
            }
        }
        .formStyle(.grouped)
        // `pollingInterval` / `slowPollingOnBattery` / `reapplyProfileAfterWake` reach the
        // manager through `FanControlAlertCoordinator.syncManagerSettings()` (SettingsStore.updates).
        .onAppear { manager.refreshConflictingControllers() }
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
                    // Stop only if the feature is still off once the restore has
                    // finished: a quick off → on (double-click) has already run
                    // `startMonitoring()` on the on-path, which must not be undone.
                    fanControlPerform($actionError) {
                        defer {
                            if !SettingsStore[.fanControlGeneralSettings].isEnabled {
                                manager.stopMonitoring()
                            }
                        }
                        try await manager.restoreDefaultControl()
                    }
                }
            }
        )
    }

    /// One threshold row: label, value and stepper in the widget's temperature
    /// unit (`widgetSettings.temperatureUnit`), stored in °C. A step moves to the
    /// next whole °C or °F (`TemperatureUnitConversion.stepped`; the hysteresis is
    /// a difference, so °F = °C × 9/5 without the +32 offset). The resulting °C
    /// value goes through `set` (`ThresholdBounds.setting…`), which clamps it to
    /// `range` (°C) and re-clamps the other two values; the coordinator mirrors
    /// the result into `manager.safetyPolicy`
    /// (`FanControlAlertCoordinator.syncManagerSettings()`). A button is disabled
    /// at its end of `range`.
    private func thresholdStepper(_ title: LocalizedStringKey,
                                  value: KeyPath<SafetyThresholds, Double>,
                                  kind: TemperatureUnitConversion.Kind,
                                  range: ClosedRange<Double>,
                                  set: @escaping (Double, SafetyThresholds) -> SafetyThresholds) -> some View {
        let unit = widgetSettings.temperatureUnit
        let current = ThresholdBounds.clamped(thresholdSettings.thresholds)[keyPath: value]
        let step: (Bool) -> Void = { up in
            let thresholds = ThresholdBounds.clamped(thresholdSettings.thresholds)
            let next = TemperatureUnitConversion.stepped(celsius: thresholds[keyPath: value],
                                                         kind: kind, unit: unit, up: up)
            thresholdSettings.thresholds = set(next, thresholds)
        }
        let canIncrement = TemperatureUnitConversion.canStep(celsius: current, up: true, within: range)
        let canDecrement = TemperatureUnitConversion.canStep(celsius: current, up: false, within: range)
        return Stepper(onIncrement: canIncrement ? { step(true) } : nil,
                       onDecrement: canDecrement ? { step(false) } : nil) {
            LabeledContent(title) {
                Text(verbatim: TemperatureUnitConversion.label(celsius: current, kind: kind, unit: unit))
                    .monospacedDigit()
            }
        }
    }

    /// `manager.conflictingControllers` as one list ("FanFi", "FanFi, Other"; product names).
    private var conflictingNames: String {
        manager.conflictingControllers.formatted(.list(type: .and))
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

/// Helper install state, connection state and the matching action.
private struct HelperStatusRows: View {
    @Binding var actionError: String?

    /// Output of the last (or running) host installer run (`FanControlHostActions`).
    @State private var installerLog: String?
    @State private var showsInstallerLog = false
    /// Non-nil while a host installer runs ("Installing…" / "Uninstalling…"); buttons disabled.
    @State private var runningInstaller: LocalizedStringKey?

    private var manager: FanControlManager { FanControlManager.shared }
    private var hostInstalls: Bool { FanControlHostActions.providesHelperInstaller }

    /// One form row per item (`LabeledContent` shows the value right-aligned, like System Settings).
    var body: some View {
        Group {
            LabeledContent("Privileged Helper") { statusText }
            LabeledContent("Connection") { connectionText }

            // Refused at runtime although the files look fine (e.g. the plist could
            // not be read, or a Team-ID build): same remedy, explained once here.
            if case .rejected(let reason) = manager.helperConnectionState,
               !manager.helperStatus.isManualMismatch {
                Text(fanControlRejectionHelp(reason))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch manager.helperStatus {
            case .enabled:
                EmptyView()
            case .installedManually:
                // Manual / personal mode (FanControl/Support/manual-install/): installed by
                // root. Without a host installer the app offers no install/uninstall action.
                if hostInstalls {
                    Text("The helper is installed for this build of DynamicNotch. After every update of DynamicNotch, install the helper again (it only accepts the build it was installed for).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The helper was installed manually with install.sh. After updating DynamicNotch, run sudo install.sh again; remove it with sudo uninstall.sh (FanControl/Support/manual-install/).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    // A rejection although the files are there (e.g. the installed helper is
                    // another build's): reinstalling is the remedy.
                    if hostInstalls, case .rejected = manager.helperConnectionState {
                        installButton
                    }
                    checkAgainButton
                    uninstallButton
                }
            case .installedManuallyMismatch:
                // The plist pins another build's cdhash: the app does not connect at all
                // until install.sh is re-run (HelperRejectionReason.clientNotPinned).
                Text(fanControlRejectionHelp(.clientNotPinned(pinnedCDHash: "", appCDHash: "")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if hostInstalls { installButton }
                    checkAgainButton
                    uninstallButton
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
            case .notFound where !hostInstalls:
                // Packaging error: `SMAppService` cannot find the launchd plist,
                // so installing cannot succeed. No install button.
                Text("The helper’s launchd plist is missing from DynamicNotch.app. Reinstall DynamicNotch to change fan speeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notRegistered, .unknown, .notFound:
                // (.notFound only with a host installer, which does not need the SMAppService plist.)
                Text("Reading temperatures works without the helper. Changing fan speeds requires installing it (administrator approval is needed).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hostInstalls {
                    installButton
                } else {
                    Button("Install Helper…") {
                        fanControlPerform($actionError) {
                            try await manager.installHelper()
                            manager.refreshHelperStatus()
                        }
                    }
                }
            }

            if let runningInstaller {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runningInstaller)
                        .foregroundStyle(.secondary)
                }
            }
            if let installerLog {
                DisclosureGroup("Installer Output", isExpanded: $showsInstallerLog) {
                    ScrollView {
                        Text(verbatim: installerLog.isEmpty ? "—" : installerLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    // MARK: Actions

    private var checkAgainButton: some View {
        Button("Check Again") {
            // Forgets a rejection / backoff and probes the helper once (read-only).
            fanControlPerform($actionError) { try await manager.retryHelperConnection() }
        }
        .disabled(runningInstaller != nil)
    }

    /// "Install Helper…" through the host (`FanControlHostActions.installHelper`): asks for an
    /// administrator password, installs the helper pinned to this build, then checks again.
    @ViewBuilder private var installButton: some View {
        if let install = FanControlHostActions.installHelper {
            Button("Install Helper…") {
                runInstaller(install, status: "Installing the helper…") {
                    manager.refreshHelperStatus()
                    try await manager.retryHelperConnection()
                }
            }
            .disabled(runningInstaller != nil)
        }
    }

    /// "Uninstall Helper…" (`FanControlHostActions.uninstallHelper`). launchd stops the helper,
    /// which hands the fans back to macOS before exiting.
    @ViewBuilder private var uninstallButton: some View {
        if let uninstall = FanControlHostActions.uninstallHelper {
            Button("Uninstall Helper…") {
                runInstaller(uninstall, status: "Uninstalling the helper…") {
                    manager.refreshHelperStatus()
                }
            }
            .disabled(runningInstaller != nil)
        }
    }

    private func runInstaller(_ action: @escaping FanControlHostActions.HelperInstallerAction,
                              status: LocalizedStringKey,
                              then followUp: @escaping @MainActor () async throws -> Void) {
        guard runningInstaller == nil else { return }
        runningInstaller = status
        installerLog = ""
        actionError = nil
        Task { @MainActor in
            defer { runningInstaller = nil }
            do {
                installerLog = try await action { installerLog = $0 }
                try await followUp()
            } catch is CancellationError {
                // The user cancelled the password dialog: nothing happened.
                manager.refreshHelperStatus()
                if installerLog?.isEmpty ?? true { installerLog = nil }
            } catch let failure as FanControlHelperInstallerFailure {
                installerLog = failure.output
                showsInstallerLog = true
                actionError = failure.summary
                manager.refreshHelperStatus()
            } catch {
                actionError = fanControlErrorMessage(error)
                manager.refreshHelperStatus()
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch manager.helperStatus {
        case .notRegistered: Text("Not installed")
        case .enabled: Text("Installed")
        case .installedManually: Text("Installed manually (personal mode)")
        case .installedManuallyMismatch: Text("Installed manually, pinned to another build")
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
        case .rejected(.clientNotPinned): Text("Refused (pinned to a different build)")
        case .rejected(.droppedByHelper): Text("Refused by the helper")
        case .rejected(.helperSignatureMismatch): Text("Refused (helper signature mismatch)")
        }
    }
}
private extension HelperInstallStatus {
    var isManualMismatch: Bool {
        if case .installedManuallyMismatch = self { return true }
        return false
    }
}
#endif
