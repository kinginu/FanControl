/// Registration state of the FanControlHelper launch daemon
/// (mirrors `SMAppService.Status`).
public enum HelperInstallStatus: Equatable, Sendable {
    case notRegistered
    case enabled
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

/// Thin wrapper over `SMAppService.daemon(plistName:)` for the FanControlHelper daemon.
///
/// Only the plist name is stored (the `SMAppService` object is created on
/// demand) so the struct is trivially `Sendable`.
public struct HelperInstaller: Sendable {
    public let plistName: String

    public init(plistName: String = FanControlHelperConstants.plistName) {
        self.plistName = plistName
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// Current registration status.
    public func status() -> HelperInstallStatus {
        Self.map(service.status)
    }

    /// Registers the daemon and returns the status read afterwards.
    ///
    /// `register()` throws in two situations that are not real failures; both
    /// are detected by re-reading the status:
    /// - the user still has to approve the daemon (status `.requiresApproval`),
    /// - it is already registered (status `.enabled`).
    /// Any other error is rethrown as `FanControlError.helperConnectionFailed`
    /// carrying the `NSError` description.
    @discardableResult
    public func register() throws -> HelperInstallStatus {
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

    /// Unregisters the daemon (launchd stops it).
    public func unregister() async throws {
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
