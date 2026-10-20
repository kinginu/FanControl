import Foundation

/// Return codes carried as the first `Int` of every helper reply
/// (`FanControlHelperErrorCode.rawValue`).
///
/// The raw values are part of the wire contract (`FanControlHelperConstants.protocolVersion`):
/// never renumber or reuse a value; add new codes at the end. A client that receives
/// an unknown code (`init(rawValue:)` returns `nil`) treats it as a failure.
public enum FanControlHelperErrorCode: Int, CaseIterable, Sendable, CustomStringConvertible {
    /// Success.
    case ok = 0
    /// Another process owns the write session.
    case notSessionOwner = 1
    /// A write or `closeSession` without an open session.
    case sessionNotOpen = 2
    /// The key is not exactly 4 ASCII characters (`readKeyInfo`: or does not exist on this SMC).
    case invalidKey = 3
    /// The key is not in the write allowlist (`FanControlHelperConstants.isWriteAllowed`).
    case keyNotAllowed = 4
    /// The helper could not open AppleSMC.
    case smcUnavailable = 5
    /// The SMC rejected the call, or a required value (e.g. fan limits) is unknown.
    case smcError = 6
    /// The payload was rejected (`HelperWritePolicy.validate`: size, value, range, attribute).
    case badRequest = 7
    // F2: Low Power Mode request (`setLowPowerMode`).
    /// An external command (pmset) failed or its read-back disagreed.
    case commandFailed = 8
    /// Too many requests in a short time (Low Power Mode: `LowPowerModeRequestHandler`).
    case rateLimited = 9

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .notSessionOwner: return "notSessionOwner"
        case .sessionNotOpen: return "sessionNotOpen"
        case .invalidKey: return "invalidKey"
        case .keyNotAllowed: return "keyNotAllowed"
        case .smcUnavailable: return "smcUnavailable"
        case .smcError: return "smcError"
        case .badRequest: return "badRequest"
        case .commandFailed: return "commandFailed"  // F2
        case .rateLimited: return "rateLimited"  // F2
        }
    }
}

#if os(macOS)

/// XPC interface vended by FanControlHelper on `FanControlHelperConstants.machServiceName`.
///
/// ## Wire contract
///
/// Only plain property-list types cross the connection (`Int`, `String`, `Data`,
/// `UInt32`, `UInt8`); there are no archived / `Codable` / `NSSecureCoding` payloads,
/// so no class allow-lists are needed on the interface and the whole contract is
/// versioned by one number, `FanControlHelperConstants.protocolVersion`, returned
/// by `version(reply:)`:
///
/// - every reply starts with an `Int` return code (`FanControlHelperErrorCode`) and
///   ends with a human-readable message (for logs, not for parsing);
/// - only a single client, the session owner, may write;
/// - the helper is the safety authority: it re-validates every write
///   (`isWriteAllowed`, `HelperWritePolicy.validate`) and restores automatic
///   control when the owner closes the session or disappears.
///
/// Bump `protocolVersion` when a selector, an argument / reply type, the meaning of
/// a return code or the allowlist semantics change. Adding a method is also a bump:
/// an old helper would not implement it.
///
/// | Version | Change |
/// |---|---|
/// | 1 | Initial contract: `version`, `openSession`, `writeKey`, `closeSession`, `readKeyInfo`; allowlist `F<n>Tg`, `F<n>Md` |
/// | 2 | F1: `setChargeLimitEnabled(_:reply:)` (`CHWA` only, values 0/1, no session, never restored; `ChargeLimitPolicy`). F2: `setLowPowerMode(battery:ac:reply:)` (fixed-argv pmset `-a`/`-b`/`-c lowpowermode 0\|1`, no session); codes `8 commandFailed`, `9 rateLimited` |
///
/// The ObjC selectors (`versionWithReply:`, `openSessionWithReply:`,
/// `writeKey:bytes:reply:`, `closeSessionWithReply:`, `readKeyInfo:reply:`) are
/// pinned by `FanControlXPCTests` so a rename cannot slip through unversioned.
@objc public protocol FanControlHelperProtocol {
    /// Replies with (`FanControlHelperConstants.protocolVersion` of the helper, build string).
    /// Needs no session; the app calls it first on every new connection.
    func version(reply: @escaping (Int, String) -> Void)
    /// Opens the exclusive write session for the calling process (re-opening by the
    /// owner, or by a new connection of the same pid, succeeds). Replies
    /// (`FanControlHelperErrorCode`, message).
    func openSession(reply: @escaping (Int, String) -> Void)
    /// Writes the raw SMC payload `bytes` (1…32 bytes, encoded for the key's data type
    /// as `SMCCodec.encode` does; e.g. little-endian `flt` for `F<n>Tg` on Apple
    /// Silicon) to an allowlisted key. Requires an open session. Replies
    /// (`FanControlHelperErrorCode`, message).
    func writeKey(_ key: String, bytes: Data, reply: @escaping (Int, String) -> Void)
    /// Closes the write session owned by the calling process and restores automatic
    /// control (`HelperWritePolicy.restore`). Replies (`FanControlHelperErrorCode`, message).
    func closeSession(reply: @escaping (Int, String) -> Void)
    /// Replies with (return code, data size, data type FourCC, attribute byte, message)
    /// of any key (read-only; needs no session).
    func readKeyInfo(_ key: String, reply: @escaping (Int, Int, UInt32, UInt8, String) -> Void)
    // F1: charge limit (protocol v2). Not part of the fan write session: needs no open
    // session and is never reverted by the helper (docs/helper.md "Charge limit (CHWA)").
    /// Writes `CHWA` = 1 (`enabled`, hold at 80 %) or 0 (`ChargeLimitPolicy.apply`) and
    /// replies with (rc, read-back value 0/1 or -1, message).
    func setChargeLimitEnabled(_ enabled: Bool, reply: @escaping (Int, Int, String) -> Void)

    // F2: Low Power Mode (protocol version 2). Runs `/usr/bin/pmset -a lowpowermode 0|1` (both
    // values equal) or `-b` / `-c lowpowermode 0|1` (per power source) with a fixed argv and
    // reads the settings back (`LowPowerModeRequestHandler`). No session required: it changes
    // a system setting, not a fan; the connection is already code-signing checked.
    /// Sets Low Power Mode on battery power and on AC power. Replies (rc, message).
    func setLowPowerMode(battery: Bool, ac: Bool, reply: @escaping (Int, String) -> Void)
}

/// Builds the `NSXPCInterface` used on both sides of the connection.
public func makeHelperInterface() -> NSXPCInterface {
    NSXPCInterface(with: FanControlHelperProtocol.self)
}
#endif
