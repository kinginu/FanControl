#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package): host-specific
// glue on top of FanControlUI.
//
// "Pause When Nook Is Hidden" (design doc §5.4 (c), PATCHES.md (b-2)): the host's Nook open /
// close hook (`FanControlNookVisibility`) and the widgets' appear / disappear fallback
// (`FanControlWidgetPresence`, used by the Fan Control and Temperature widgets).

import Foundation
import FanControlCore
import FanControlKit
import FanControlUI

/// Host hook for "Pause When Nook Is Hidden" (design doc §5.4, PATCHES.md (b)):
/// call `nookVisibilityChanged(isVisible:)` from the host's Nook open / close
/// handling. Pausing is driven by the Nook itself, not by the Fan Control widget's
/// appear / disappear, so it also works when the widget is not in the grid and is
/// always cleared when the Nook opens again. Turning the setting off resumes
/// polling (`FanControlAlertCoordinator.syncManagerSettings`).
@MainActor
enum FanControlNookVisibility {
    static func nookVisibilityChanged(isVisible: Bool) {
        // The host reports Nook visibility; the widget's own appear/disappear becomes a fallback only.
        FanControlWidgetPresence.hostReportsVisibility = true
        let general = FanControlSettingKey.general.value
        FanControlManager.shared.setMonitoringPaused(!isVisible && general.isEnabled && general.pauseWhenNookHidden)
    }
}

// MARK: - Presence (pause fallback)

/// How many Fan Control widgets are on screen (one per screen whose Nook is open), and whether
/// the host reports Nook visibility itself. `hostReportsVisibility` is meant to be set by the
/// host hook (`FanControlNookVisibility.nookVisibilityChanged`, below —
/// one line: `FanControlWidgetPresence.hostReportsVisibility = true`); until then the widget's
/// fallback pause only fires when the last visible widget disappears.
/// Shared by the Fan Control and Temperature widgets (both need live readings).
@MainActor
enum FanControlWidgetPresence {
    static var visibleCount = 0
    static var hostReportsVisibility = false

    /// A Fan Control / Temperature widget appeared: count it and (when the feature is on) make
    /// sure monitoring runs and is not paused. With "Start Monitoring at Launch" off, monitoring
    /// starts the first time a widget is shown (design doc §5.5 (b)).
    static func widgetAppeared(isPreview: Bool) {
        if !isPreview { visibleCount += 1 }
        guard FanControlSettingKey.general.value.isEnabled else { return }
        let manager = FanControlManager.shared
        if !manager.isMonitoring {
            manager.startMonitoring()
        }
        manager.setMonitoringPaused(false)
    }

    /// Fallback only (PATCHES.md (b-2)): pausing is driven by the host's
    /// FanControlNookVisibility hook, which sees every screen's Nook. A widget's own disappear
    /// runs after that hook (the Nook content fades out), so it must never re-pause while a
    /// Fan Control / Temperature widget is still shown on another screen, and it stays out of
    /// the way once a host has reported Nook visibility.
    static func widgetDisappeared(isPreview: Bool) {
        guard !isPreview else { return }
        visibleCount = max(visibleCount - 1, 0)
        if FanControlSettingKey.general.value.pauseWhenNookHidden,
           !hostReportsVisibility,
           visibleCount == 0 {
            FanControlManager.shared.setMonitoringPaused(true)
        }
    }
}
#endif
