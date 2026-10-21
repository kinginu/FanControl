#if os(macOS)
// F2: the "Power Profiles" settings pane (DynamicNotchApp/docs/power-profiles.md): a master
// switch, the live context, and an ordered rules editor (first match wins). Each rule maps
// power source / lid / time window to a fan profile and a Low Power Mode setting.
// Meant as a top-level tab of the host's settings window (e.g. DynamicNotch);
// `PowerProfileEngine` persists the rules.

import SwiftUI
import FanControlCore
import FanControlKit

public struct FanControlPowerProfilesSettingsView: View {

    @State private var expandedRuleID: UUID?
    @State private var pmsetState: Bool??
    @State private var isCheckingPmset = false

    private var engine: PowerProfileEngine { PowerProfileEngine.shared }

    public init() {}

    public var body: some View {
        @Bindable var model = engine
        Form {
            Section {
                Toggle("Use Power Profiles", isOn: $model.configuration.isEnabled)
                Text("Rules are checked from top to bottom and the first one that matches decides. A fan profile you choose by hand stays until the situation changes. Low Power Mode is changed through the fan control helper and given back to your own setting when no rule asks for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Now") {
                LabeledContent("Power Source", value: powerSourceText)
                LabeledContent("Lid", value: lidText)
                LabeledContent("Low Power Mode") {
                    HStack(spacing: 6) {
                        Text(verbatim: onOff(engine.isLowPowerModeEnabled))
                        if let pmsetState {
                            Text(verbatim: "(pmset: \(onOff(pmsetState)))")
                                .foregroundStyle(.secondary)
                        }
                        Button("Check pmset") { checkPmset() }
                            .buttonStyle(.borderless)
                            .disabled(isCheckingPmset)
                    }
                }
                LabeledContent("Matching Rule", value: engine.configuration.isEnabled
                               ? (engine.matchedRule?.name ?? "None") : "Power Profiles are off")
                if engine.arbiter.arbitration.isManualOverrideActive {
                    LabeledContent("Fan Profile") {
                        HStack(spacing: 6) {
                            Text("Chosen manually")
                            Button("Resume Rules") {
                                Task { await engine.resumeAutomation() }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else if let decision = engine.arbiter.decision, engine.configuration.isEnabled {
                    LabeledContent("Fan Profile", value: "\(profileName(decision.profileID)) (\(decision.layer.displayName))")
                }
                if let error = engine.arbiter.lastError ?? engine.lowPowerModeError {
                    Label {
                        Text(verbatim: error)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                }
            }

            Section {
                if engine.configuration.rules.isEmpty {
                    Text("No rules yet. Add one below, or start from a template.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.configuration.rules) { $rule in
                    PowerProfileRuleRow(rule: $rule,
                                        isMatching: engine.matchedRule?.id == rule.id,
                                        isUnreachable: engine.configuration.unreachableRuleIDs.contains(rule.id),
                                        isExpanded: expandedBinding(rule.id),
                                        canMoveUp: rule.id != engine.configuration.rules.first?.id,
                                        canMoveDown: rule.id != engine.configuration.rules.last?.id,
                                        move: { offset in move(rule.id, by: offset) },
                                        delete: { delete(rule.id) })
                }
                Menu("Add Rule") {
                    Button("Empty Rule") {
                        add(PowerProfileRule(name: "New Rule"))
                    }
                    Divider()
                    ForEach(PowerProfileRule.templates(), id: \.name) { template in
                        Button(template.name) { add(template) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Rules")
            } footer: {
                Text("Precedence: a profile you choose by hand, then emergency and workload rules, then power profiles, then your own profile. The all-fans-maximum safety override always applies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { checkPmset() }
    }

    // MARK: Now

    private var powerSourceText: String {
        switch engine.context?.powerSource {
        case .ac: return "Power Adapter"
        case .battery: return "Battery"
        case nil: return "Unknown"
        }
    }

    private var lidText: String {
        switch engine.context?.isLidClosed {
        case true?: return "Closed"
        case false?: return "Open"
        case nil: return "No lid"
        }
    }

    private func onOff(_ value: Bool?) -> String {
        switch value {
        case true?: return "On"
        case false?: return "Off"
        case nil: return "Unknown"
        }
    }

    private func profileName(_ id: UUID) -> String {
        FanControlProfiles.all.first { $0.id == id }.map(FanControlFormatting.profileName) ?? "Unknown Profile"
    }

    private func checkPmset() {
        isCheckingPmset = true
        Task { @MainActor in
            pmsetState = .some(await LowPowerModeReader.pmsetState())
            isCheckingPmset = false
            engine.requestEvaluation()  // refresh the ProcessInfo value and the context
        }
    }

    // MARK: Editing

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandedRuleID == id },
                set: { expandedRuleID = $0 ? id : (expandedRuleID == id ? nil : expandedRuleID) })
    }

    private func add(_ rule: PowerProfileRule) {
        var rule = rule
        rule.id = UUID()
        engine.configuration.rules.append(rule)
        expandedRuleID = rule.id
    }

    private func move(_ id: UUID, by offset: Int) {
        var rules = engine.configuration.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        engine.configuration.rules = rules
    }

    private func delete(_ id: UUID) {
        engine.configuration.rules.removeAll { $0.id == id }
        if expandedRuleID == id { expandedRuleID = nil }
    }
}

/// One rule: summary row (enable switch, name, conditions → actions, reorder, delete) with
/// an inline editor.
private struct PowerProfileRuleRow: View {
    @Binding var rule: PowerProfileRule
    let isMatching: Bool
    let isUnreachable: Bool
    @Binding var isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PowerProfileRuleEditor(rule: $rule)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Toggle("Enabled", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(verbatim: rule.name.isEmpty ? "Untitled Rule" : rule.name)
                            .fontWeight(.medium)
                        if isMatching {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                    Text(verbatim: PowerProfileRuleText.summary(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if isUnreachable {
                        Text("Never used: an earlier rule matches everything.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .opacity(rule.isEnabled ? 1 : 0.5)
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    .help("Move Up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                    .help("Move Down")
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete Rule")
            }
        }
    }
}

/// The editor of one rule (conditions and actions).
private struct PowerProfileRuleEditor: View {
    @Binding var rule: PowerProfileRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $rule.name)

            Text("When")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Power Source", selection: $rule.powerSource) {
                Text("Any").tag(PowerSourceCondition.any)
                Text("Power Adapter").tag(PowerSourceCondition.ac)
                Text("Battery").tag(PowerSourceCondition.battery)
            }
            Picker("Lid", selection: $rule.lid) {
                Text("Any").tag(LidCondition.any)
                Text("Open").tag(LidCondition.open)
                Text("Closed (Clamshell)").tag(LidCondition.closed)
            }
            Toggle("Only at Certain Times", isOn: hasTimeWindow)
            if rule.timeWindow != nil {
                HStack {
                    DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                }
                WeekdayPicker(weekdays: weekdaysBinding)
                Text("Times wrap past midnight (22:00 to 07:00 is overnight). Same start and end means all day. No day selected means every day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Then")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Fan Profile", selection: $rule.fanProfileID) {
                Text("Don’t Change").tag(UUID?.none)
                ForEach(FanControlProfiles.all) { profile in
                    Text(verbatim: FanControlFormatting.profileName(profile)).tag(UUID?.some(profile.id))
                }
            }
            Picker("Low Power Mode", selection: $rule.lowPowerMode) {
                Text("Don’t Change").tag(LowPowerModeAction.unchanged)
                Text("On").tag(LowPowerModeAction.on)
                Text("Off").tag(LowPowerModeAction.off)
            }
            if rule.lowPowerMode != .unchanged {
                Text("Needs the fan control helper (install.sh). Sets Low Power Mode for all power sources, like “Always” or “Never” in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasTimeWindow: Binding<Bool> {
        Binding(get: { rule.timeWindow != nil },
                set: { rule.timeWindow = $0 ? (rule.timeWindow ?? PowerTimeWindow(from: (22, 0), to: (7, 0))) : nil })
    }

    private var weekdaysBinding: Binding<Set<Int>> {
        Binding(get: { rule.timeWindow?.weekdays ?? [] },
                set: { rule.timeWindow?.weekdays = $0 })
    }

    /// Minutes after midnight ↔ a `Date` today (local time) for the hour-and-minute picker.
    private func minuteBinding(_ keyPath: WritableKeyPath<PowerTimeWindow, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = rule.timeWindow?[keyPath: keyPath] ?? 0
                let midnight = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                rule.timeWindow?[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}

/// Seven toggle buttons in the user's week order (system weekday symbols).
private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>

    private var order: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                Toggle(isOn: Binding(get: { weekdays.contains(day) },
                                     set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } })) {
                    Text(verbatim: Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .frame(minWidth: 14)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
    }
}

/// Plain-English summaries of rules (settings rows, widget status line).
@MainActor
enum PowerProfileRuleText {
    static func summary(_ rule: PowerProfileRule) -> String {
        "\(conditions(rule)) → \(actions(rule))"
    }

    static func conditions(_ rule: PowerProfileRule) -> String {
        var parts: [String] = []
        switch rule.powerSource {
        case .any: break
        case .ac: parts.append("on power adapter")
        case .battery: parts.append("on battery")
        }
        switch rule.lid {
        case .any: break
        case .open: parts.append("lid open")
        case .closed: parts.append("lid closed")
        }
        if let window = rule.timeWindow {
            parts.append(window.isAllDay ? "all day" : "\(clock(window.startMinute))–\(clock(window.endMinute))")
            if !window.weekdays.isEmpty {
                let symbols = Calendar.current.shortWeekdaySymbols
                parts.append(window.weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: ", "))
            }
        }
        return parts.isEmpty ? "Always" : parts.joined(separator: ", ").capitalizedFirst
    }

    static func actions(_ rule: PowerProfileRule) -> String {
        var parts: [String] = []
        if let id = rule.fanProfileID {
            let name = FanControlProfiles.all.first { $0.id == id }.map(FanControlFormatting.profileName) ?? "Unknown Profile"
            parts.append(name)
        }
        switch rule.lowPowerMode {
        case .unchanged: break
        case .on: parts.append("Low Power Mode on")
        case .off: parts.append("Low Power Mode off")
        }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Host start-up hook (e.g. DynamicNotch): call once from
/// `applicationDidFinishLaunching`, after the Fan Control start-up. Starts the engine (cheap and
/// inert while Power Profiles are off) and keeps fan switching off while the Fan Control feature
/// is disabled (`FanControlSettingKey.general`). When the feature is switched back on, a
/// decision the arbiter held back meanwhile is applied (`applyAllowedDidChange()`).
@MainActor
public enum FanControlPowerProfiles {
    private static var gateTask: Task<Void, Never>?

    public static func start() {
        FanProfileArbiter.shared.isApplyAllowed = { FanControlSettingKey.general.value.isEnabled }
        if gateTask == nil {
            gateTask = Task { @MainActor in
                var wasEnabled = FanControlSettingKey.general.value.isEnabled
                for await settings in FanControlSettingKey.general.updates(initial: false) {
                    let isEnabled = settings.isEnabled
                    defer { wasEnabled = isEnabled }
                    guard isEnabled, !wasEnabled else { continue }
                    await FanProfileArbiter.shared.applyAllowedDidChange()
                }
            }
        }
        PowerProfileEngine.shared.start()
    }
}
#endif
