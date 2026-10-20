import Foundation

/// Errors raised across the fan-control stack.
public enum FanControlError: Error, Equatable, Sendable, LocalizedError {
    /// The `AppleSMC` IOKit service could not be opened.
    case smcUnavailable
    /// The SMC has no key with this name.
    case keyNotFound(String)
    /// The string is not a valid four-character SMC key.
    case invalidKey(String)
    /// Reading `key` failed with the SMC / IOKit result `code`.
    case readFailed(key: String, code: Int32)
    /// Writing `key` failed with the SMC / IOKit result `code`.
    case writeFailed(key: String, code: Int32)
    /// The privileged helper is not installed (or not registered with launchd).
    case helperNotInstalled
    /// Connecting to or talking with the helper failed (XPC error, timeout, unreadable
    /// manual-install files, invalid pinned cdhash); the value describes why.
    case helperConnectionFailed(String)
    /// The helper answered a request with an error (write policy, session state);
    /// `code` and `message` are the helper's.
    case helperRejected(code: Int, message: String)
    /// The helper refuses this app's connections (code-signing requirement mismatch,
    /// e.g. a manual install pinned to another build of the app). Sticky until the
    /// user retries (`FanControlManager.retryHelperConnection()`) or reinstalls.
    case helperConnectionRejected(String)
    /// A write was requested without an open helper session.
    case sessionNotOpen
    /// A target speed outside the fan's `allowed` range (`F<n>Mn`…`F<n>Mx`).
    case rpmOutOfRange(fan: Int, rpm: Int, allowed: ClosedRange<Int>)
    /// The SMC key has a data type the codec cannot decode or encode.
    case unsupportedDataType(String)
    /// The host is not an Apple Silicon Mac (Intel Macs are not supported).
    /// The associated value describes the detected hardware.
    case unsupportedPlatform(String)
    /// Fan `fan` has `F<n>Tg` but no `F<n>Md` mode key, so it cannot be put into
    /// manual mode with the (only supported) Apple Silicon write scheme.
    case fanModeKeyMissing(fan: Int)

    public var errorDescription: String? {
        switch self {
        case .smcUnavailable:
            return "The System Management Controller (SMC) is not available."
        case .keyNotFound(let key):
            return "SMC key \"\(key)\" was not found."
        case .invalidKey(let key):
            return "\"\(key)\" is not a valid SMC key."
        case .readFailed(let key, let code):
            return "Reading SMC key \"\(key)\" failed (code \(code))."
        case .writeFailed(let key, let code):
            return "Writing SMC key \"\(key)\" failed (code \(code))."
        case .helperNotInstalled:
            return "The fan control helper is not installed."
        case .helperConnectionFailed(let reason):
            return "Could not connect to the fan control helper: \(reason)"
        case .helperRejected(let code, let message):
            return "The fan control helper rejected the request (code \(code)): \(message)"
        case .helperConnectionRejected(let reason):
            return "The fan control helper refuses this app: \(reason)"
        case .sessionNotOpen:
            return "No fan control session is open."
        case .rpmOutOfRange(let fan, let rpm, let allowed):
            return "\(rpm) RPM is outside the allowed range \(allowed.lowerBound)-\(allowed.upperBound) RPM for fan \(fan)."
        case .unsupportedDataType(let type):
            return "Unsupported SMC data type \"\(type)\"."
        case .unsupportedPlatform(let detail):
            return "Fan control requires a Mac with Apple silicon (\(detail))."
        case .fanModeKeyMissing(let fan):
            return "Fan \(fan) has no SMC mode key \"F\(fan)Md\" and cannot be controlled on this Mac."
        }
    }
}
