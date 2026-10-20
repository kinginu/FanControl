#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

// F2: Low Power Mode for power profiles. Writing needs root (the helper's dedicated
// `setLowPowerMode` request, sent on its own session-less connection); reading does not
// (`ProcessInfo.isLowPowerModeEnabled`, and `pmset -g` / `pmset -g custom`).

/// Low Power Mode as `PowerProfileEngine` sees it (a fake in tests).
@MainActor
public protocol LowPowerModeControlling: AnyObject {
    /// The current state (read-back); `nil` if unknown.
    var isLowPowerModeEnabled: Bool? { get }
    /// The per-power-source settings (`pmset -g custom`), `nil` if unreadable.
    func readLowPowerModeSettings() async -> LowPowerModeSettings?
    /// Sets the value on battery and on AC power (helper request). Throws on failure.
    func setLowPowerMode(battery: Bool, ac: Bool) async throws
}

extension LowPowerModeControlling {
    /// Sets the value for every power source.
    public func setLowPowerMode(_ enabled: Bool) async throws {
        try await setLowPowerMode(battery: enabled, ac: enabled)
    }
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
                                arguments: LowPowerModeCommand.readArguments,
                                timeout: LowPowerModeCommand.commandTimeout)
        guard result.status == 0 else { return nil }
        return LowPowerModeCommand.parseLowPowerMode(pmsetOutput: result.standardOutput)
    }

    /// `pmset -g custom` → per-source settings (fixed argv, no shell, no root). Blocking:
    /// runs off the main actor. `nil` if pmset fails or prints neither section.
    @concurrent
    public static func pmsetSettings(runner: any CommandRunning = ProcessCommandRunner()) async -> LowPowerModeSettings? {
        let result = runner.run(executable: LowPowerModeCommand.pmsetPath,
                                arguments: LowPowerModeCommand.readCustomArguments,
                                timeout: LowPowerModeCommand.commandTimeout)
        guard result.status == 0 else { return nil }
        return LowPowerModeCommand.parseSettings(pmsetCustomOutput: result.standardOutput)
    }
}

extension FanControlManager {
    // F2: Low Power Mode request (never installs or registers the helper by itself).
    /// Sets Low Power Mode for every power source through the helper (`pmset -a lowpowermode 0|1`).
    public func setLowPowerMode(_ enabled: Bool) async throws {
        try await setLowPowerMode(battery: enabled, ac: enabled)
    }

    /// Sets Low Power Mode on battery and on AC power through the helper.
    ///
    /// Requires an installed helper that speaks protocol `lowPowerModeProtocolVersion` or
    /// later; it does not register the helper (automation must not trigger approval prompts)
    /// and needs no write session. The request goes over a **separate, short-lived
    /// connection** (`HelperClient.makeIndependentClient`, timeout
    /// `LowPowerModeCommand.clientCallTimeout`): the fan write session's connection is never
    /// blocked by pmset, and a timeout here cannot invalidate it (which would make the helper
    /// restore the fans). Errors are thrown, not recorded in `lastError`.
    public func setLowPowerMode(battery: Bool, ac: Bool) async throws {
        guard FanControlPlatform.isSupported else {
            throw FanControlError.unsupportedPlatform(FanControlPlatform.unsupportedPlatformDetail)
        }
        let status = helper.installer.status()
        guard status == .enabled || status.isManualInstallation else {
            throw FanControlError.helperNotInstalled
        }
        // A sticky rejection of the main client (e.g. pinned to another build) applies here too.
        if let rejection = helper.client.rejection {
            throw FanControlError.helperConnectionRejected(rejection.description)
        }
        let client = helper.client.makeIndependentClient(callTimeout: LowPowerModeCommand.clientCallTimeout)
        defer { client.invalidate() }
        let (version, _) = try await client.version()
        guard version >= FanControlHelperConstants.lowPowerModeProtocolVersion else {
            throw FanControlError.helperRejected(
                code: -1,
                message: "The installed helper (protocol \(version)) cannot change Low Power Mode; it needs protocol \(FanControlHelperConstants.lowPowerModeProtocolVersion). Re-run sudo \(FanControlHelperConstants.manualInstallScriptName) with this app.")
        }
        try await client.setLowPowerMode(battery: battery, ac: ac)
        kitLog.notice("Low Power Mode set \(LowPowerModeCommand.describe(battery: battery, ac: ac), privacy: .public) through the helper")
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

    public func readLowPowerModeSettings() async -> LowPowerModeSettings? {
        await LowPowerModeReader.pmsetSettings()
    }

    public func setLowPowerMode(battery: Bool, ac: Bool) async throws {
        try await manager.setLowPowerMode(battery: battery, ac: ac)
    }
}
#endif
