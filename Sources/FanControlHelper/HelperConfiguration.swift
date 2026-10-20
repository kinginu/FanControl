#if os(macOS)
import Foundation
import Security
import FanControlXPC

/// Values read from the helper's embedded Info.plist (`-sectcreate __TEXT __info_plist`).
enum HelperConfiguration {
    /// Team ID that clients must be signed with (`FanControlClientTeamID`).
    /// Falls back to `FanControlHelperConstants.teamIdentifierPlaceholder` with a warning,
    /// which in practice rejects every client until the real Team ID is configured.
    static let teamID: String = {
        if let value = Bundle.main.infoDictionary?["FanControlClientTeamID"] as? String,
           !value.isEmpty {
            if value == FanControlHelperConstants.teamIdentifierPlaceholder {
                helperLog.warning("FanControlClientTeamID is still the placeholder; no real client will pass the code-signing check")
            }
            return value
        }
        helperLog.warning("FanControlClientTeamID missing from embedded Info.plist; using placeholder Team ID")
        return FanControlHelperConstants.teamIdentifierPlaceholder
    }()

    /// Requirement every client connection must satisfy, chosen once at startup by
    /// `FanControlHelperConstants.resolveClientRequirement(environment:teamID:)`:
    ///
    /// - no `FANCONTROL_CLIENT_REQUIREMENT` in the environment → Team-ID requirement
    ///   (SMAppService builds; unchanged behaviour);
    /// - the variable set by the manual-install LaunchDaemon plist → that requirement,
    ///   which must pin the app's cdhash (manual / personal mode, docs/helper.md
    ///   「手動インストール（個人利用モード）」);
    /// - the variable set but invalid → failure: `main.swift` logs a fault and exits
    ///   without listening.
    static func resolveClientRequirement(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<ClientRequirement, ManualRequirementError> {
        let resolved = FanControlHelperConstants.resolveClientRequirement(environment: environment, teamID: teamID)
        guard case .success(let requirement) = resolved else { return resolved }
        // Also make sure the Security framework can compile it (setCodeSigningRequirement
        // would otherwise reject it only when the first client connects).
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement.requirement as CFString, [], &compiled)
        guard status == errSecSuccess, compiled != nil else {
            return .failure(.malformed("\(requirement.requirement) (SecRequirementCreateWithString: \(status))"))
        }
        return resolved
    }

    /// `CFBundleVersion` of the helper, returned by `version(reply:)`.
    static let buildString: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (nil, b?): return b
        case let (s?, nil): return s
        default: return "unknown"
        }
    }()
}
#endif
