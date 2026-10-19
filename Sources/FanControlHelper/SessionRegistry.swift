#if os(macOS)
import Foundation
import FanControlCore
import FanControlSMC
import FanControlXPC

/// Identity of a client connection. The session belongs to the XPC connection that
/// opened it; the pid is kept for liveness checks and logging.
struct SessionOwner: Equatable, Sendable {
    let pid: pid_t
    let connectionID: UInt64
}

/// Result of a registry operation, mapped 1:1 onto XPC replies.
struct HelperResult {
    var code: FanControlHelperErrorCode
    var message: String

    static func ok(_ message: String = "ok") -> HelperResult { HelperResult(code: .ok, message: message) }
}

/// Single-owner SMC write session (design doc §5.3).
///
/// - Only one connection may own the session at a time; others get `notSessionOwner`.
/// - A session whose owner process no longer exists is reclaimed automatically.
/// - The SMC connection is held only while a session is open.
/// - The original bytes of every key written during the session are recorded before
///   the first write (a write is refused if that snapshot cannot be taken). When the
///   session closes or the owner disappears, speed keys (`F<n>Tg`, `F<n>Mn`) are
///   restored to their snapshot and mode keys are forced back to automatic
///   (`F<n>Md` = 0, `FS! ` = snapshot with this session's bits cleared), so a crashed
///   client cannot leave fans pinned in manual mode.
/// - Written values are validated here (the helper is the safety authority): see
///   `validateLocked(_:for:info:)`.
public final class SessionRegistry: @unchecked Sendable {
    public static let shared = SessionRegistry()

    /// Allowed slack (RPM) below the hardware minimum / above the maximum, to absorb
    /// client-side rounding of fractional `F<n>Mn` / `F<n>Mx` values.
    static let rpmTolerance: Double = 1

    private let lock = NSLock()
    private var owner: SessionOwner?
    private var openedAt: Date?
    private var client: SMCClient?
    /// Original values captured before the first write of each key in this session, in write order.
    private var originals: [(key: SMCKey, bytes: [UInt8])] = []
    /// `FNum` read at session open (`nil` if unreadable).
    private var fanCount: Int?
    /// Hardware `F<n>Mn...F<n>Mx` per fan, read at session open (before any write can
    /// change `F<n>Mn`). Fans missing here cannot have speed keys written.
    private var fanLimits: [Int: ClosedRange<Double>] = [:]
    /// `FS! ` bits this session has set; cleared from the snapshot on restore.
    private var touchedForceBits: UInt64 = 0

    private init() {}

    func open(for requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        if let current = owner {
            if current == requester {
                return .ok("session already open")
            }
            if Self.isProcessAlive(current.pid) {
                return HelperResult(code: .notSessionOwner,
                                    message: "session is owned by pid \(current.pid) since \(openedAt.map { "\($0)" } ?? "?")")
            }
            helperLog.notice("Reclaiming session from dead pid \(current.pid, privacy: .public)")
            endSessionLocked()
        }

        let newClient: SMCClient
        do {
            newClient = try SMCClient()
        } catch {
            return HelperResult(code: .smcUnavailable, message: "cannot open AppleSMC: \(error)")
        }
        owner = requester
        openedAt = Date()
        client = newClient
        originals = []
        touchedForceBits = 0
        readHardwareLimitsLocked(using: newClient)
        helperLog.info("Session opened by pid \(requester.pid, privacy: .public) (connection \(requester.connectionID, privacy: .public))")
        return .ok("session opened")
    }

    /// Writes `bytes` to `key`. Caller has already validated the key against the allowlist
    /// and the byte count against 1...32.
    func write(_ bytes: [UInt8], to key: SMCKey, from requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        guard let current = owner, let client else {
            return HelperResult(code: .sessionNotOpen, message: "no session is open")
        }
        guard current == requester else {
            return HelperResult(code: .notSessionOwner, message: "session is owned by pid \(current.pid)")
        }

        let info: SMCKeyInfo
        do {
            info = try client.keyInfo(key)
        } catch FanControlError.keyNotFound {
            return HelperResult(code: .invalidKey, message: "key '\(key.name)' does not exist on this SMC")
        } catch {
            return HelperResult(code: .smcError, message: "key info for '\(key.name)' failed: \(error)")
        }
        guard info.dataSize == bytes.count else {
            return HelperResult(code: .badRequest,
                                message: "key '\(key.name)' expects \(info.dataSize) bytes, got \(bytes.count)")
        }
        if let rejection = validateLocked(bytes, for: key, info: info) {
            return rejection
        }

        if !originals.contains(where: { $0.key == key }) {
            // Without a snapshot the key could not be restored on close: refuse the write.
            let original: [UInt8]
            do {
                original = try client.readBytes(key)
            } catch {
                return HelperResult(code: .smcError,
                                    message: "cannot snapshot original value of '\(key.name)': \(error); write refused")
            }
            guard original.count == info.dataSize else {
                return HelperResult(code: .smcError,
                                    message: "snapshot of '\(key.name)' has \(original.count) bytes, expected \(info.dataSize); write refused")
            }
            originals.append((key, original))
        }
        if key == .forceBits, let bits = Self.forceBits(of: bytes, type: info.dataType) {
            // Recorded before the write: if the SMC applied it despite an error, restore still clears it.
            touchedForceBits |= bits
        }

        do {
            try client.writeBytes(bytes, to: key)
        } catch {
            return HelperResult(code: .smcError, message: "write to '\(key.name)' failed: \(error)")
        }
        return .ok()
    }

    func close(for requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        guard let current = owner else {
            return HelperResult(code: .sessionNotOpen, message: "no session is open")
        }
        guard current == requester else {
            return HelperResult(code: .notSessionOwner, message: "session is owned by pid \(current.pid)")
        }
        endSessionLocked()
        return .ok("session closed")
    }

    /// Ends any open session and restores fans (SIGTERM / helper shutdown).
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard owner != nil || client != nil else { return }
        helperLog.notice("Helper shutting down; ending session and restoring fans")
        endSessionLocked()
    }

    /// Called when a connection is invalidated/interrupted. No-op unless `owner` holds the session.
    func release(owner released: SessionOwner) {
        lock.lock()
        defer { lock.unlock() }
        guard owner == released else { return }
        helperLog.notice("Owner pid \(released.pid, privacy: .public) went away; releasing session")
        endSessionLocked()
    }

    /// Key info lookup; uses the session's SMC connection if open, else a temporary one.
    func keyInfo(_ key: SMCKey) -> Result<SMCKeyInfo, FanControlError> {
        lock.lock()
        defer { lock.unlock() }
        do {
            let reader = try client ?? SMCClient()
            defer { if reader !== client { reader.close() } }
            return .success(try reader.keyInfo(key))
        } catch let error as FanControlError {
            return .failure(error)
        } catch {
            return .failure(.smcUnavailable)
        }
    }

    // MARK: Private (lock held)

    private func endSessionLocked() {
        if let client {
            restoreOriginalsLocked(using: client)
            client.close()
        }
        if let owner, let openedAt {
            helperLog.info("Session of pid \(owner.pid, privacy: .public) closed after \(Int(Date().timeIntervalSince(openedAt)), privacy: .public)s")
        }
        owner = nil
        openedAt = nil
        client = nil
        originals = []
        touchedForceBits = 0
        fanCount = nil
        fanLimits = [:]
    }

    /// Restores state: speed keys (`F<n>Tg`, `F<n>Mn`) to their snapshot first, then
    /// mode keys to automatic (`F<n>Md` = 0, `FS! ` = snapshot minus this session's
    /// bits), so automatic control is re-enabled only after targets/minimums are back.
    /// Mode keys are not restored to their snapshot: a snapshot taken while a previous
    /// (crashed) session had fans forced would otherwise re-pin them. A failed mode-key
    /// restore is retried once.
    private func restoreOriginalsLocked(using client: SMCClient) {
        let speed = originals.filter { !Self.isModeKey($0.key) }
        let mode = originals.filter { Self.isModeKey($0.key) }
        for entry in speed {
            do {
                try client.writeBytes(entry.bytes, to: entry.key)
            } catch {
                helperLog.error("Failed to restore \(entry.key.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for entry in mode {
            let value: [UInt8]
            if entry.key == .forceBits {
                value = Self.clearingBits(touchedForceBits, in: entry.bytes)
            } else {
                value = [UInt8](repeating: 0, count: entry.bytes.count)
            }
            for attempt in 1...2 {
                do {
                    try client.writeBytes(value, to: entry.key)
                    break
                } catch {
                    helperLog.error("Failed to restore mode key \(entry.key.name, privacy: .public) (attempt \(attempt, privacy: .public)): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Reads `FNum` and every fan's hardware `F<n>Mn` / `F<n>Mx` into the session cache.
    private func readHardwareLimitsLocked(using client: SMCClient) {
        fanCount = nil
        fanLimits = [:]
        guard let rawCount = try? client.readNumber(.fanCount), rawCount.isFinite, rawCount >= 0 else {
            helperLog.error("Cannot read FNum; FS! writes will be refused")
            return
        }
        let count = Int(min(rawCount, 10))
        fanCount = count
        for i in 0..<count {
            guard let lo = try? client.readNumber(.fanMin(i)), let hi = try? client.readNumber(.fanMax(i)),
                  lo.isFinite, hi.isFinite, lo <= hi else {
                helperLog.error("Cannot read hardware Mn/Mx of fan \(i, privacy: .public); its speed writes will be refused")
                continue
            }
            fanLimits[i] = lo...hi
        }
    }

    /// Value checks for an allowlisted key. Returns `nil` if the write may proceed.
    ///
    /// - `F<n>Md`: 0 or 1.
    /// - `F<n>Tg`, `F<n>Mn`: within the fan's hardware `F<n>Mn...F<n>Mx` read at session
    ///   open (± `rpmTolerance`); `.smcError` if those limits are unknown.
    /// - `FS! `: no bit at or above `1 << FNum`; `.smcError` if `FNum` is unknown.
    private func validateLocked(_ bytes: [UInt8], for key: SMCKey, info: SMCKeyInfo) -> HelperResult? {
        func bad(_ message: String) -> HelperResult { HelperResult(code: .badRequest, message: message) }
        let name = key.name

        if key == .forceBits {
            guard let count = fanCount else {
                return HelperResult(code: .smcError, message: "fan count (FNum) unknown; refusing to write 'FS! '")
            }
            guard let bits = Self.forceBits(of: bytes, type: info.dataType) else {
                return bad("'FS! ' payload is not a non-negative integer bitmask")
            }
            let limit: UInt64 = count >= 64 ? .max : (UInt64(1) << UInt64(count))
            guard bits < limit else {
                return bad("'FS! ' bitmask 0x\(String(bits, radix: 16)) has bits for fans >= FNum (\(count))")
            }
            return nil
        }

        let chars = Array(name)
        guard chars.count == 4, chars[0] == "F", let fan = chars[1].wholeNumberValue else {
            return bad("unexpected key '\(name)'")
        }
        let suffix = String(chars[2...])
        guard let number = SMCCodec.decode(bytes, as: info.dataType)?.doubleValue, number.isFinite else {
            return bad("'\(name)' payload does not decode to a finite number as \(info.dataType.name)")
        }
        switch suffix {
        case "Md":
            guard number == 0 || number == 1 else {
                return bad("'\(name)' must be 0 or 1, got \(number)")
            }
        case "Tg", "Mn":
            guard let limits = fanLimits[fan] else {
                return HelperResult(code: .smcError,
                                    message: "hardware min/max of fan \(fan) unknown; refusing to write '\(name)'")
            }
            guard number >= limits.lowerBound - Self.rpmTolerance,
                  number <= limits.upperBound + Self.rpmTolerance else {
                return bad("'\(name)' = \(number) RPM is outside fan \(fan)'s hardware range \(limits.lowerBound)...\(limits.upperBound)")
            }
        default:
            return bad("unexpected key '\(name)'")
        }
        return nil
    }

    private static func isModeKey(_ key: SMCKey) -> Bool {
        let name = key.name
        return key == .forceBits || (name.hasPrefix("F") && name.hasSuffix("Md"))
    }

    /// Decodes an `FS! ` payload as an unsigned bitmask (numeric types via `SMCCodec`,
    /// raw/hex types as a big-endian integer). `nil` if negative, fractional or > 8 bytes.
    static func forceBits(of bytes: [UInt8], type: SMCDataType) -> UInt64? {
        switch SMCCodec.decode(bytes, as: type) {
        case .number(let value):
            guard value.isFinite, value >= 0, value.rounded() == value, value < 18_446_744_073_709_551_616 else { return nil }
            return UInt64(value)
        case .bytes(let raw):
            guard raw.count <= 8 else { return nil }
            return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case .flag(let on):
            return on ? 1 : 0
        case .string, nil:
            return nil
        }
    }

    /// `bytes` read as a big-endian integer with `mask` cleared, re-serialised at the same width.
    static func clearingBits(_ mask: UInt64, in bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for i in 0..<out.count {
            let shift = (out.count - 1 - i) * 8
            guard shift < 64 else { continue }
            out[i] &= ~UInt8(truncatingIfNeeded: mask >> UInt64(shift))
        }
        return out
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
#endif
