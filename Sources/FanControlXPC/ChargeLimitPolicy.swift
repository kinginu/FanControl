import Foundation
import FanControlCore

/// Platform-neutral rules of the Apple Silicon charge limit ("Limit charging to
/// 80 %"), written by FanControlHelper through the dedicated
/// `FanControlHelperProtocol.setChargeLimitEnabled(_:reply:)` request
/// (docs/helper.md "Charge limit (CHWA)").
///
/// - The only key is `CHWA` (`ui8`, 1 byte): `1` = the firmware holds the battery
///   at 80 %, `0` = normal charging (the firmware default). No other key and no
///   other value can be written through this path, and `CHWA` cannot be written
///   through the generic `writeKey` path (it is not in
///   `FanControlHelperConstants.allowedWriteKeyPatterns`).
/// - The charge limit is **not** part of the fan write session: no session is
///   needed, nothing is snapshotted, and it is not reverted when a session closes,
///   the client disappears or the helper exits. It is a persistent preference that
///   lives in the SMC (an SMC reset is expected to clear it back to `0`).
///
/// `SessionRegistry`-independent glue in the helper (`ChargeLimitService`) calls
/// `apply`; the decision logic is tested here with closures (`FanControlXPCTests`).
public enum ChargeLimitPolicy {

    /// The SMC key (Apple Silicon battery-management firmware, community-documented;
    /// not documented by Apple).
    public static let key: SMCKey = "CHWA"
    /// Exactly the keys the charge-limit request may write: `["CHWA"]`.
    public static let allowedKeys: Set<String> = ["CHWA"]
    /// Exactly the values that may be written: 0 (normal charging) and 1 (hold at 80 %).
    public static let allowedValues: Set<UInt8> = [0, 1]
    /// The level the firmware holds the battery at while `CHWA` = 1. Fixed by the
    /// firmware; not configurable.
    public static let limitPercent = 80
    /// Read-back value reported when it is unknown (`setChargeLimitEnabled` reply).
    public static let unknownValue = -1

    /// `true` only for `"CHWA"`.
    public static func isKeyAllowed(_ name: String) -> Bool {
        allowedKeys.contains(name)
    }

    /// The payload for `enabled`: `[1]` or `[0]`.
    public static func bytes(enabled: Bool) -> [UInt8] {
        [enabled ? 1 : 0]
    }

    /// `true` for `[1]`, `false` for `[0]`, `nil` for anything else (unknown state).
    public static func decode(_ bytes: [UInt8]) -> Bool? {
        guard bytes.count == 1 else { return nil }
        switch bytes[0] {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// Checks the key's metadata: 1 byte, `ui8`, readable (`0x80`) and writable
    /// (`0x40`). Returns `nil` if the key looks like the documented charge-limit key.
    /// A mismatch means the firmware's `CHWA` is not the key this code knows, so it
    /// is treated as unsupported rather than written.
    public static func validateKeyInfo(_ info: SMCKeyInfo) -> HelperWritePolicy.Rejection? {
        guard info.dataSize == 1, info.dataType == .ui8 else {
            return HelperWritePolicy.Rejection(
                code: .badRequest,
                message: "'\(key.name)' is \(info.dataType.name) with \(info.dataSize) byte(s), expected ui8 with 1 byte; not writing an unknown key layout")
        }
        guard info.isReadable, info.isWritable else {
            return HelperWritePolicy.Rejection(
                code: .badRequest,
                message: "'\(key.name)' is not readable and writable on this SMC (attributes 0x\(String(info.attributes, radix: 16)))")
        }
        return nil
    }

    /// Full validation of one write: the key must be `CHWA`, the payload exactly one
    /// byte in `allowedValues`, and the key's metadata as `validateKeyInfo` expects.
    public static func validate(_ bytes: [UInt8], for target: SMCKey, info: SMCKeyInfo) -> HelperWritePolicy.Rejection? {
        guard isKeyAllowed(target.name) else {
            return HelperWritePolicy.Rejection(code: .keyNotAllowed,
                                               message: "key '\(target.name)' is not the charge-limit key")
        }
        guard bytes.count == 1, allowedValues.contains(bytes[0]) else {
            return HelperWritePolicy.Rejection(
                code: .badRequest,
                message: "'\(target.name)' accepts only 0 or 1, got \(bytes.map { String($0) }.joined(separator: ","))")
        }
        return validateKeyInfo(info)
    }

    /// Outcome of `apply`, mapped 1:1 onto the XPC reply `(rc, value, message)`.
    public struct Outcome: Equatable, Sendable {
        public var code: FanControlHelperErrorCode
        /// Read-back value of `CHWA` (0 or 1), `unknownValue` when unknown.
        public var value: Int
        public var message: String
        /// Whether `write` was called (and succeeded).
        public var wrote: Bool

        public init(code: FanControlHelperErrorCode, value: Int, message: String, wrote: Bool) {
            self.code = code
            self.value = value
            self.message = message
            self.wrote = wrote
        }
    }

    /// Sets the charge limit: key info → validation → read current → write only if it
    /// differs → read back and verify. Never throws.
    ///
    /// - `CHWA` missing: `.invalidKey` (the app reports "unsupported").
    /// - Unexpected metadata: `.badRequest`, nothing written.
    /// - Current value other than 0/1: enabling is refused (`.badRequest`, nothing
    ///   written; the firmware is in a state this code does not know); disabling
    ///   still writes 0, the firmware default, as the escape direction.
    /// - Already in the requested state: `.ok` without a write.
    /// - Read-back differs from the request after a successful write: `.smcError`
    ///   with the read-back value.
    public static func apply(enabled: Bool,
                             keyInfo: (SMCKey) throws -> SMCKeyInfo,
                             read: (SMCKey) throws -> [UInt8],
                             write: (SMCKey, [UInt8]) throws -> Void) -> Outcome {
        func fail(_ code: FanControlHelperErrorCode, _ message: String, value: Int = unknownValue) -> Outcome {
            Outcome(code: code, value: value, message: message, wrote: false)
        }
        let info: SMCKeyInfo
        do {
            info = try keyInfo(key)
        } catch FanControlError.keyNotFound {
            return fail(.invalidKey, "'\(key.name)' does not exist on this SMC; the charge limit is not supported on this Mac")
        } catch {
            return fail(.smcError, "key info for '\(key.name)' failed: \(error)")
        }
        let payload = bytes(enabled: enabled)
        if let rejection = validate(payload, for: key, info: info) {
            return fail(rejection.code, rejection.message)
        }

        let current: Bool?
        let currentRaw: [UInt8]
        do {
            currentRaw = try read(key)
            current = decode(currentRaw)
        } catch {
            return fail(.smcError, "cannot read '\(key.name)' before writing: \(error); write refused")
        }
        if current == enabled {
            return Outcome(code: .ok, value: enabled ? 1 : 0,
                           message: "charge limit already \(enabled ? "on" : "off")", wrote: false)
        }
        if current == nil && enabled {
            let raw = currentRaw.map { String($0) }.joined(separator: ",")
            return fail(.badRequest, "'\(key.name)' holds unexpected value \(raw); refusing to enable (disabling is allowed)")
        }

        do {
            try write(key, payload)
        } catch {
            return fail(.smcError, "write to '\(key.name)' failed: \(error)")
        }

        guard let readBack = try? read(key), let state = decode(readBack) else {
            return Outcome(code: .smcError, value: unknownValue,
                           message: "wrote '\(key.name)' = \(payload[0]) but could not read it back", wrote: true)
        }
        guard state == enabled else {
            return Outcome(code: .smcError, value: state ? 1 : 0,
                           message: "wrote '\(key.name)' = \(payload[0]) but the SMC reports \(state ? 1 : 0)", wrote: true)
        }
        return Outcome(code: .ok, value: state ? 1 : 0,
                       message: "charge limit \(enabled ? "on (hold at \(limitPercent) %)" : "off")", wrote: true)
    }
}
