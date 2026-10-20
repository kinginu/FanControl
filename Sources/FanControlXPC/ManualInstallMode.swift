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
    public static var manualHelperPath: String { "/Library/PrivilegedHelperTools/\(launchdLabel)" }
    /// LaunchDaemon plist installed by `install.sh` (root:wheel 0644).
    public static var manualLaunchDaemonPlistPath: String { "/Library/LaunchDaemons/\(launchdLabel).plist" }
    /// Script names shown to the user (directory `FanControl/Support/manual-install/`).
    public static let manualInstallScriptName = "install.sh"
    public static let manualUninstallScriptName = "uninstall.sh"

    /// `true` if `value` is a cdhash as `codesign` prints it: exactly 40 ASCII hex digits
    /// (20 bytes: SHA-1, or SHA-256 truncated to 20 bytes). Either case is accepted.
    public static func isValidCDHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    /// Lower-cased cdhash, or `nil` if `value` is not 40 hex digits.
    public static func normalizedCDHash(_ value: String) -> String? {
        isValidCDHash(value) ? value.lowercased() : nil
    }

    /// cdhash-pinned requirement a **client** must satisfy in manual mode:
    /// `identifier "<clientBundleIdentifier>" and cdhash H"<40 hex, lower case>"`
    /// (`CodeSigningRequirement.cdhashPinned`). `nil` for an invalid cdhash or
    /// identifier. `install.sh` writes exactly this format (`common.sh`
    /// `client_requirement`). Team-ID counterpart: `clientCodeSigningRequirement(teamID:)`.
    public static func manualModeClientRequirement(cdhash: String,
                                                   clientBundleIdentifier: String = FanControlHelperConstants.appBundleIdentifier) -> String? {
        CodeSigningRequirement.cdhashPinned(identifier: clientBundleIdentifier, cdhash: cdhash)
    }

    /// cdhash-pinned requirement the app sets on its **helper** connection in manual
    /// mode (`cdhash` read from the root-owned `manualHelperPath`). `nil` for an invalid
    /// cdhash or identifier. Team-ID counterpart: `helperCodeSigningRequirement(teamID:)`.
    public static func manualModeHelperRequirement(cdhash: String,
                                                   helperIdentifier: String = FanControlHelperConstants.helperIdentifier) -> String? {
        CodeSigningRequirement.cdhashPinned(identifier: helperIdentifier, cdhash: cdhash)
    }

    /// Validates a `FANCONTROL_CLIENT_REQUIREMENT` value and returns the pinned cdhash
    /// (lower case). Strict: only exactly the `manualModeClientRequirement(cdhash:)`
    /// format is accepted (`CodeSigningRequirement.parseCDHashPinned`).
    public static func validateManualClientRequirement(_ requirement: String,
                                                       clientBundleIdentifier: String = FanControlHelperConstants.appBundleIdentifier) -> Result<String, ManualRequirementError> {
        CodeSigningRequirement.parseCDHashPinned(requirement, identifier: clientBundleIdentifier)
    }

    /// Decides which requirement the helper enforces on its clients.
    /// - No override in `environment` (key absent): the Team-ID requirement (SMAppService builds).
    /// - Override present and valid: the override in its canonical form (rebuilt from
    ///   the parsed cdhash, so the enforced string is exactly what was validated).
    /// - Override present but invalid (including empty): `.failure` — the helper must
    ///   not listen, so a weak requirement cannot be configured by accident.
    ///
    /// `teamID` is only evaluated without an override (the helper's Team ID lookup
    /// logs a placeholder warning that is irrelevant in manual mode).
    public static func resolveClientRequirement(environment: [String: String],
                                                teamID: @autoclosure () -> String,
                                                clientBundleIdentifier: String = FanControlHelperConstants.appBundleIdentifier) -> Result<ClientRequirement, ManualRequirementError> {
        guard let override = environment[clientRequirementEnvironmentKey] else {
            return .success(ClientRequirement(mode: .teamID,
                                              requirement: clientCodeSigningRequirement(teamID: teamID(),
                                                                                        clientBundleIdentifier: clientBundleIdentifier)))
        }
        switch validateManualClientRequirement(override, clientBundleIdentifier: clientBundleIdentifier) {
        case .success(let hash):
            guard let canonical = manualModeClientRequirement(cdhash: hash, clientBundleIdentifier: clientBundleIdentifier) else {
                return .failure(.malformed(override))
            }
            return .success(ClientRequirement(mode: .manualCDHash(hash), requirement: canonical))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Which helper requirement the app uses. Manual (cdhash-pinned) mode is chosen
    /// when a manual installation exists or the app itself carries no valid Team ID
    /// (ad-hoc signed); otherwise the Team-ID requirement (SMAppService path).
    public static func helperRequirementMode(appTeamID: String?, manualInstallDetected: Bool) -> HelperRequirementMode {
        if manualInstallDetected { return .manualCDHash }
        guard let team = appTeamID, FanControlIdentifiers.isValidTeamID(team) else { return .manualCDHash }
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
    public static func manualClientPinCheck(pinnedRequirement: String?, appCDHash: String?,
                                            clientBundleIdentifier: String = FanControlHelperConstants.appBundleIdentifier) -> ManualClientPinCheck {
        guard let pinnedRequirement else {
            return .unknown("\(clientRequirementEnvironmentKey) could not be read from \(manualLaunchDaemonPlistPath)")
        }
        guard let appCDHash, let own = normalizedCDHash(appCDHash) else {
            return .unknown("the app's own cdhash is not available")
        }
        switch validateManualClientRequirement(pinnedRequirement, clientBundleIdentifier: clientBundleIdentifier) {
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

/// Requirement chosen by the helper for its clients
/// (`FanControlHelperConstants.resolveClientRequirement`).
public struct ClientRequirement: Equatable, Sendable {
    /// Which pin the requirement uses (`SigningPin`).
    public enum Mode: Equatable, Sendable {
        /// `clientCodeSigningRequirement(teamID:)` (SMAppService / Team-ID builds).
        case teamID
        /// `FANCONTROL_CLIENT_REQUIREMENT` override pinning this cdhash (lower case;
        /// manual install).
        case manualCDHash(String)
    }
    /// Which pin `requirement` uses.
    public var mode: Mode
    /// The requirement string passed to `NSXPCConnection.setCodeSigningRequirement`.
    public var requirement: String

    public init(mode: Mode, requirement: String) {
        self.mode = mode
        self.requirement = requirement
    }
}

/// Which requirement the app puts on its helper connection
/// (`FanControlHelperConstants.helperRequirementMode`). Same case names as
/// `ClientRequirement.Mode`; the cdhash itself is read at connect time.
public enum HelperRequirementMode: Equatable, Sendable {
    /// `helperCodeSigningRequirement(teamID:)` (SMAppService path).
    case teamID
    /// `manualModeHelperRequirement(cdhash:)` with the installed helper's cdhash.
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
