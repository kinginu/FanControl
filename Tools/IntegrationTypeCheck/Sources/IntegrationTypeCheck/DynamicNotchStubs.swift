// Type-check scaffolding only. NOT shipped, NOT a drop-in file.
//
// Part 1 declares the minimal DynamicNotch-side symbols that the PATCHES.md
// snippets need, modelled on the host app.
// The 8 drop-in files themselves reference none of these symbols (only in
// comments), so they compile without any stub.
//
// Part 2 transcribes the code from DynamicNotchIntegration/PATCHES.md (a)(c)(d)(e)(f)
// against those stubs, so the snippets are type-checked against the real
// Defaults / Settings / SwiftUI APIs. Keep it in sync with PATCHES.md by hand.

import SwiftUI
import AppKit
import Defaults
@preconcurrency import Settings   // PATCHES.md (d): needed for `static let fanControl` in Swift 6 mode
import enum Settings.Settings
import FanControlCore
import FanControlKit

// MARK: - Part 1: DynamicNotch stubs

/// host app *Settings.swift: every settings struct conforms to `DynamicNotch.Preferences`.
/// Requirements are unknown (not visible from the host sources); modelled as the conformances all
/// settings structs share. NB: sindresorhus/Settings also exports `typealias Preferences = Settings`;
/// the app module's own protocol shadows it.
protocol Preferences: Defaults.Serializable, Codable, Equatable, Hashable {}

/// host app *WidgetSettings.swift: `DynamicNotch.WidgetPrefs`. NookSettings.swift reads
/// `widget.prefs.gridSizeType` (existential dispatch), which is the only requirement modelled here.
protocol WidgetPrefs {
    var gridSizeType: NookWidget.NookGridSizeType { get }
}

/// host app NookWidget.swift (tags 0–7 abridged to one existing case + the new one).
enum NookWidget: String, CaseIterable, Codable, Hashable, Identifiable {
    case timer
    case fanControl            // PATCHES.md (a)

    var id: String { rawValue }

    /// host app NookWidget.swift: tags small = 0, medium = 2, doubleWide = 5.
    enum NookGridSizeType: Int, Equatable, Hashable, CaseIterable {
        case small = 0
        case medium = 2
        case doubleWide = 5
    }
}

/// host app LiveActivity.swift (abridged).
enum LiveActivity: String, CaseIterable, Codable, Hashable, Identifiable {
    case battery = "batteryStatus"
    case fanAlert              // PATCHES.md (f)

    var id: String { rawValue }
}

/// host app ActiveLiveActivitiesManager.swift (`Observation.Observable`, not MainActor-annotated
/// in the host app).
@Observable
final class ActiveLiveActivitiesManager {
    private(set) var activeLiveActivities: Set<LiveActivity> = []
    func insertSync(_ activity: LiveActivity) { activeLiveActivities.insert(activity) }
    func removeSync(_ activity: LiveActivity) { activeLiveActivities.remove(activity) }
}

/// host app BlankView.swift.
struct BlankView: View { var body: some View { EmptyView() } }

/// host app TimerWidgetView.swift / TimerWidgetSettingsView.swift (placeholders for the existing switch arms).
struct TimerWidgetView: View { var body: some View { EmptyView() } }
struct TimerWidgetSettingsView: View { var body: some View { EmptyView() } }

// MARK: - Part 2: PATCHES.md snippets

// (a) NookWidget additions
extension NookWidget {
    var icon: String {
        switch self {
        case .timer: return "timer"
        case .fanControl: return "fan"
        }
    }

    var name: String {
        switch self {
        case .timer: return "Timer"
        case .fanControl: return "Fan Control"
        }
    }

    var gridSizeType: NookGridSizeType {
        switch self {
        case .timer: return .small
        case .fanControl:
            return Defaults[.fanControlWidgetSettings].gridSize == .doubleWide ? .doubleWide : .medium
        }
    }

    var prefs: WidgetPrefs {
        switch self {
        case .timer: return Defaults[.fanControlWidgetSettings] // placeholder for TimerWidgetSettingsKey()
        case .fanControl: return Defaults[.fanControlWidgetSettings]
        }
    }
}

extension FanControlWidgetSettings: Preferences, WidgetPrefs {
    var gridSizeType: NookWidget.NookGridSizeType {
        gridSize == .doubleWide ? .doubleWide : .medium
    }
}

/// `NookGridSizeType` raw values must match `GridSizeChoice` (PATCHES.md (a)).
private let _gridSizeRawValuesMatch: Bool =
    FanControlWidgetSettings.GridSizeChoice.medium.rawValue == NookWidget.NookGridSizeType.medium.rawValue
    && FanControlWidgetSettings.GridSizeChoice.doubleWide.rawValue == NookWidget.NookGridSizeType.doubleWide.rawValue

// (b) widget → view dispatch
struct _PatchB_WidgetDispatch: View {
    let widget: NookWidget
    var body: some View {
        switch widget {
        case .timer: TimerWidgetView()
        case .fanControl: FanControlWidgetView()
        }
    }
}

// (c) per-widget settings
struct _PatchC_WidgetSettingsDispatch: View {
    let widget: NookWidget
    var body: some View {
        switch widget {
        case .timer: TimerWidgetSettingsView()
        case .fanControl: FanControlWidgetSettingsView()
        }
    }
}

// (d) settings pane registration
extension Settings.PaneIdentifier {
    static let fanControl = Self("fanControl")
}

@MainActor
func FanControlSettingsPaneController() -> SettingsPane {
    let pane = Settings.Pane(
        identifier: .fanControl,
        title: String(localized: "Fan Control"),
        toolbarIcon: NSImage(systemSymbolName: "fan", accessibilityDescription: String(localized: "Fan Control"))!
    ) {
        FanControlSettingsView()
    }
    return Settings.PaneHostingController(pane: pane)
}

@MainActor
func _patchD_makeWindowController() -> SettingsWindowController {
    SettingsWindowController(panes: [FanControlSettingsPaneController()])
}

// (e) AppDelegate.applicationDidFinishLaunching
final class _PatchE_AppDelegate: NSObject, NSApplicationDelegate {
    let activeLiveActivitiesManager = ActiveLiveActivitiesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let activeLiveActivitiesManager = self.activeLiveActivitiesManager
        FanControlAlertCoordinator.shared.onAlertChange = { alert in
            if alert != nil {
                activeLiveActivitiesManager.insertSync(.fanAlert)
            } else {
                activeLiveActivitiesManager.removeSync(.fanAlert)
            }
        }
        let fanSettings = Defaults[.fanControlGeneralSettings]
        if fanSettings.isEnabled && fanSettings.autoStartMonitoring {
            FanControlManager.shared.startMonitoring()
        }
        _ = NotificationCenter.default.addObserver(
            forName: FanControlAlertCoordinator.transientNotificationName, object: nil, queue: .main
        ) { _ in }
    }
}

// (f) LiveActivityView arms
struct _PatchF_LiveActivityView: View {
    let activity: LiveActivity
    var body: some View {
        switch activity {
        case .fanAlert:
            HStack {
                FanControlAlertView(part: .leading)
                FanControlAlertView(part: .trailing)
                FanControlAlertView()
            }
        case .battery: EmptyView()
        }
    }
}
