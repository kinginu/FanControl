#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Fan Control Live Activity (design doc §4.2): a compact alert shown around the
// notch while the high-temperature or fan-stopped alert is active, plus the
// coordinator that turns `FanControlManager` notifications into Live Activity
// state and a transient "flash", mirroring PowerMonitor's low-battery
// transient (`DynamicNotchBatteryLowTransient`).
//
// ## Wiring into DynamicNotch (see PATCHES.md (e)(f))
//
// 1. Add a case to the `LiveActivity` enum:
//
//        case fanAlert   // id "fanAlert", icon "fan", name "Fan Alert"
//
//    (also add it to `icon`, `id`, `name` and `init?(rawValue:)`).
// 2. In `LiveActivityView`, render `FanControlAlertView(part: .leading)` /
//    `FanControlAlertView(part: .trailing)` for `.fanAlert` on the two sides of
//    the notch (or `FanControlAlertView()` where a single view is expected).
// 3. In `AppDelegate.applicationDidFinishLaunching`, create the coordinator
//    (before `startMonitoring()`, so the manager already has the user's polling
//    interval and wake setting) and forward its state to the app's
//    `ActiveLiveActivitiesManager` instance:
//
//        FanControlAlertCoordinator.shared.onAlertChange = { alert in
//            if alert != nil {
//                activeLiveActivitiesManager.insertSync(.fanAlert)
//            } else {
//                activeLiveActivitiesManager.removeSync(.fanAlert)
//            }
//        }
//
// 4. Optionally observe `FanControlAlertCoordinator.transientNotificationName`
//    wherever `DynamicNotchBatteryLowTransient` is observed, to briefly expand the
//    notch when an alert starts.

import SwiftUI
import AppKit
import Defaults
import FanControlCore
import FanControlKit

// MARK: - Alert kind

enum FanControlAlertKind: Equatable, Hashable {
    /// The hottest CPU/GPU sensor crossed `SafetyPolicy.highTemperatureAlert`.
    case highTemperature
    /// At least one fan reports 0 RPM while a non-zero target is set.
    case fanStopped
}

// MARK: - Coordinator

/// Observes `FanControlManager` alert notifications, applies the user's alert
/// toggles and exposes the alert to show.
///
/// It is also the single place that mirrors the Defaults-backed
/// `FanControlGeneralSettings` into the manager (FanControlKit does not depend
/// on Defaults): `pollingInterval`, `reapplyProfileAfterWake` and
/// `keepAlertsWhilePaused` (= any alert toggle on) are copied at creation and
/// on every settings change. The wake re-apply itself is done by
/// `FanControlManager` (5 s after wake, only while a write session is open).
@MainActor
@Observable
final class FanControlAlertCoordinator {

    static let shared = FanControlAlertCoordinator()

    /// Posted (main queue, `object: nil`) when an alert starts.
    nonisolated static let transientNotificationName = Notification.Name("DynamicNotchFanAlertTransient")

    /// The alert currently shown, or `nil`. A stopped fan wins over high temperature.
    private(set) var currentAlert: FanControlAlertKind? = nil

    /// Called on the main thread whenever `currentAlert` changes. Used to insert or
    /// remove `LiveActivity.fanAlert` in `ActiveLiveActivitiesManager`.
    @ObservationIgnored var onAlertChange: ((FanControlAlertKind?) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.fanControlHighTemperatureChanged, .fanControlFanAnomalyChanged] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
            observers.append(token)
        }

        // Alert toggles, master switch, polling interval or wake option changed in Settings.
        settingsTask = Task { [weak self] in
            for await _ in Defaults.updates(.fanControlGeneralSettings, initial: false) {
                self?.syncManagerSettings()
                self?.reevaluate()
            }
        }

        syncManagerSettings()
        reevaluate()
    }

    /// Copies the manager-relevant general settings into `FanControlManager`.
    /// `pollingInterval` and `keepAlertsWhilePaused` are only assigned when they
    /// changed, because assigning them may reschedule the poll timer.
    func syncManagerSettings() {
        let general = Defaults[.fanControlGeneralSettings]
        let manager = FanControlManager.shared
        if manager.pollingInterval != general.pollingInterval {
            manager.pollingInterval = general.pollingInterval
        }
        manager.reapplyProfileAfterWake = general.reapplyProfileAfterWake
        // Keep a slow poll while the Nook is hidden only if some alert can fire.
        let keepAlerts = general.highTemperatureAlertEnabled || general.fanAnomalyAlertEnabled
        if manager.keepAlertsWhilePaused != keepAlerts {
            manager.keepAlertsWhilePaused = keepAlerts
        }
    }

    /// Recomputes `currentAlert` from the manager state and the alert settings.
    func reevaluate() {
        let general = Defaults[.fanControlGeneralSettings]
        let manager = FanControlManager.shared

        let alert: FanControlAlertKind?
        if general.isEnabled, general.fanAnomalyAlertEnabled, !manager.anomalousFanIDs.isEmpty {
            alert = .fanStopped
        } else if general.isEnabled, general.highTemperatureAlertEnabled, manager.highTempAlertActive {
            alert = .highTemperature
        } else {
            alert = nil
        }

        guard alert != currentAlert else { return }
        currentAlert = alert
        onAlertChange?(alert)

        if alert != nil {
            // Same shape as PowerMonitor.fireTransient().
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.transientNotificationName, object: nil)
            }
        }
    }
}

// MARK: - Live Activity view

/// Compact Live Activity content for `LiveActivity.fanAlert`.
struct FanControlAlertView: View {

    enum Part { case leading, trailing, full }

    var part: Part = .full

    @Default(.fanControlWidgetSettings) private var settings

    private var coordinator: FanControlAlertCoordinator { FanControlAlertCoordinator.shared }
    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        HStack(spacing: 6) {
            if part != .trailing {
                Image(systemName: coordinator.currentAlert == .fanStopped ? "exclamationmark.triangle.fill" : "fan.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: coordinator.currentAlert != nil)
            }
            if part != .leading {
                if let hottest = manager.hottestSensor {
                    Text(verbatim: FanControlFormatting.temperature(hottest, unit: settings.temperatureUnit))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
                title
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder private var title: some View {
        switch coordinator.currentAlert {
        case .fanStopped: Text("Fan stopped")
        case .highTemperature: Text("High temperature")
        case nil: EmptyView()
        }
    }
}
#endif
