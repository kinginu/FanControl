import Foundation
import FanControlXPC

/// Why `HelperClient` stopped talking to the helper (`HelperConnectionState.rejected(reason:)`).
///
/// A rejection is sticky: no further connection is attempted until the user asks
/// for it (`HelperClient.resetRejection()`, "Check Again"), the app is relaunched,
/// or the installation changes on disk (`HelperConnectionGate` compares an install
/// fingerprint, so re-running `install.sh` clears it by itself).
public enum HelperRejectionReason: Equatable, Sendable, CustomStringConvertible {
    /// Manual install: the root-owned LaunchDaemon plist pins another client cdhash
    /// (`FANCONTROL_CLIENT_REQUIREMENT`) than this app's. Detected **before**
    /// connecting (`FanControlHelperConstants.manualClientPinCheck`), so no
    /// connection is made at all.
    case clientNotPinned(pinnedCDHash: String, appCDHash: String)
    /// The helper dropped the connection right after the first request, without a
    /// reply, `HelperConnectionGate.Policy.dropsBeforeRejection` times in a row.
    /// The helper's client requirement (pinned cdhash or Team ID) most likely does
    /// not match this app (seen from the client as `NSXPCConnectionInterrupted`).
    case droppedByHelper
    /// The helper's code signature does not satisfy the requirement this app puts on
    /// the connection (`NSXPCConnectionCodeSigningRequirementFailure`, 4102).
    case helperSignatureMismatch

    /// English, for logs and `FanControlError.helperConnectionRejected`. The UI
    /// shows its own localized text per case.
    public var description: String {
        let rerun = "re-run sudo \(FanControlHelperConstants.manualInstallScriptName) <this app> (FanControl/Support/manual-install/)"
        switch self {
        case .clientNotPinned(let pinned, let app):
            return "the installed helper is pinned to a different build of the app (pinned cdhash \(pinned), this app \(app)); \(rerun)"
        case .droppedByHelper:
            return "the helper closed the connection without replying (its code-signing requirement does not accept this app: the installed helper is probably pinned to a different build of the app); \(rerun)"
        case .helperSignatureMismatch:
            return "the helper's code signature does not match the requirement of this app (the helper binary was replaced or the app expects another one); \(rerun)"
        }
    }
}

/// How one helper call failed, as far as the retry policy is concerned
/// (`HelperConnectionGate.classify`).
public enum HelperCallFailure: Equatable, Sendable {
    /// `NSXPCConnectionCodeSigningRequirementFailure`: definitive.
    case codeSigningRequirementFailed
    /// The connection was interrupted before the helper ever replied on it, i.e.
    /// right after the first message. What a client-requirement failure on the
    /// helper side looks like (the helper accepts, then invalidates the peer).
    case droppedWithoutReply
    /// Anything else: timeout, helper not running / not registered, interrupted
    /// after earlier replies (crash or restart), unexpected proxy type.
    case transient
}

/// Retry policy of `HelperClient` (pure state machine, unit tested).
///
/// - A rejection (`HelperRejectionReason`) blocks every call until `reset()` or until
///   the install fingerprint changes (e.g. `install.sh` rewrote the plist).
/// - Transient failures back off exponentially: after the n-th consecutive failure
///   calls fail fast for `min(initialBackoff × multiplier^(n−1), maxBackoff)` seconds.
/// - Any successful reply resets the counters.
///
/// Times are monotonic seconds (`ProcessInfo.systemUptime` in the client).
public struct HelperConnectionGate: Equatable, Sendable {

    public struct Policy: Equatable, Sendable {
        public var initialBackoff: TimeInterval
        public var multiplier: Double
        public var maxBackoff: TimeInterval
        /// Consecutive `.droppedWithoutReply` failures that count as a rejection.
        public var dropsBeforeRejection: Int

        public init(initialBackoff: TimeInterval = 2, multiplier: Double = 2,
                    maxBackoff: TimeInterval = 300, dropsBeforeRejection: Int = 2) {
            self.initialBackoff = initialBackoff
            self.multiplier = multiplier
            self.maxBackoff = maxBackoff
            self.dropsBeforeRejection = max(1, dropsBeforeRejection)
        }

        public static let `default` = Policy()
    }

    public enum Decision: Equatable, Sendable {
        case proceed
        /// Do not connect; the reason stays until `reset()` / a new fingerprint.
        case rejected(HelperRejectionReason)
        /// Do not connect for another `remaining` seconds.
        case backingOff(remaining: TimeInterval)
    }

    public let policy: Policy
    public private(set) var rejection: HelperRejectionReason?
    /// Install fingerprint when the rejection was recorded.
    public private(set) var rejectionFingerprint: String?
    public private(set) var consecutiveFailures = 0
    public private(set) var consecutiveDrops = 0
    /// Monotonic time before which calls fail fast (transient backoff).
    public private(set) var retryAt: TimeInterval?

    public init(policy: Policy = .default) {
        self.policy = policy
    }

    /// Whether a call may connect now. A rejection recorded under another install
    /// fingerprint is dropped (the user re-ran `install.sh`), and so is the backoff.
    public mutating func decide(now: TimeInterval, fingerprint: String) -> Decision {
        if let rejection {
            if fingerprint == rejectionFingerprint { return .rejected(rejection) }
            reset()
        }
        if let retryAt, now < retryAt { return .backingOff(remaining: retryAt - now) }
        return .proceed
    }

    /// A reply arrived: the helper accepts this app.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
        consecutiveDrops = 0
        retryAt = nil
    }

    /// Records a rejection found without connecting (manual pin check).
    public mutating func recordRejection(_ reason: HelperRejectionReason, fingerprint: String) {
        rejection = reason
        rejectionFingerprint = fingerprint
        retryAt = nil
    }

    /// Records a failed call; returns the rejection if this failure caused one.
    @discardableResult
    public mutating func recordFailure(_ failure: HelperCallFailure, now: TimeInterval,
                                       fingerprint: String) -> HelperRejectionReason? {
        switch failure {
        case .codeSigningRequirementFailed:
            recordRejection(.helperSignatureMismatch, fingerprint: fingerprint)
            return .helperSignatureMismatch
        case .droppedWithoutReply:
            consecutiveDrops += 1
            if consecutiveDrops >= policy.dropsBeforeRejection {
                recordRejection(.droppedByHelper, fingerprint: fingerprint)
                return .droppedByHelper
            }
        case .transient:
            consecutiveDrops = 0
        }
        consecutiveFailures += 1
        retryAt = now + backoffDelay(afterFailures: consecutiveFailures)
        return nil
    }

    /// User action ("Check Again") or relaunch: forget rejection and backoff.
    public mutating func reset() {
        rejection = nil
        rejectionFingerprint = nil
        consecutiveFailures = 0
        consecutiveDrops = 0
        retryAt = nil
    }

    /// Backoff after `failures` consecutive failures (≥ 1).
    public func backoffDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 62))
        return min(policy.initialBackoff * pow(policy.multiplier, exponent), policy.maxBackoff)
    }

    /// `NSError` domain/code of a failed call → retry class.
    /// - Parameter hadReplyBeforeSend: the current peer connection had already
    ///   answered a call when this one was sent (then an interruption means the
    ///   helper went away, not that it refused us).
    public static func classify(errorDomain: String, errorCode: Int, hadReplyBeforeSend: Bool) -> HelperCallFailure {
        guard errorDomain == NSCocoaErrorDomain else { return .transient }
        switch errorCode {
        case codeSigningRequirementFailureCode:
            return .codeSigningRequirementFailed
        case connectionInterruptedCode:
            return hadReplyBeforeSend ? .transient : .droppedWithoutReply
        default:
            return .transient
        }
    }

    /// `NSXPCConnectionInterrupted`.
    public static let connectionInterruptedCode = 4097
    /// `NSXPCConnectionInvalid`.
    public static let connectionInvalidCode = 4099
    /// `NSXPCConnectionCodeSigningRequirementFailure` (macOS 13+).
    public static let codeSigningRequirementFailureCode = 4102
}
