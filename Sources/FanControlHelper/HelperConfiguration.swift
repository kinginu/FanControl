#if os(macOS)
import Foundation
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
