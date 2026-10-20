#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

// F2: Low Power Mode for power profiles. Writing needs root (the helper's dedicated
// `setLowPowerMode` request); reading does not (`ProcessInfo.isLowPowerModeEnabled`, and
// `pmset -g` for diagnostics).

/// Low Power Mode as `PowerProfileEngine` sees it (a fake in tests).
@MainActor
public protocol LowPowerModeControlling: AnyObject {
    /// The current state (read-back); `nil` if unknown.
    var isLowPowerModeEnabled: Bool? { get }
    /// Sets the state (helper request). Throws on failure.
    func setLowPowerMode(_ enabled: Bool) async throws
}

/// Unprivileged reads of the Low Power Mode state.
public enum LowPowerModeReader {
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled` (updated by the system;
    /// `NSProcessInfoPowerStateDidChange` is posted on changes).
    public static var processInfoState: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// `pmset -g` → `lowpowermode` (fixed argv, no shell, no root). Blocking: runs off the
    /// main actor. `nil` if pmset fails or prints no such line.
    @concurrent
    public static func pmsetState(runner: any CommandRunning = ProcessCommandRunner()) async -> Bool? {
        let result = runner.run(executable: LowPowerModeCommand.pmsetPath,
                                arguments: LowPowerModeCommand.readArguments, timeout: 10)
        guard result.status == 0 else { return nil }
        return LowPowerModeCommand.parseLowPowerMode(pmsetOutput: result.standardOutput)
    }
}

extension FanControlManager {
    // F2: Low Power Mode request (never installs or registers the helper by itself).
    /// Sets Low Power Mode through the helper (`pmset -a lowpowermode 0|1`).
    ///
    /// Requires an installed helper that speaks protocol `lowPowerModeProtocolVersion` or
    /// later; it does not register the helper (automation must not trigger approval prompts)
    /// and needs no write session. Errors are thrown, not recorded in `lastError`.
    public func setLowPowerMode(_ enabled: Bool) async throws {
        guard FanControlPlatform.isSupported else {
            throw FanControlError.unsupportedPlatform(FanControlPlatform.unsupportedPlatformDetail)
        }
        let status = helper.installer.status()
        guard status == .enabled || status.isManualInstallation else {
            throw FanControlError.helperNotInstalled
        }
        let (version, _) = try await helper.client.version()
        guard version >= FanControlHelperConstants.lowPowerModeProtocolVersion else {
            throw FanControlError.helperRejected(
                code: -1,
                message: "The installed helper (protocol \(version)) cannot change Low Power Mode; it needs protocol \(FanControlHelperConstants.lowPowerModeProtocolVersion). Re-run sudo \(FanControlHelperConstants.manualInstallScriptName) with this app.")
        }
        try await helper.client.setLowPowerMode(enabled)
        kitLog.notice("Low Power Mode set \(enabled ? "on" : "off", privacy: .public) through the helper")
    }
}

/// `LowPowerModeControlling` backed by `FanControlManager.setLowPowerMode` and `ProcessInfo`.
@MainActor
public final class HelperLowPowerModeController: LowPowerModeControlling {
    private let manager: FanControlManager

    public init(manager: FanControlManager) {
        self.manager = manager
    }

    public var isLowPowerModeEnabled: Bool? { LowPowerModeReader.processInfoState }

    public func setLowPowerMode(_ enabled: Bool) async throws {
        try await manager.setLowPowerMode(enabled)
    }
}
#endif
