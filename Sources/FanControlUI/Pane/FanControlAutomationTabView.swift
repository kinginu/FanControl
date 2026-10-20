#if os(macOS)
// "Automation" sub-tab of the Fan Control settings pane (feature F3): workload-linked profile
// switching. Edits `FanControlSettingKey.automation`; shows `FanControlAutomationState.shared`,
// which the host's driver (DynamicNotch: `WorkloadProfileCoordinator`) keeps up to date.
// docs/kit.md "Workload automation".

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FanControlCore
import FanControlKit

public struct FanControlAutomationTabView: View {

    @FanControlSetting(.automation) private var settings
    @FanControlSetting(.general) private var general

    private var state: FanControlAutomationState { FanControlAutomationState.shared }

    public init() {}

    public var body: some View {
        Form {
            Section("Automation") {
                Toggle("Switch Profiles Automatically", isOn: $settings.isEnabled)
                LabeledContent("Status") {
                    Text(verbatim: state.statusText)
                        .foregroundStyle(.secondary)
                }
                if case .pausedByManualSelection = state.status {
                    Button("Resume Automation") { state.resume() }
                }
                if let error = state.lastApplyError {
                    Label {
                        Text(verbatim: error)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                }
                if !general.isEnabled {
                    Text("Fan control is turned off in General, so automation does nothing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach($settings.appRules) { $rule in
                    FanControlAutomationAppRuleRow(rule: $rule) {
                        settings.appRules.removeAll { $0.id == rule.id }
                    }
                }
                Button("Add App…", action: addApps)
            } header: {
                Text("Apps")
            } footer: {
                Text("The first matching app in the list wins. App rules take precedence over the load rule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sustained Load") {
                Toggle("Switch on Sustained Load", isOn: $settings.loadRule.isEnabled)
                Group {
                    Picker("Measure", selection: $settings.loadRule.metric) {
                        Text("CPU").tag(WorkloadLoadRule.Metric.cpu)
                        Text("GPU").tag(WorkloadLoadRule.Metric.gpu)
                        Text("CPU or GPU").tag(WorkloadLoadRule.Metric.either)
                    }
                    FanControlAutomationProfilePicker(title: "Profile", selection: $settings.loadRule.profileID)
                    percentStepper("Switch When Above", value: $settings.loadRule.highThreshold,
                                   range: Swift.max(settings.loadRule.lowThreshold, 5)...100)
                    secondsStepper("For at Least", value: $settings.loadRule.highDuration, range: 0...600)
                    percentStepper("Return When Below", value: $settings.loadRule.lowThreshold,
                                   range: 0...settings.loadRule.highThreshold)
                    secondsStepper("For at Least", value: $settings.loadRule.lowDuration, range: 0...600)
                    LabeledContent("Current Load") {
                        Text(verbatim: currentLoadText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.loadRule.isEnabled)
            }

            Section {
                Picker("After Choosing a Profile by Hand", selection: $settings.manualOverrideMinutes) {
                    ForEach(WorkloadAutomationSettings.manualOverrideChoices, id: \.self) { minutes in
                        Text(verbatim: Self.overrideText(minutes)).tag(minutes)
                    }
                }
                secondsStepper("Keep App Profile After the App Quits", value: $settings.appReleaseDelay, range: 0...120)
            } header: {
                Text("Manual Override")
            } footer: {
                Text("Choosing a profile in the widget or in Profiles pauses automation. When a rule ends, the profile that was active before it is restored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    private var currentLoadText: String {
        func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) %" } ?? "–" }
        return "CPU \(percent(state.cpuLoad)) · GPU \(percent(state.gpuLoad))"
    }

    private func percentStepper(_ title: LocalizedStringKey, value: Binding<Double>,
                                range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            LabeledContent(title) { Text(verbatim: "\(Int(value.wrappedValue)) %").monospacedDigit() }
        }
    }

    private func secondsStepper(_ title: LocalizedStringKey, value: Binding<TimeInterval>,
                                range: ClosedRange<TimeInterval>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            LabeledContent(title) { Text(verbatim: "\(Int(value.wrappedValue)) s").monospacedDigit() }
        }
    }

    static func overrideText(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "Pause Until Resumed")
        case 60: return String(localized: "Pause for 1 Hour")
        case let m where m % 60 == 0: return String(localized: "Pause for \(m / 60) Hours")
        default: return String(localized: "Pause for \(minutes) Minutes")
        }
    }

    // MARK: Actions

    /// Lets the user pick apps (NSOpenPanel on /Applications) and adds a Boost rule for each
    /// one not listed yet.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an App")
        panel.prompt = String(localized: "Add")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        var rules = settings.appRules
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier,
                  !rules.contains(where: { $0.bundleIdentifier == identifier }) else { continue }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            rules.append(WorkloadAppRule(bundleIdentifier: identifier, displayName: name))
        }
        settings.appRules = rules
    }
}

/// One app rule: enabled, icon + name, trigger, profile, remove.
private struct FanControlAutomationAppRuleRow: View {
    @Binding var rule: WorkloadAppRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
            Text(verbatim: rule.displayName)
                .lineLimit(1)
                .help(Text(verbatim: rule.bundleIdentifier))
            Spacer(minLength: 8)
            Picker("", selection: $rule.trigger) {
                Text("While Running").tag(WorkloadAppRule.Trigger.running)
                Text("While Frontmost").tag(WorkloadAppRule.Trigger.frontmost)
            }
            .labelsHidden()
            .fixedSize()
            FanControlAutomationProfilePicker(title: "", selection: $rule.profileID)
                .labelsHidden()
                .fixedSize()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Remove"))
            .accessibilityLabel(Text("Remove"))
        }
    }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// Picker over the seven fixed profiles.
private struct FanControlAutomationProfilePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: UUID

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(FanControlProfiles.all) { profile in
                Text(verbatim: FanControlFormatting.profileName(profile)).tag(profile.id)
            }
        }
    }
}

/// One line for a fan widget header: "Auto: Boost (Xcode)" while a rule's profile is active,
/// "Auto paused" during a manual override; nothing otherwise.
public struct FanControlAutomationIndicator: View {

    public init() {}

    public var body: some View {
        if let text = FanControlAutomationState.shared.indicatorText {
            Text(verbatim: text)
                .font(.caption2.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text("Fan profile chosen by Automation (Settings ▸ Fan Control ▸ Automation)"))
        }
    }
}
#endif
