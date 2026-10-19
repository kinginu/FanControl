#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The "Fan Control" settings pane (design doc §4.3), registered as a
// `Settings.Pane` (see PATCHES.md (d)). Mirrors `LiveActivitiesSettingsView`:
// a `TabView` with General / Profiles / Sensors tabs, plus an error footer.

import SwiftUI
import FanControlCore
import FanControlKit

struct FanControlSettingsView: View {

    @State private var selection: Int = 0
    /// Error from the last action started in this pane (thrown by the manager).
    @State private var actionError: String?

    private var manager: FanControlManager { FanControlManager.shared }

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selection) {
                FanControlGeneralTabView(actionError: $actionError)
                    .tabItem { Text("General") }
                    .tag(0)

                FanControlProfilesTabView(actionError: $actionError)
                    .tabItem { Text("Profiles") }
                    .tag(1)

                FanControlSensorsTabView()
                    .tabItem { Text("Sensors") }
                    .tag(2)
            }

            FanControlErrorFooter(message: actionError ?? manager.lastError.map { fanControlErrorMessage($0) }) {
                actionError = nil
                manager.clearLastError()
            }
        }
        .padding(.all)
        .frame(idealHeight: 544)
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
    return error.localizedDescription
}
#endif
