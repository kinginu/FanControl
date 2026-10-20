import Foundation

/// How one binary pins the other's code signature. The two install paths differ
/// **only** in this pin; identifiers, Mach service, protocol and write rules are shared.
///
/// | | SMAppService (distribution) | Manual install (personal use, docs/helper.md §6) |
/// |---|---|---|
/// | Signing | Developer ID / Apple Development, one Team ID | ad hoc (no Team ID) |
/// | Pin | `.teamID("<Team ID>")` | `.cdhash("<40 hex digits>")` |
/// | Requirement | `anchor apple generic and identifier "<id>" and certificate leaf[subject.OU] = "<Team ID>"` | `identifier "<id>" and cdhash H"<cdhash>"` |
/// | Helper → app, pin read from | Info.plist `FanControlClientTeamID` | `FANCONTROL_CLIENT_REQUIREMENT` in the root-owned LaunchDaemon plist |
/// | App → helper, pin read from | `FanControlManager.clientTeamID` | cdhash of the root-owned `manualHelperPath` |
/// | Mode enums | `ClientRequirement.Mode.teamID`, `HelperRequirementMode.teamID` | `ClientRequirement.Mode.manualCDHash`, `HelperRequirementMode.manualCDHash` |
/// | `FanControlHelperConstants` builders | `clientCodeSigningRequirement(teamID:)`, `helperCodeSigningRequirement(teamID:)` | `manualModeClientRequirement(cdhash:)`, `manualModeHelperRequirement(cdhash:)` |
public enum SigningPin: Equatable, Hashable, Sendable {
    /// The peer must be signed by Apple-issued certificates of this Team ID.
    case teamID(String)
    /// The peer must have exactly this code directory hash (40 hex digits).
    case cdhash(String)
}

/// Builds and parses the code-signing requirement strings both sides of the XPC
/// connection enforce (`NSXPCConnection.setCodeSigningRequirement`).
///
/// Every value interpolated into a requirement is validated first, so a requirement
/// can never be widened by a crafted identifier, Team ID or cdhash (quotes, `or`
/// clauses, …):
///
/// - identifiers: `FanControlIdentifiers.isValidIdentifier` (reverse-DNS characters only);
/// - Team IDs: `FanControlIdentifiers.isValidTeamID` (10 upper-case letters / digits);
/// - cdhashes: `FanControlHelperConstants.isValidCDHash` (40 hex digits, lower-cased).
///
/// The builders return `nil` for invalid input. Callers that must always produce a
/// requirement fall back to `never`, which no code satisfies (fail closed).
///
/// Pure string logic (no Security framework), unit-tested on any platform; the helper
/// additionally compiles its requirement with `SecRequirementCreateWithString` at start.
public enum CodeSigningRequirement {
    /// Requirement no code satisfies (requirement language constant). Used whenever an
    /// input is invalid, so a configuration mistake rejects every peer instead of
    /// accepting more than intended.
    public static let never = "never"

    /// `anchor apple generic and identifier "<identifier>" and certificate leaf[subject.OU] = "<teamID>"`,
    /// or `nil` if either value is invalid.
    public static func teamPinned(identifier: String, teamID: String) -> String? {
        guard FanControlIdentifiers.isValidIdentifier(identifier),
              FanControlIdentifiers.isValidTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// `identifier "<identifier>" and cdhash H"<cdhash, lower case>"`, or `nil` if either
    /// value is invalid. This is the only form `parseCDHashPinned` accepts, and the form
    /// `Support/manual-install/common.sh` (`client_requirement`) writes.
    public static func cdhashPinned(identifier: String, cdhash: String) -> String? {
        guard FanControlIdentifiers.isValidIdentifier(identifier),
              let hash = FanControlHelperConstants.normalizedCDHash(cdhash) else { return nil }
        return "\(cdhashPrefix(identifier: identifier))\(hash)\""
    }

    /// The requirement for `pin`, or `nil` if `identifier` or the pinned value is invalid.
    public static func make(identifier: String, pin: SigningPin) -> String? {
        switch pin {
        case .teamID(let team): return teamPinned(identifier: identifier, teamID: team)
        case .cdhash(let hash): return cdhashPinned(identifier: identifier, cdhash: hash)
        }
    }

    /// Parses a cdhash-pinned requirement and returns the pinned cdhash (lower case).
    ///
    /// Deliberately strict: after trimming surrounding whitespace the value must be
    /// exactly `cdhashPinned(identifier:cdhash:)` output (hex digits may be upper case).
    /// A looser check ("contains `identifier …` and `cdhash H"`") would also accept
    /// e.g. `… and cdhash H"…" or anchor apple`, which matches far more code.
    ///
    /// Errors, in the order they are checked: `.empty`; `.wrongIdentifier` (does not
    /// start with `identifier "<identifier>" `, or `identifier` itself is invalid);
    /// `.missingCDHash` (no `cdhash H"`); `.malformed` (anything but exactly
    /// `and cdhash H"<40 characters>"` after the identifier); `.invalidCDHash` (the
    /// 40 characters are not hex).
    public static func parseCDHashPinned(_ requirement: String,
                                         identifier: String) -> Result<String, ManualRequirementError> {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard FanControlIdentifiers.isValidIdentifier(identifier),
              trimmed.hasPrefix("identifier \"\(identifier)\" ") else {
            return .failure(.wrongIdentifier(trimmed))
        }
        guard trimmed.contains("cdhash H\"") else { return .failure(.missingCDHash(trimmed)) }
        let prefix = cdhashPrefix(identifier: identifier)
        guard trimmed.hasPrefix(prefix) else { return .failure(.malformed(trimmed)) }
        let rest = trimmed.utf8.dropFirst(prefix.utf8.count)
        guard rest.count == 41, rest.last == UInt8(ascii: "\"") else { return .failure(.malformed(trimmed)) }
        let hash = String(decoding: rest.dropLast(), as: UTF8.self)
        guard let normalized = FanControlHelperConstants.normalizedCDHash(hash) else {
            return .failure(.invalidCDHash(hash))
        }
        return .success(normalized)
    }

    /// `identifier "<identifier>" and cdhash H"` (shared by the builder and the parser).
    private static func cdhashPrefix(identifier: String) -> String {
        "identifier \"\(identifier)\" and cdhash H\""
    }
}
