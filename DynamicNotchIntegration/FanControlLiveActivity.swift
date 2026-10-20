#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package): host-specific
// glue on top of FanControlUI.
//
// Fan Control Live Activity (design doc §4.2): a compact alert shown around the
// notch while the high-temperature or fan-stopped alert is active (and for a few
// seconds when another fan control app such as FanFi is detected). The alert state and its
// transient "flash" (mirroring PowerMonitor's low-battery transient,
// `DynamicNotchBatteryLowTransient`) come from FanControlUI's `FanControlAlertCoordinator`.
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
import FanControlUI

// MARK: - Live Activity view

/// Compact Live Activity content for `LiveActivity.fanAlert`.
struct FanControlAlertView: View {

    enum Part { case leading, trailing, full }

    var part: Part = .full

    @FanControlSetting(.widget) private var settings

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
