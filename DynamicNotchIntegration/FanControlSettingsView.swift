#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The "Fan Control" settings pane (design doc §4.3), registered as a
// `Settings.Pane` (see PATCHES.md (d)). Mirrors `LiveActivitiesSettingsView`:
// a `TabView` with General / Profiles / Sensors tabs, plus an error footer.
//
// The pane has ONE fixed size for every tab (`contentSize`), so switching tabs
// never resizes the settings window; tab contents that can grow (General's
// sections, the profile editor, the sensor table) scroll inside it. The host
// app wraps the pane in a slightly larger fixed frame (DynamicNotchApp: 760×640,
// `settingsPaneSize` in WindowsManager.swift).

import SwiftUI
import FanControlCore
import FanControlKit

struct FanControlSettingsView: View {

    /// Fixed size of the whole pane (tabs + error footer), identical for every tab.
    static let contentSize = CGSize(width: 740, height: 600)

    @State private var selection: Int = 0
    /// Error from the last action started in this pane (thrown by the manager).
    @State private var actionError: String?

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selection) {
                FanControlGeneralTabView(actionError: $actionError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Text("General") }
                    .tag(0)

                FanControlProfilesTabView(actionError: $actionError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Text("Profiles") }
                    .tag(1)

                FanControlSensorsTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Text("Sensors") }
                    .tag(2)
            }

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
    }
}

/// Shows the most recent error, if any.
struct FanControlErrorFooter: View {
    let message: String?
    let dismiss: () -> Void

    var body: some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer()
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Runs an async manager call (on the main actor) from a button or binding
/// setter and reports failures to `errorMessage`.
func fanControlPerform(_ errorMessage: Binding<String?>, _ operation: @escaping @MainActor () async throws -> Void) {
    Task { @MainActor in
        do {
            try await operation()
            errorMessage.wrappedValue = nil
        } catch {
            errorMessage.wrappedValue = fanControlErrorMessage(error)
        }
    }
}

/// User-facing text for an error thrown by `FanControlManager`.
///
/// `installHelper()` (also reached through `applyProfile`, `setFanRPM`, ...)
/// throws `.helperNotInstalled` while the daemon is waiting for approval in
/// Login Items; that case carries no message of its own, so the localized
/// approval instructions are shown instead (Kit's English equivalent is
/// `FanControlManager.helperApprovalInstructions`). Call on the main thread
/// (`helperStatus` is main-thread state; the manager updates it before throwing).
@MainActor
func fanControlErrorMessage(_ error: Error) -> String {
    if let fanError = error as? FanControlError, fanError == .helperNotInstalled,
       FanControlManager.shared.helperStatus == .requiresApproval {
        return String(localized: "Allow “DynamicNotch” in System Settings ▸ General ▸ Login Items & Extensions (macOS 15) / Login Items (macOS 14) to let it change fan speeds.")
    }
    if let fanError = error as? FanControlError, case .helperConnectionRejected = fanError {
        // Sticky rejection (HelperClient does not retry on its own): localized remedy.
        if case .rejected(let reason) = FanControlManager.shared.helperConnectionState {
            return fanControlRejectionHelp(reason)
        }
        return fanControlRejectionHelp(.clientNotPinned(pinnedCDHash: "", appCDHash: ""))
    }
    return error.localizedDescription
}

/// Localized explanation and remedy for a helper rejection
/// (`HelperConnectionState.rejected(reason:)` / `HelperInstallStatus.installedManuallyMismatch`).
@MainActor
func fanControlRejectionHelp(_ reason: HelperRejectionReason) -> String {
    switch reason {
    case .clientNotPinned, .droppedByHelper:
        return String(localized: "The installed helper is pinned to a different build of DynamicNotch and refuses this app. Re-run sudo install.sh with this app (FanControl/Support/manual-install/), then click Check Again.")
    case .helperSignatureMismatch:
        return String(localized: "The installed helper’s code signature does not match what DynamicNotch expects. Re-run sudo install.sh with this app (FanControl/Support/manual-install/), then click Check Again.")
    }
}
#endif
