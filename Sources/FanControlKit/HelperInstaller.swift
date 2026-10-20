/// Registration state of the FanControlHelper launch daemon
/// (mirrors `SMAppService.Status`, plus `installedManually`).
public enum HelperInstallStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    /// Installed by `Support/manual-install/install.sh` as a plain LaunchDaemon
    /// (manual / personal mode, ad-hoc signing): both
    /// `FanControlHelperConstants.manualLaunchDaemonPlistPath` and
    /// `manualHelperPath` exist. Treated as installed; `register()` is a no-op and
    /// `unregister()` refuses (use `uninstall.sh`).
    case installedManually
    /// Registered, but the user must enable it in System Settings > General >
    /// Login Items & Extensions (macOS 15) / Login Items (macOS 14).
    case requiresApproval
    /// The plist is not in `Contents/Library/LaunchDaemons/` of the app bundle.
    case notFound
    case unknown(String)
}

#if os(macOS)
import Foundation
import ServiceManagement
import FanControlCore
import FanControlXPC

/// Thin wrapper over `SMAppService.daemon(plistName:)` for the FanControlHelper daemon,
/// aware of the manual installation made by `Support/manual-install/install.sh`.
///
/// Only the plist name and a file-existence probe are stored (the `SMAppService`
/// object is created on demand) so the struct is trivially `Sendable`.
///
/// A manual installation takes precedence over `SMAppService`: both use the same
/// launchd label and Mach service name, so they must never coexist; while the
/// manual files exist `register()` does not touch `SMAppService`.
public struct HelperInstaller: Sendable {
    public let plistName: String
    private let fileExists: @Sendable (String) -> Bool

    /// - Parameter fileExists: probe for the manual-install files (injectable for tests).
    public init(plistName: String = FanControlHelperConstants.plistName,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.plistName = plistName
        self.fileExists = fileExists
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// Presence of `/Library/LaunchDaemons/<label>.plist` and
    /// `/Library/PrivilegedHelperTools/<label>` (read-only file checks, no root needed).
    public var manualInstallState: ManualInstallState {
        FanControlHelperConstants.manualInstallState(
            plistExists: fileExists(FanControlHelperConstants.manualLaunchDaemonPlistPath),
            helperExists: fileExists(FanControlHelperConstants.manualHelperPath))
    }

    /// cdhash of the manually installed helper (`manualHelperPath`), as pinned by
    /// `HelperClient` in manual mode. Throws if the file is missing, not root-owned or
    /// not validly signed. For diagnostics UI.
    public static func installedManualHelperCDHash() throws -> String {
        try ManualHelperSigning.installedHelperCDHash()
    }

    /// Team identifier of the running app's signature (`nil` for ad-hoc builds,
    /// which therefore always use manual mode).
    public static var appTeamIdentifier: String? { ManualHelperSigning.ownTeamIdentifier }

    /// Current registration status (`.installedManually` if the manual files exist).
    public func status() -> HelperInstallStatus {
        Self.resolveStatus(manual: manualInstallState, serviceStatus: Self.map(service.status))
    }

    /// Status decision: a complete manual installation wins, an incomplete one is
    /// reported as `.unknown` with instructions, otherwise the `SMAppService` status
    /// (evaluated only in that case).
    static func resolveStatus(manual: ManualInstallState,
                              serviceStatus: @autoclosure () -> HelperInstallStatus) -> HelperInstallStatus {
        switch manual {
        case .installed:
            return .installedManually
        case .incomplete(let missing):
            return .unknown(Self.incompleteManualInstallMessage(missing: missing))
        case .absent:
            return serviceStatus()
        }
    }

    static func incompleteManualInstallMessage(missing: String) -> String {
        "manual installation incomplete (\(missing) is missing); re-run sudo \(FanControlHelperConstants.manualInstallScriptName) or \(FanControlHelperConstants.manualUninstallScriptName)"
    }

    /// Registers the daemon and returns the status read afterwards.
    ///
    /// `register()` throws in two situations that are not real failures; both
    /// are detected by re-reading the status:
    /// - the user still has to approve the daemon (status `.requiresApproval`),
    /// - it is already registered (status `.enabled`).
    /// Any other error is rethrown as `FanControlError.helperConnectionFailed`
    /// carrying the `NSError` description.
    ///
    /// Manual installation: returns `.installedManually` without touching
    /// `SMAppService`; an incomplete one throws (`.helperConnectionFailed`).
    @discardableResult
    public func register() throws -> HelperInstallStatus {
        switch manualInstallState {
        case .installed:
            return .installedManually
        case .incomplete(let missing):
            throw FanControlError.helperConnectionFailed(Self.incompleteManualInstallMessage(missing: missing))
        case .absent:
            break
        }
        let service = self.service
        do {
            try service.register()
        } catch {
            let after = Self.map(service.status)
            if after == .requiresApproval || after == .enabled {
                return after
            }
            let nsError = error as NSError
            throw FanControlError.helperConnectionFailed(
                "SMAppService.register failed: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
        return Self.map(service.status)
    }

    /// Unregisters the daemon (launchd stops it). Refuses a manual installation
    /// (only root can remove it: `sudo uninstall.sh`).
    public func unregister() async throws {
        if manualInstallState != .absent {
            throw FanControlError.helperConnectionFailed(
                "The helper was installed manually; remove it with sudo \(FanControlHelperConstants.manualUninstallScriptName) (FanControl/Support/manual-install/).")
        }
        do {
            try await service.unregister()
        } catch {
            let nsError = error as NSError
            throw FanControlError.helperConnectionFailed(
                "SMAppService.unregister failed: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
    }

    /// Opens System Settings > General > Login Items & Extensions (macOS 15) /
    /// Login Items (macOS 14), where the daemon is approved.
    public static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func map(_ status: SMAppService.Status) -> HelperInstallStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown("SMAppService.Status(rawValue: \(status.rawValue))")
        }
    }
}
#endif
