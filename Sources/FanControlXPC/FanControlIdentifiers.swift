import Foundation

/// Identifiers that tie the host app, the privileged helper and launchd together,
/// read once at runtime from `Bundle.main.infoDictionary`:
///
/// - in the **app**, from the app's own `Info.plist`;
/// - in the **helper**, from the Info.plist embedded into the bare executable with
///   `-sectcreate __TEXT __info_plist` (`Support/Helper-Info.plist`).
///
/// Both sides read the same keys, so a host app sets them once (in `Helper-Info.plist`,
/// copied into the app's Info.plist by `Support/embed-helper-config.sh`, or by hand).
/// Every key is optional; a missing or invalid value falls back to the defaults below
/// (the identifiers DynamicNotch has always used), and invalid values are reported in
/// `issues` so the helper / app can log them. See docs/helper.md "Configuring identifiers".
///
/// | Key | Meaning | Fallback |
/// |---|---|---|
/// | `FanControlHelperIdentifier` | code-signing identifier of the helper (`PRODUCT_BUNDLE_IDENTIFIER` of the helper target) | `FanControlMachServiceName`, else `defaultHelperIdentifier` |
/// | `FanControlMachServiceName` | Mach service = launchd `Label`, LaunchDaemon plist name `<value>.plist`, manual-install paths | `FanControlHelperIdentifier` (resolved) |
/// | `FanControlClientBundleIdentifier` | bundle / code-signing identifier of the only app the helper accepts | `defaultClientBundleIdentifier` |
/// | `FanControlClientTeamID` | Team ID both binaries are signed with (SMAppService path only) | `nil` (callers use `FanControlHelperConstants.teamIdentifierPlaceholder`) |
///
/// Pure value type (no I/O besides `init(bundle:)`), so the parsing is unit-tested.
public struct FanControlIdentifiers: Equatable, Sendable {
    /// Info.plist keys.
    public enum InfoKey {
        public static let helperIdentifier = "FanControlHelperIdentifier"
        public static let machServiceName = "FanControlMachServiceName"
        public static let clientBundleIdentifier = "FanControlClientBundleIdentifier"
        public static let clientTeamID = "FanControlClientTeamID"
        public static let all = [helperIdentifier, machServiceName, clientBundleIdentifier, clientTeamID]
    }

    /// Defaults (DynamicNotch). Keep in sync with `Support/identifiers.sh`.
    public static let defaultHelperIdentifier = "com.example.dynamicnotch.DynamicNotch.fanfi"
    public static let defaultClientBundleIdentifier = "com.example.dynamicnotch.DynamicNotch"

    /// Code-signing identifier of the helper executable.
    public var helperIdentifier: String
    /// Mach service name vended by the helper; also the launchd label.
    public var machServiceName: String
    /// Bundle identifier (and code-signing identifier) of the client app.
    public var clientBundleIdentifier: String
    /// Team ID configured in the Info.plist, `nil` if absent or invalid.
    public var clientTeamID: String?
    /// Human-readable problems found while parsing (invalid values that were ignored).
    public var issues: [String]

    /// The built-in defaults (no Info.plist keys).
    public static let defaults = FanControlIdentifiers(infoDictionary: nil)

    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        var issues: [String] = []

        func identifier(_ key: String) -> String? {
            guard let raw = info[key] else { return nil }
            guard let value = raw as? String else {
                issues.append("\(key) is not a string; ignored")
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidIdentifier(trimmed) else {
                issues.append("\(key) '\(value)' is not a valid reverse-DNS identifier; ignored")
                return nil
            }
            return trimmed
        }

        let helper = identifier(InfoKey.helperIdentifier)
        let mach = identifier(InfoKey.machServiceName)
        let client = identifier(InfoKey.clientBundleIdentifier)

        helperIdentifier = helper ?? mach ?? Self.defaultHelperIdentifier
        machServiceName = mach ?? helperIdentifier
        clientBundleIdentifier = client ?? Self.defaultClientBundleIdentifier
        if clientBundleIdentifier == helperIdentifier {
            issues.append("\(InfoKey.clientBundleIdentifier) equals the helper identifier '\(helperIdentifier)'; the app and the helper need distinct identifiers")
        }

        clientTeamID = nil
        if let raw = info[InfoKey.clientTeamID] {
            if let value = raw as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Explicitly empty: treated as "not configured".
                } else if Self.isValidTeamID(trimmed) {
                    clientTeamID = trimmed
                } else {
                    issues.append("\(InfoKey.clientTeamID) '\(value)' is not a 10-character Team ID; ignored")
                }
            } else {
                issues.append("\(InfoKey.clientTeamID) is not a string; ignored")
            }
        }
        self.issues = issues
    }

    /// Reads `bundle.infoDictionary` (for a bare helper executable: the embedded
    /// `__TEXT,__info_plist` section).
    public init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    /// The four keys as an Info.plist fragment (what `embed-helper-config.sh` writes into
    /// the app). `FanControlClientTeamID` only when configured.
    public var infoDictionaryRepresentation: [String: String] {
        var dict = [InfoKey.helperIdentifier: helperIdentifier,
                    InfoKey.machServiceName: machServiceName,
                    InfoKey.clientBundleIdentifier: clientBundleIdentifier]
        if let clientTeamID { dict[InfoKey.clientTeamID] = clientTeamID }
        return dict
    }

    /// Reverse-DNS style identifier: 1…255 ASCII letters, digits, `-` and `.`, no
    /// leading/trailing dot and no empty component. The value is interpolated into
    /// code-signing requirement strings and file paths, so quotes, slashes, spaces and
    /// the like must never get through.
    public static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count) else { return false }
        guard value.utf8.allSatisfy({ byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x2E
        }) else { return false }
        return !value.split(separator: ".", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// Apple Team ID: exactly 10 upper-case ASCII letters or digits.
    public static func isValidTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
        }
    }
}
