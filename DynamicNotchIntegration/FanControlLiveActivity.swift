#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Fan Control Live Activity (design doc §4.2): a compact alert shown around the
// notch while the high-temperature or fan-stopped alert is active (and for a few
// seconds when another fan control app such as FanFi is detected), plus the
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
import FanControlCore
import FanControlKit

// MARK: - Alert kind

enum FanControlAlertKind: Equatable, Hashable {
    /// The hottest CPU/GPU sensor crossed `SafetyPolicy.highTemperatureAlert`.
    case highTemperature
    /// At least one fan reports 0 RPM while a non-zero target is set.
    case fanStopped
    /// Another fan control app (FanFi) started running (`conflictingControllers`,
    /// design doc §5.2). Shown once per detection for `conflictAlertDuration`, not
    /// again until the conflict has cleared.
    case conflictingController
}

// MARK: - Coordinator

/// Observes `FanControlManager` alert notifications, applies the user's alert
/// toggles and exposes the alert to show.
///
/// It is also the single place that mirrors the SettingsStore-backed
/// `FanControlGeneralSettings` into the manager (FanControlKit does not depend
/// on the app settings store): `pollingInterval`, `slowPollingOnBattery`, `reapplyProfileAfterWake`
/// and `keepAlertsWhilePaused` (= any alert toggle on) are copied at creation and
/// on every settings change, and so are the temperature thresholds
/// (`FanControlThresholdSettings` → `manager.applySafetyThresholds`). The wake re-apply itself is done by
/// `FanControlManager` (5 s after wake, only while a write session is open).
@MainActor
@Observable
final class FanControlAlertCoordinator {

    static let shared = FanControlAlertCoordinator()

    /// Posted (main queue, `object: nil`) when an alert starts.
    nonisolated static let transientNotificationName = Notification.Name("DynamicNotchFanAlertTransient")

    /// How long the conflicting-controller alert stays (seconds).
    nonisolated static let conflictAlertDuration: TimeInterval = 8

    /// The alert currently shown, or `nil`. A stopped fan wins over high
    /// temperature, which wins over a conflicting controller.
    private(set) var currentAlert: FanControlAlertKind? = nil

    /// Called on the main thread whenever `currentAlert` changes. Used to insert or
    /// remove `LiveActivity.fanAlert` in `ActiveLiveActivitiesManager`.
    @ObservationIgnored var onAlertChange: ((FanControlAlertKind?) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var thresholdsTask: Task<Void, Never>?
    /// The conflict alert is being shown (`conflictAlertDuration`).
    @ObservationIgnored private var conflictAlertVisible = false
    /// The current detection was announced already (reset when it clears).
    @ObservationIgnored private var conflictAnnounced = false
    @ObservationIgnored private var conflictHideTask: Task<Void, Never>?

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.fanControlHighTemperatureChanged, .fanControlFanAnomalyChanged] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
            observers.append(token)
        }
        let conflictToken = center.addObserver(forName: .fanControlConflictingControllersChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.conflictingControllersChanged() }
        }
        observers.append(conflictToken)

        // Alert toggles, master switch, polling interval or wake option changed in Settings.
        settingsTask = Task { [weak self] in
            for await _ in SettingsStore.updates(.fanControlGeneralSettings, initial: false) {
                self?.syncManagerSettings()
                self?.reevaluate()
            }
        }
        // Temperature thresholds changed in Settings (General tab, design doc §5.6).
        thresholdsTask = Task { [weak self] in
            for await _ in SettingsStore.updates(.fanControlThresholdSettings, initial: false) {
                self?.syncManagerSettings()
            }
        }

        syncManagerSettings()
        reevaluate()
    }

    /// Copies the manager-relevant general settings into `FanControlManager`.
    /// `pollingInterval` and `keepAlertsWhilePaused` are only assigned when they
    /// changed, because assigning them may reschedule the poll timer.
    func syncManagerSettings() {
        let general = SettingsStore[.fanControlGeneralSettings]
        let manager = FanControlManager.shared
        if manager.pollingInterval != general.pollingInterval {
            manager.pollingInterval = general.pollingInterval
        }
        if manager.slowPollingOnBattery != general.slowPollingOnBattery {
            manager.slowPollingOnBattery = general.slowPollingOnBattery
        }
        manager.reapplyProfileAfterWake = general.reapplyProfileAfterWake
        // Keep a slow poll while the Nook is hidden only if some alert can fire.
        let keepAlerts = general.highTemperatureAlertEnabled || general.fanAnomalyAlertEnabled
        if manager.keepAlertsWhilePaused != keepAlerts {
            manager.keepAlertsWhilePaused = keepAlerts
        }
        // "Pause When Nook Is Hidden" turned off (or the feature disabled) while
        // paused: nothing else would clear the pause until the Nook opens again.
        if !(general.isEnabled && general.pauseWhenNookHidden) && manager.isMonitoringPaused {
            manager.setMonitoringPaused(false)
        }
        // Alert / emergency / hysteresis (FanControlThresholdSettings, clamped by
        // ThresholdBounds). `emergencySensorPrefixes` and `enforceHardwareMinimum`
        // are left as they are. A change is evaluated by the next poll; poll now
        // so the alert and the emergency override follow without waiting.
        let thresholds = SettingsStore[.fanControlThresholdSettings].thresholds
        if manager.safetyPolicy.thresholds != ThresholdBounds.clamped(thresholds) {
            manager.applySafetyThresholds(thresholds)
            if manager.isMonitoring { manager.refreshNow() }
        }
    }

    /// Recomputes `currentAlert` from the manager state and the alert settings.
    func reevaluate() {
        let general = SettingsStore[.fanControlGeneralSettings]
        let manager = FanControlManager.shared

        let alert: FanControlAlertKind?
        if general.isEnabled, general.fanAnomalyAlertEnabled, !manager.anomalousFanIDs.isEmpty {
            alert = .fanStopped
        } else if general.isEnabled, general.highTemperatureAlertEnabled, manager.highTempAlertActive {
            alert = .highTemperature
        } else if general.isEnabled, conflictAlertVisible, !manager.conflictingControllers.isEmpty {
            alert = .conflictingController
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

extension FanControlAlertCoordinator {
    /// Shows the conflict alert once per detection (`conflictAlertDuration`); a
    /// cleared conflict re-arms it.
    fileprivate func conflictingControllersChanged() {
        let manager = FanControlManager.shared
        if manager.conflictingControllers.isEmpty {
            conflictAnnounced = false
            conflictAlertVisible = false
            conflictHideTask?.cancel()
            conflictHideTask = nil
        } else if !conflictAnnounced, SettingsStore[.fanControlGeneralSettings].isEnabled {
            conflictAnnounced = true
            conflictAlertVisible = true
            conflictHideTask?.cancel()
            conflictHideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.conflictAlertDuration))
                guard !Task.isCancelled, let self else { return }
                self.conflictAlertVisible = false
                self.reevaluate()
            }
        }
        reevaluate()
    }
}

// MARK: - Live Activity view

/// Compact Live Activity content for `LiveActivity.fanAlert`.
struct FanControlAlertView: View {

    enum Part { case leading, trailing, full }

    var part: Part = .full

    @StoredSetting(.fanControlWidgetSettings) private var settings

    private var coordinator: FanControlAlertCoordinator { FanControlAlertCoordinator.shared }
    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        HStack(spacing: 6) {
            if part != .trailing {
                Image(systemName: coordinator.currentAlert == .highTemperature ? "fan.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(coordinator.currentAlert == .conflictingController ? .orange : .red)
                    .symbolEffect(.pulse, isActive: coordinator.currentAlert != nil)
            }
            if part != .leading {
                if coordinator.currentAlert != .conflictingController, let hottest = manager.hottestSensor {
                    Text(verbatim: FanControlFormatting.temperature(hottest, unit: settings.temperatureUnit))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .help(Text(verbatim: "\(FanControlSensorNames.localized(hottest)) (\(hottest.id))"))
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
        case .conflictingController:
            Text("\(manager.conflictingControllers.formatted(.list(type: .and))) is running")
        case nil: EmptyView()
        }
    }
}
#endif
