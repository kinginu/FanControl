#if os(macOS)
// F2: one-line Power Profiles status under the Fan Control widget's header
// ("On Battery · Constant Quiet · Low Power"), with "Resume" while a hand-picked fan profile
// overrides the rules. Hidden while Power Profiles are off.

import SwiftUI
import FanControlCore
import FanControlKit

public struct FanControlPowerProfileStatusLine: View {
    private let isCompact: Bool

    private var engine: PowerProfileEngine { PowerProfileEngine.shared }

    /// `isCompact`: the smaller font and no fan profile name (narrow widget sizes).
    public init(isCompact: Bool = false) {
        self.isCompact = isCompact
    }

    public var body: some View {
        if let status = engine.status {
            HStack(spacing: 3) {
                Image(systemName: status.error != nil ? "exclamationmark.triangle" : "bolt.badge.automatic")
                    .foregroundStyle(status.error != nil ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
                Text(verbatim: text(status))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if status.isManualOverride {
                    Button("Resume") {
                        Task { await engine.resumeAutomation() }
                    }
                    .buttonStyle(.borderless)
                    .help("Let the power profile rules choose the fan profile again")
                }
            }
            .font(isCompact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .help(Text(verbatim: status.error ?? help(status)))
            .accessibilityElement(children: .combine)
        }
    }

    private func text(_ status: PowerProfileStatus) -> String {
        if status.isManualOverride { return "Manual" + (status.ruleName.map { " (rule: \($0))" } ?? "") }
        if status.winningLayer == .workload || status.winningLayer == .emergency {
            return status.winningLayer?.displayName ?? ""
        }
        guard let rule = status.ruleName else { return "No rule matches" }
        var parts = [rule]
        if let id = status.fanProfileID, !isCompact { parts.append(profileName(id)) }
        if status.isLowPowerModeEnabled == true { parts.append("Low Power") }
        return parts.joined(separator: " · ")
    }

    private func help(_ status: PowerProfileStatus) -> String {
        if status.isManualOverride {
            return "You chose this fan profile by hand. The rules take over again when the situation changes, or click Resume."
        }
        return "Power Profiles: \(status.ruleName ?? "no rule matches")"
    }

    private func profileName(_ id: UUID) -> String {
        FanControlProfiles.all.first { $0.id == id }.map(FanControlFormatting.profileName) ?? "Unknown Profile"
    }
}
#endif
