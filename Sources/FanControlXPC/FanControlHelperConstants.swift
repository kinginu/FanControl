import Foundation

/// Constants shared by the host app (client) and FanControlHelper (privileged daemon).
///
/// The identifiers (Mach service, helper / client identifiers, Team ID) are **not**
/// hard-coded: they are read once from `Bundle.main.infoDictionary` through
/// `FanControlIdentifiers` (app: its Info.plist; helper: its embedded
/// `__TEXT,__info_plist`), falling back to the DynamicNotch defaults. The accessors
/// below keep the old names so call sites do not change. docs/helper.md
/// "Configuring identifiers".
///
/// This file is intentionally platform-neutral so that the allowlist logic can be
/// unit-tested on any platform.
public enum FanControlHelperConstants {
    /// Identifiers resolved from this process's Info.plist (read once, on first use).
    public static let identifiers = FanControlIdentifiers(bundle: .main)

    /// Mach service name vended by the helper (launchd `MachServices` key,
    /// Info.plist `FanControlMachServiceName`).
    public static var machServiceName: String { identifiers.machServiceName }
    /// launchd label. Must match `Label` in the LaunchDaemon plist.
    public static var launchdLabel: String { machServiceName }
    /// File name of the LaunchDaemon plist inside `<App>.app/Contents/Library/LaunchDaemons/`
    /// (`<launchdLabel>.plist`). Pass this to `SMAppService.daemon(plistName:)`.
    public static var plistName: String { "\(launchdLabel).plist" }
    /// Executable name inside `<App>.app/Contents/MacOS/`.
    public static let helperExecutableName = "FanControlHelper"
    /// Bump whenever `FanControlHelperProtocol` changes incompatibly. The app compares
    /// this with the value returned by `version(reply:)` and re-registers the helper on mismatch.
    public static let protocolVersion = 1
    /// Bundle identifier of the only client allowed to connect
    /// (Info.plist `FanControlClientBundleIdentifier`).
    public static var appBundleIdentifier: String { identifiers.clientBundleIdentifier }
    /// Team ID from Info.plist `FanControlClientTeamID`, `nil` if not configured.
    public static var clientTeamID: String? { identifiers.clientTeamID }
    /// Stand-in used when no Team ID is configured; no real signature carries it, so
    /// Team-ID requirements built from it reject everything.
    public static let teamIdentifierPlaceholder = "TEAMID0000"

    /// Code-signing identifier of the helper executable (`PRODUCT_BUNDLE_IDENTIFIER`
    /// of the Xcode helper target, Info.plist `FanControlHelperIdentifier`).
    public static var helperIdentifier: String { identifiers.helperIdentifier }

    /// Code-signing requirement the **helper** must satisfy; the app sets it on its
    /// client connection (`NSXPCConnection.setCodeSigningRequirement`) so it only
    /// talks to our own helper. `teamID` is `FanControlManager.clientTeamID`.
    public static func helperCodeSigningRequirement(teamID: String,
                                                    helperIdentifier: String = FanControlHelperConstants.helperIdentifier) -> String {
        "anchor apple generic and identifier \"\(helperIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Code-signing requirement a client must satisfy to talk to the helper.
    public static func clientCodeSigningRequirement(teamID: String,
                                                    clientBundleIdentifier: String = FanControlHelperConstants.appBundleIdentifier) -> String {
        "anchor apple generic and identifier \"\(clientBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Regular expressions (anchored) for SMC keys the helper is willing to write.
    /// - `F<n>Tg`: fan target speed
    /// - `F<n>Md`: fan mode (1 = forced/manual, 0 = automatic)
    ///
    /// Apple Silicon only (Intel dropped 2026-10-20): the Intel `FS! ` force
    /// bitmask is **not** allowed, nor is `F<n>Mn` (the Intel "set min to
    /// desired" technique; read-only on Apple Silicon, attribute `0x84` on
    /// Mac14,9). Unlock keys such as `Ftst` are not allowed either (pre-write
    /// review 2026-10-20).
    public static let allowedWriteKeyPatterns: [String] = [
        "^F[0-9]Tg$",
        "^F[0-9]Md$",
    ]

    /// Compiled `allowedWriteKeyPatterns` (built once; the patterns are constants).
    private static let allowedWriteKeyRegexes: [NSRegularExpression] =
        allowedWriteKeyPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    /// Returns `true` if `key` is exactly 4 ASCII characters and matches one of
    /// `allowedWriteKeyPatterns`.
    public static func isWriteAllowed(key: String) -> Bool {
        guard key.utf8.count == 4, key.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let range = NSRange(location: 0, length: (key as NSString).length)
        for regex in allowedWriteKeyRegexes {
            if regex.firstMatch(in: key, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
