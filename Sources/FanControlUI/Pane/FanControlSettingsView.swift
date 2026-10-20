#if os(macOS)
// The "Fan Control" settings pane (design doc §4.3), meant as one tab of the
// host's native SwiftUI `Settings` scene (DynamicNotch: PATCHES.md (d)). General /
// Profiles / Sensors sub-tabs as a segmented control (a nested `TabView` would
// be hoisted into the Settings window's toolbar), plus an error footer.
//
// The pane has ONE fixed size for every tab (`contentSize`), so switching tabs
// never resizes the settings window; tab contents that can grow (General's
// grouped form, the profile editor, the sensor table) scroll inside it. The host
// app wraps every settings tab in a slightly larger fixed frame (DynamicNotchApp:
// 760×640, `SettingsRootView.contentSize` in Sources/SettingsRootView.swift).

import SwiftUI
import FanControlCore
import FanControlKit

public struct FanControlSettingsView: View {

    /// Fixed size of the whole pane (tabs + error footer), identical for every tab.
    public static let contentSize = CGSize(width: 740, height: 600)

    /// Selected sub-tab, remembered across openings (like the top-level tab).
    @AppStorage("fanControlSettingsTab") private var selection: Int = 0
    /// Error from the last action started in this pane (thrown by the manager).
    @State private var actionError: String?

    private var manager: FanControlManager { FanControlManager.shared }

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            // Sub-tabs as a segmented control, not a nested `TabView`: inside SwiftUI's
            // `Settings` scene every `TabView` is hoisted into the window toolbar.
            Picker("", selection: $selection) {
                Text("General").tag(0)
                Text("Profiles").tag(1)
                Text("Sensors").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch selection {
                case 1: FanControlProfilesTabView(actionError: $actionError)
                case 2: FanControlSensorsTabView()
                default: FanControlGeneralTabView(actionError: $actionError)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            FanControlErrorFooter(message: actionError ?? manager.lastError.map { fanControlErrorMessage($0) }) {
                actionError = nil
                manager.clearLastError()
            }
        }
        .padding(.all)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .task {
            manager.refreshHelperStatus()
        }
        // Live data while the pane is open, even with the Nook hidden ("Pause When
        // Nook Is Hidden"): a hold suspends the pause without changing the host's
        // request, so closing the pane returns to whatever the Nook state asks for.
        .onAppear { manager.setLiveDataHold(true, for: Self.liveDataHolder) }
        .onDisappear { manager.setLiveDataHold(false, for: Self.liveDataHolder) }
    }

    private static let liveDataHolder = "FanControlSettingsView"
}
#endif
