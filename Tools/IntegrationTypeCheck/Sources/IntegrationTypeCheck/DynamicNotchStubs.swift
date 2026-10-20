// Type-check scaffolding only. NOT shipped, NOT a drop-in file.
//
// This module plays the host app: it compiles the drop-in files (symlinks), the host's own
// settings store (`HostSettingsStore.swift`, a symlink to FanControlUI's internal
// Storage/SettingsStore.swift — DynamicNotchApp compiles the same file as
// Sources/Support/SettingsStorage.swift) and this file.
//
// Part 1 declares the minimal DynamicNotch-side symbols that the PATCHES.md
// snippets need, modelled on DynamicNotchApp/. The drop-in files themselves
// reference none of these symbols (only in comments), so they compile without any stub.
//
// Part 2 transcribes the code from DynamicNotchIntegration/PATCHES.md (a)–(f) and the app glue
// (DynamicNotchApp/Sources/Support/FanControl-Patches.swift) against those stubs, so the
// snippets are type-checked against the real FanControlUI / SwiftUI APIs. Keep it in sync
// with PATCHES.md by hand.

import SwiftUI
import AppKit
import FanControlCore
import FanControlKit
import FanControlUI

// MARK: - Part 1: DynamicNotch stubs

/// DynamicNotchApp/Sources/Support/SharedDeclarations.swift: every settings struct conforms to
/// `Preferences` (the host store's `CodableStoredValue` + a bare `init()`).
protocol Preferences: CodableStoredValue, Hashable {
    init()
}

/// host app *WidgetSettings.swift: `DynamicNotch.WidgetPrefs`. NookSettings.swift reads
/// `widget.prefs.gridSizeType` (existential dispatch), which is the only requirement modelled here.
protocol WidgetPrefs {
    var gridSizeType: NookWidget.NookGridSizeType { get }
}

/// host app NookWidget.swift (tags 0–7 abridged to one existing case + the new one).
enum NookWidget: String, CaseIterable, Codable, Hashable, Identifiable {
    case timer
    case fanControl            // PATCHES.md (a)
    case temperature           // PATCHES.md (a-2)

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

// App glue (FanControl-Patches.swift): the host store's typed keys for the Fan Control settings
// the host reads itself (NookWidget, NotchView), named after FanControlUI's key names.
extension StoredKeys {
    static let fanControlWidgetSettings = Key<FanControlWidgetSettings>(
        FanControlSettingKey.widget.name, default: .init())
    static let fanControlTemperatureWidgetSettings = Key<FanControlTemperatureWidgetSettings>(
        FanControlSettingKey.temperatureWidget.name, default: .init())
}

// (a) NookWidget additions
extension NookWidget {
    var icon: String {
        switch self {
        case .timer: return "timer"
        case .fanControl: return "fan"
        case .temperature: return "thermometer.medium"
        }
    }

    var name: String {
        switch self {
        case .timer: return "Timer"
        case .fanControl: return "Fan Control"
        case .temperature: return "Temperature"
        }
    }

    var gridSizeType: NookGridSizeType {
        switch self {
        case .timer: return .small
        case .fanControl:
            return SettingsStore[.fanControlWidgetSettings].gridSize == .doubleWide ? .doubleWide : .medium
        case .temperature: return .doubleWide
        }
    }

    var prefs: WidgetPrefs {
        switch self {
        case .timer: return SettingsStore[.fanControlWidgetSettings] // placeholder for TimerWidgetSettingsKey()
        case .fanControl: return SettingsStore[.fanControlWidgetSettings]
        case .temperature: return SettingsStore[.fanControlTemperatureWidgetSettings]
        }
    }
}

extension FanControlWidgetSettings: Preferences, WidgetPrefs {
    init() { self.init(gridSize: .medium) }

    var gridSizeType: NookWidget.NookGridSizeType {
        gridSize == .doubleWide ? .doubleWide : .medium
    }
}

extension FanControlTemperatureWidgetSettings: Preferences, WidgetPrefs {
    init() { self.init(historyWindow: .fiveMinutes) }

    var gridSizeType: NookWidget.NookGridSizeType { .doubleWide }
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
        case .temperature: FanControlTemperatureWidgetView()
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
        case .temperature: FanControlTemperatureWidgetSettingsView()
        }
    }
}

// (d) Fan Control tab in the host's native SwiftUI `Settings` scene.
// Host side (DynamicNotchApp/Sources/SettingsRootView.swift), stubbed minimally:
enum AppSettings {
    struct PaneIdentifier: Hashable, RawRepresentable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        init(_ rawValue: String) { self.rawValue = rawValue }
    }
}

// PATCHES.md (d):
extension AppSettings.PaneIdentifier {
    static let fanControl = Self("fanControl")
}

struct _PatchD_SettingsRootView: View {
    @State private var selection = AppSettings.PaneIdentifier("general")

    var body: some View {
        TabView(selection: $selection) {
            // … existing tabs …
            FanControlSettingsView()
                .frame(width: 760, height: 640, alignment: .top)
                .tabItem { Label("Fan Control", systemImage: "fan") }
                .tag(AppSettings.PaneIdentifier.fanControl)
            // … About …
        }
    }
}

// The scene the host declares in its `App` (no name clash: SwiftUI's `Settings` is the only one).
struct _PatchD_App {
    @SceneBuilder var body: some Scene {
        Settings { _PatchD_SettingsRootView() }
    }
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
        let fanSettings = FanControlSettingKey.general.value
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

// (b-2) Nook open / close hook
@MainActor func _PatchB2_nookStateChanged(isNookOpen: Bool) {
    FanControlNookVisibility.nookVisibilityChanged(isVisible: isNookOpen)
}

// Host-side reads through its own store and through FanControlUI agree on the key names.
private let _hostKeyNamesMatch: Bool =
    StoredKeys.fanControlWidgetSettings.name == FanControlSettingKey.widget.name
    && StoredKeys.fanControlTemperatureWidgetSettings.name == FanControlSettingKey.temperatureWidget.name
