import Foundation

/// Manual-install (personal use) mode: the helper is installed by
/// `Support/manual-install/install.sh` as a plain LaunchDaemon instead of being
/// registered with `SMAppService`, and both binaries are ad-hoc signed (no Team ID).
///
/// Without a Team ID the usual `anchor apple generic … leaf[subject.OU]` requirements
/// cannot be satisfied, so each side pins the **cdhash** of the other instead:
///
/// - Helper → app: the root-owned LaunchDaemon plist sets the environment variable
///   `FANCONTROL_CLIENT_REQUIREMENT` = `manualModeClientRequirement(cdhash:)`.
///   This check is the security boundary (only a client satisfying it can ask root
///   to write the SMC). An `identifier`-only requirement would be spoofable — any
///   local process can ad-hoc sign itself with the app's bundle identifier — so the
///   helper refuses to start unless the override pins a cdhash
///   (`resolveClientRequirement(environment:teamID:)`).
/// - App → helper: `manualModeHelperRequirement(cdhash:)` with the cdhash read at
///   connect time from the root-owned `manualHelperPath`.
///
/// Everything here is platform-neutral pure logic shared by the helper, the app
/// (FanControlKit), the install script (same string format) and the tests.
extension FanControlHelperConstants {
    /// Environment variable (launchd `EnvironmentVariables`) that overrides the helper's
    /// client code-signing requirement.
    public static let clientRequirementEnvironmentKey = "FANCONTROL_CLIENT_REQUIREMENT"
    /// Helper binary installed by `install.sh` (root:wheel 0755).
    public static let manualHelperPath = "/Library/PrivilegedHelperTools/\(launchdLabel)"
    /// LaunchDaemon plist installed by `install.sh` (root:wheel 0644).
    public static let manualLaunchDaemonPlistPath = "/Library/LaunchDaemons/\(launchdLabel).plist"
    /// Script names shown to the user (directory `FanControl/Support/manual-install/`).
    public static let manualInstallScriptName = "install.sh"
    public static let manualUninstallScriptName = "uninstall.sh"

    /// `true` if `value` is a SHA-256-truncated / SHA-1 cdhash: exactly 40 hex digits.
    public static func isValidCDHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    /// Lower-cased cdhash, or `nil` if `value` is not 40 hex digits.
    public static func normalizedCDHash(_ value: String) -> String? {
        isValidCDHash(value) ? value.lowercased() : nil
    }

    /// Client requirement for manual mode:
    /// `identifier "com.example.dynamicnotch.DynamicNotch" and cdhash H"<40 hex>"`.
    /// Returns `nil` for an invalid cdhash. `install.sh` writes exactly this format.
    public static func manualModeClientRequirement(cdhash: String) -> String? {
        guard let hash = normalizedCDHash(cdhash) else { return nil }
        return "identifier \"\(appBundleIdentifier)\" and cdhash H\"\(hash)\""
    }

    /// Requirement the app sets on its helper connection in manual mode.
    public static func manualModeHelperRequirement(cdhash: String) -> String? {
        guard let hash = normalizedCDHash(cdhash) else { return nil }
        return "identifier \"\(helperIdentifier)\" and cdhash H\"\(hash)\""
    }

    /// Validates a `FANCONTROL_CLIENT_REQUIREMENT` value.
    ///
    /// Deliberately strict: the value must be exactly the format produced by
    /// `manualModeClientRequirement(cdhash:)` (surrounding whitespace ignored). A
    /// substring check ("contains `identifier …` and `cdhash H"`") would also accept
    /// e.g. `… and cdhash H"…" or anchor apple`, which matches far more clients.
    /// Returns the pinned cdhash (lower case) on success.
    public static func validateManualClientRequirement(_ requirement: String) -> Result<String, ManualRequirementError> {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.hasPrefix("identifier \"\(appBundleIdentifier)\" ") else {
            return .failure(.wrongIdentifier(trimmed))
        }
        guard trimmed.contains("cdhash H\"") else { return .failure(.missingCDHash(trimmed)) }
        let prefix = "identifier \"\(appBundleIdentifier)\" and cdhash H\""
        guard trimmed.hasPrefix(prefix) else { return .failure(.malformed(trimmed)) }
        let rest = trimmed.dropFirst(prefix.count)
        guard rest.hasSuffix("\""), rest.count == 41 else { return .failure(.malformed(trimmed)) }
        let hash = String(rest.dropLast())
        guard let normalized = normalizedCDHash(hash) else { return .failure(.invalidCDHash(hash)) }
        return .success(normalized)
    }

    /// Decides which requirement the helper enforces on its clients.
    /// - No override in `environment` (key absent): the Team-ID requirement (SMAppService builds).
    /// - Override present and valid: the override (manual mode).
    /// - Override present but invalid (including empty): `.failure` — the helper must
    ///   not listen, so a weak requirement cannot be configured by accident.
    ///
    /// `teamID` is only evaluated without an override (the helper's Team ID lookup
    /// logs a placeholder warning that is irrelevant in manual mode).
    public static func resolveClientRequirement(environment: [String: String],
                                                teamID: @autoclosure () -> String) -> Result<ClientRequirement, ManualRequirementError> {
        guard let override = environment[clientRequirementEnvironmentKey] else {
            return .success(ClientRequirement(mode: .teamID, requirement: clientCodeSigningRequirement(teamID: teamID())))
        }
        switch validateManualClientRequirement(override) {
        case .success(let hash):
            return .success(ClientRequirement(mode: .manualCDHash(hash),
                                              requirement: override.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Which helper requirement the app uses. Manual (cdhash-pinned) mode is chosen
    /// when the app itself has no Team ID (ad-hoc signed) or a manual installation
    /// exists; otherwise the Team-ID requirement (SMAppService path, unchanged).
    public static func helperRequirementMode(appTeamID: String?, manualInstallDetected: Bool) -> HelperRequirementMode {
        if manualInstallDetected { return .manualCDHash }
        guard let team = appTeamID, !team.isEmpty else { return .manualCDHash }
        return .teamID
    }

    /// State of the manual installation given which of its two files exist.
    public static func manualInstallState(plistExists: Bool, helperExists: Bool) -> ManualInstallState {
        switch (plistExists, helperExists) {
        case (true, true): return .installed
        case (false, false): return .absent
        case (true, false): return .incomplete(missing: manualHelperPath)
        case (false, true): return .incomplete(missing: manualLaunchDaemonPlistPath)
        }
    }

    /// Compares the client cdhash pinned by the installed LaunchDaemon plist
    /// (`FANCONTROL_CLIENT_REQUIREMENT`, `nil` if it could not be read) with the running
    /// app's own cdhash (`nil` if unknown). The app runs this before connecting in
    /// manual mode, so a helper pinned to another build is reported without a
    /// connection attempt (`HelperInstallStatus.installedManuallyMismatch`).
    public static func manualClientPinCheck(pinnedRequirement: String?, appCDHash: String?) -> ManualClientPinCheck {
        guard let pinnedRequirement else {
            return .unknown("\(clientRequirementEnvironmentKey) could not be read from \(manualLaunchDaemonPlistPath)")
        }
        guard let appCDHash, let own = normalizedCDHash(appCDHash) else {
            return .unknown("the app's own cdhash is not available")
        }
        switch validateManualClientRequirement(pinnedRequirement) {
        case .success(let pinned):
            return pinned == own ? .matches : .mismatch(pinnedCDHash: pinned, appCDHash: own)
        case .failure(let error):
            // The helper refuses to start with such a value anyway.
            return .unknown(error.description)
        }
    }

    /// `true` if a file with this owner and mode can serve as a trust anchor: owned by
    /// root and not writable by group or others (only root could have put it there).
    public static func isRootOwnedAndProtected(ownerUID: UInt32, permissions: UInt16) -> Bool {
        ownerUID == 0 && (permissions & 0o022) == 0
    }
}

/// Requirement chosen by the helper for its clients.
public struct ClientRequirement: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// `clientCodeSigningRequirement(teamID:)` (SMAppService / Team-ID builds).
        case teamID
        /// `FANCONTROL_CLIENT_REQUIREMENT` override pinning this cdhash (manual install).
        case manualCDHash(String)
    }
    public var mode: Mode
    public var requirement: String
}

/// Helper requirement used by the app.
public enum HelperRequirementMode: Equatable, Sendable {
    case teamID
    case manualCDHash
}

/// Presence of the manual-install files.
public enum ManualInstallState: Equatable, Sendable {
    case absent
    case installed
    /// Exactly one of the two files exists (`missing` is the absent path).
    case incomplete(missing: String)
}

/// Result of `FanControlHelperConstants.manualClientPinCheck`.
public enum ManualClientPinCheck: Equatable, Sendable {
    /// The helper pins this app's cdhash.
    case matches
    /// The helper pins another build: `sudo install.sh <this app>` must be re-run.
    case mismatch(pinnedCDHash: String, appCDHash: String)
    /// Could not decide (plist unreadable, unsigned app, malformed value); connect and
    /// rely on the runtime detection (`HelperConnectionGate`).
    case unknown(String)
}

/// Why a `FANCONTROL_CLIENT_REQUIREMENT` value was refused.
public enum ManualRequirementError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case wrongIdentifier(String)
    case missingCDHash(String)
    case invalidCDHash(String)
    case malformed(String)

    public var description: String {
        let expected = "expected: identifier \"\(FanControlHelperConstants.appBundleIdentifier)\" and cdhash H\"<40 hex digits>\""
        switch self {
        case .empty: return "\(FanControlHelperConstants.clientRequirementEnvironmentKey) is empty; \(expected)"
        case .wrongIdentifier(let value): return "requirement does not start with the app's identifier: \(value); \(expected)"
        case .missingCDHash(let value): return "requirement does not pin a cdhash: \(value); \(expected)"
        case .invalidCDHash(let value): return "cdhash is not 40 hex digits: \(value); \(expected)"
        case .malformed(let value): return "requirement is not in the accepted format: \(value); \(expected)"
        }
    }
}
