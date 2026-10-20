#if os(macOS)
// Workload automation (feature F3), UI side: the stored settings key and the observable
// runtime state that the Automation tab and the widget indicator show.
//
// The rules engine is `WorkloadProfileEngine` (FanControlKit); the host drives it (DynamicNotch:
// `WorkloadProfileCoordinator`, DynamicNotchApp) and mirrors what it does into
// `FanControlAutomationState.shared`. Settings are edited here and read by the host through
// `FanControlSettingKey.automation` (`value` / `updates()`). docs/kit.md "Workload automation".

import Foundation
import Observation
import FanControlCore
import FanControlKit

// MARK: - Stored settings

extension WorkloadAutomationSettings: CodableStoredValue {}

extension StoredKeys {
    static let fanControlWorkloadAutomation = Key<WorkloadAutomationSettings>(
        "fanControlWorkloadAutomation", default: .init())
}

extension FanControlSettingKey where Value == WorkloadAutomationSettings {
    /// App / sustained-load rules and the manual-override pause (Settings ▸ Automation).
    public static var automation: Self { Self(StoredKeys.fanControlWorkloadAutomation) }
}

// MARK: - Runtime state

/// What workload automation is doing, written by the host that drives
/// `WorkloadProfileEngine` and read by `FanControlAutomationTabView` /
/// `FanControlAutomationIndicator`. Without a host it stays `.disabled`.
@MainActor
@Observable
public final class FanControlAutomationState {

    public static let shared = FanControlAutomationState()

    /// The engine's last status.
    public var status: WorkloadStatus = .disabled
    /// Last CPU / GPU load sample in percent (`nil` = none yet / unreadable).
    public var cpuLoad: Double?
    public var gpuLoad: Double?
    /// Message of the last failed automatic apply (`nil` after a success).
    public var lastApplyError: String?
    /// Called by "Resume Automation" (ends a manual-override pause).
    @ObservationIgnored public var onResume: (@MainActor () -> Void)?

    public init() {}

    public func resume() { onResume?() }

    /// One line for a fan widget: "Auto: Boost (Xcode)" while the engaged profile is
    /// active, "Auto paused" during a manual override; `nil` otherwise (also while an
    /// automatic apply has failed, so the line never claims a profile that is not running).
    public var indicatorText: String? {
        switch status {
        case .engaged(let id, let reason):
            guard FanControlProfiles.activeID == id else { return nil }
            let name = Self.profileName(id)
            let why = Self.reasonText(reason)
            return String(localized: "Auto: \(name) (\(why))")
        case .pausedByManualSelection:
            return String(localized: "Auto paused")
        case .disabled, .idle, .heldForEmergency:
            return nil
        }
    }

    /// The status as one line for the settings tab.
    public var statusText: String {
        switch status {
        case .disabled:
            return String(localized: "Off")
        case .idle:
            return String(localized: "Waiting for a rule")
        case .engaged(let id, let reason):
            let name = Self.profileName(id)
            let why = Self.reasonText(reason)
            return "\(name) (\(why))"
        case .pausedByManualSelection(let until):
            guard let until else { return String(localized: "Paused until resumed") }
            let time = until.formatted(date: .omitted, time: .shortened)
            return String(localized: "Paused until \(time)")
        case .heldForEmergency:
            return String(localized: "Held during the emergency override")
        }
    }

    /// "Xcode", "CPU load", "GPU load", "High load".
    public static func reasonText(_ reason: WorkloadReason) -> String {
        switch reason {
        case .app(_, let name): return name
        case .load(.cpu): return String(localized: "CPU load")
        case .load(.gpu): return String(localized: "GPU load")
        case .load(.either): return String(localized: "High load")
        }
    }

    /// Display name of a fixed or stored profile.
    public static func profileName(_ id: UUID) -> String {
        FanControlAutomationProfiles.profile(id).map(FanControlFormatting.profileName)
            ?? String(localized: "Profile")
    }
}

/// Profile lookup shared by the automation host and views.
@MainActor
public enum FanControlAutomationProfiles {
    /// One of the seven fixed profiles, else a stored additional profile (a baseline can
    /// be one, e.g. "Custom" from `setFanRPM`).
    public static func profile(_ id: UUID) -> FanProfile? {
        FanControlProfiles.all.first { $0.id == id } ?? FanControlManager.shared.profileStore.profile(id: id)
    }
}
#endif
