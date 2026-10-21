#if os(macOS)
// Error presentation shared by the Fan Control views: the pane's footer, the async action
// runner and the user-facing text for `FanControlManager` errors.

import SwiftUI
import FanControlCore
import FanControlKit

/// Shows the most recent error, if any.
public struct FanControlErrorFooter: View {
    let message: String?
    let dismiss: () -> Void

    public init(message: String?, dismiss: @escaping () -> Void) {
        self.message = message
        self.dismiss = dismiss
    }

    public var body: some View {
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
public func fanControlPerform(_ errorMessage: Binding<String?>, _ operation: @escaping @MainActor () async throws -> Void) {
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
public func fanControlErrorMessage(_ error: Error) -> String {
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
public func fanControlRejectionHelp(_ reason: HelperRejectionReason) -> String {
    // With a host installer (FanControlHostActions) the remedy is a button in the same section.
    let hostInstalls = FanControlHostActions.providesHelperInstaller
    switch reason {
    case .clientNotPinned, .droppedByHelper:
        if hostInstalls {
            return String(localized: "The installed helper is pinned to a different build of DynamicNotch and refuses this app. Click Install Helper… to install it for this build.")
        }
        return String(localized: "The installed helper is pinned to a different build of DynamicNotch and refuses this app. Re-run sudo install.sh with this app (FanControl/Support/manual-install/), then click Check Again.")
    case .helperSignatureMismatch:
        if hostInstalls {
            return String(localized: "The installed helper’s code signature does not match what DynamicNotch expects. Click Install Helper… to install the helper of this build.")
        }
        return String(localized: "The installed helper’s code signature does not match what DynamicNotch expects. Re-run sudo install.sh with this app (FanControl/Support/manual-install/), then click Check Again.")
    }
}
#endif
