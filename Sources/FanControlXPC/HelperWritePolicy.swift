import Foundation
import FanControlCore

/// Platform-neutral write rules of FanControlHelper: value validation of an
/// allowlisted write and the restore sequence run when a session ends.
///
/// `SessionRegistry` (helper executable, not unit-testable) holds the session
/// state and the AppleSMC connection and delegates every decision to this
/// type, which is tested with a recording writer (`FanControlXPCTests`).
public enum HelperWritePolicy {

    /// Allowed slack (RPM) below the hardware minimum / above the maximum, to absorb
    /// client-side rounding of fractional `F<n>Mn` / `F<n>Mx` values.
    public static let rpmTolerance: Double = 1

    /// A rejected write: the helper reply code and message.
    public struct Rejection: Error, Equatable, Sendable {
        public var code: FanControlHelperErrorCode
        public var message: String

        public init(code: FanControlHelperErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: - Validation

    /// Value checks for an allowlisted key (the key name and the 1...32 byte count
    /// were checked by the caller). Returns `nil` if the write may proceed.
    ///
    /// - The key must report the write attribute (`SMCKeyInfo.isWritable`,
    ///   `0x40`); e.g. `F<n>Mn` on Apple Silicon (`0x84`) is refused here.
    /// - `bytes.count` must equal `info.dataSize`.
    /// - `F<n>Md`: 0 or 1.
    /// - `F<n>Tg`, `F<n>Mn`: within the fan's hardware `F<n>Mn...F<n>Mx` read at
    ///   session open (± `rpmTolerance`); `.smcError` if those limits are unknown.
    /// - `FS! `: no bit at or above `1 << FNum`; `.smcError` if `FNum` is unknown.
    public static func validate(_ bytes: [UInt8], for key: SMCKey, info: SMCKeyInfo,
                                fanCount: Int?, fanLimits: [Int: ClosedRange<Double>]) -> Rejection? {
        func bad(_ message: String) -> Rejection { Rejection(code: .badRequest, message: message) }
        let name = key.name

        guard info.dataSize == bytes.count else {
            return bad("key '\(name)' expects \(info.dataSize) bytes, got \(bytes.count)")
        }
        guard info.isWritable else {
            return bad("key '\(name)' is not writable on this SMC (attributes 0x\(String(info.attributes, radix: 16)))")
        }

        if key == .forceBits {
            guard let count = fanCount else {
                return Rejection(code: .smcError, message: "fan count (FNum) unknown; refusing to write 'FS! '")
            }
            guard let bits = forceBits(of: bytes, type: info.dataType) else {
                return bad("'FS! ' payload is not a non-negative integer bitmask")
            }
            let limit: UInt64 = count >= 64 ? .max : (UInt64(1) << UInt64(count))
            guard bits < limit else {
                return bad("'FS! ' bitmask 0x\(String(bits, radix: 16)) has bits for fans >= FNum (\(count))")
            }
            return nil
        }

        guard let (fan, suffix) = fanKeyParts(key) else {
            return bad("unexpected key '\(name)'")
        }
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
                return Rejection(code: .smcError,
                                 message: "hardware min/max of fan \(fan) unknown; refusing to write '\(name)'")
            }
            guard number >= limits.lowerBound - rpmTolerance,
                  number <= limits.upperBound + rpmTolerance else {
                return bad("'\(name)' = \(number) RPM is outside fan \(fan)'s hardware range \(limits.lowerBound)...\(limits.upperBound)")
            }
        default:
            return bad("unexpected key '\(name)'")
        }
        return nil
    }

    // MARK: - Restore

    /// One write performed (or attempted) by `restore`.
    public struct RestoreWrite: Equatable, Sendable {
        public var key: SMCKey
        public var bytes: [UInt8]
        public var succeeded: Bool

        public init(key: SMCKey, bytes: [UInt8], succeeded: Bool) {
            self.key = key
            self.bytes = bytes
            self.succeeded = succeeded
        }
    }

    /// Returns control to the SMC at the end of a session. Never throws; every
    /// failure is reported through `log` and in the returned list.
    ///
    /// Order (pre-write review 2026-10-20, `docs/verification/pre-write-review-2026-10-20.md`):
    /// 1. `F<n>Mn` (Intel "min = target" technique) back to its snapshot.
    /// 2. Mode keys to automatic, each tried up to twice: `F<n>Md` = 0,
    ///    `FS! ` = snapshot with this session's bits (`touchedForceBits`) cleared.
    ///    Mode keys are not restored to their snapshot: a snapshot taken while a
    ///    previous (crashed) session had fans forced would otherwise re-pin them.
    /// 3. `F<n>Tg` only for fans that have **no** mode mechanism in this session
    ///    (target-only fans), clamped into the hardware `Mn...Mx`.
    ///
    /// `F<n>Tg` of a fan whose mode key was handed back is **not** written: in
    /// automatic mode the SMC owns the target, and on Apple Silicon the idle
    /// snapshot is `Tg` = 0 (below `Mn`), which written while `F<n>Md` = 1 would
    /// command the fan to stop. If the mode restore fails, `F<n>Tg` is left at the
    /// last validated target (within `Mn...Mx`) rather than written to the snapshot.
    @discardableResult
    public static func restore(originals: [(key: SMCKey, bytes: [UInt8])],
                               touchedForceBits: UInt64,
                               fanLimits: [Int: ClosedRange<Double>],
                               keyInfo: (SMCKey) -> SMCKeyInfo?,
                               write: (SMCKey, [UInt8]) throws -> Void,
                               log: (String) -> Void = { _ in }) -> [RestoreWrite] {
        var performed: [RestoreWrite] = []

        func attempt(_ key: SMCKey, _ bytes: [UInt8], tries: Int) -> Bool {
            for n in 1...max(tries, 1) {
                do {
                    try write(key, bytes)
                    performed.append(RestoreWrite(key: key, bytes: bytes, succeeded: true))
                    return true
                } catch {
                    performed.append(RestoreWrite(key: key, bytes: bytes, succeeded: false))
                    log("Failed to restore \(key.name) (attempt \(n)): \(error)")
                }
            }
            return false
        }

        // 1. Minimum speeds (original values are safe by definition).
        for entry in originals where fanKeyParts(entry.key)?.suffix == "Mn" {
            _ = attempt(entry.key, entry.bytes, tries: 1)
        }

        // 2. Mode keys -> automatic. Fans with a mode mechanism in this session:
        var modeControlledFans = Set<Int>()
        for entry in originals {
            if entry.key == .forceBits {
                modeControlledFans.formUnion((0..<64).filter { touchedForceBits & (UInt64(1) << UInt64($0)) != 0 })
                let value = clearingBits(touchedForceBits, in: entry.bytes)
                if !attempt(entry.key, value, tries: 2) {
                    log("FS! could not be cleared; forced fans stay at their last target")
                }
            } else if let (fan, suffix) = fanKeyParts(entry.key), suffix == "Md" {
                modeControlledFans.insert(fan)
                if !attempt(entry.key, [UInt8](repeating: 0, count: entry.bytes.count), tries: 2) {
                    log("\(entry.key.name) could not be set to automatic; fan \(fan) stays at its last target")
                }
            }
        }

        // 3. Targets of fans without a mode mechanism (target-only), clamped.
        for entry in originals {
            guard let (fan, suffix) = fanKeyParts(entry.key), suffix == "Tg",
                  !modeControlledFans.contains(fan) else { continue }
            var value = entry.bytes
            if let info = keyInfo(entry.key), let limits = fanLimits[fan],
               let number = SMCCodec.decode(entry.bytes, as: info.dataType)?.doubleValue {
                let clamped = number.isFinite ? min(max(number, limits.lowerBound), limits.upperBound) : limits.upperBound
                if clamped != number,
                   let encoded = SMCCodec.encode(clamped, as: info.dataType, size: info.dataSize) {
                    log("Snapshot of \(entry.key.name) (\(number) RPM) is outside \(limits); restoring \(clamped)")
                    value = encoded
                }
            }
            _ = attempt(entry.key, value, tries: 1)
        }
        return performed
    }

    // MARK: - Helpers

    /// `(fan index, two-character suffix)` for `F<digit><xx>` keys (not `FS! `).
    static func fanKeyParts(_ key: SMCKey) -> (fan: Int, suffix: String)? {
        let chars = Array(key.name)
        guard chars.count == 4, chars[0] == "F", let fan = chars[1].wholeNumberValue,
              chars[1].isASCII else { return nil }
        return (fan, String(chars[2...]))
    }

    /// `true` for `FS! ` and `F<n>Md`.
    public static func isModeKey(_ key: SMCKey) -> Bool {
        key == .forceBits || fanKeyParts(key)?.suffix == "Md"
    }

    /// Decodes an `FS! ` payload as an unsigned bitmask (numeric types via `SMCCodec`,
    /// raw/hex types as a big-endian integer). `nil` if negative, fractional or > 8 bytes.
    public static func forceBits(of bytes: [UInt8], type: SMCDataType) -> UInt64? {
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

    /// The `FS! ` bits a write newly sets relative to the session's snapshot: `written & ~snapshot`.
    /// Bits already set before the session (by the SMC or another tool) are not the session's,
    /// so `restore` / power hand-back must not clear them. `nil` if either payload does not decode.
    public static func newlySetForceBits(written: [UInt8], snapshot: [UInt8], type: SMCDataType) -> UInt64? {
        guard let bits = forceBits(of: written, type: type),
              let before = forceBits(of: snapshot, type: type) else { return nil }
        return bits & ~before
    }

    /// `bytes` read as a big-endian integer with `mask` cleared, re-serialised at the same width.
    public static func clearingBits(_ mask: UInt64, in bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for i in 0..<out.count {
            let shift = (out.count - 1 - i) * 8
            guard shift < 64 else { continue }
            out[i] &= ~UInt8(truncatingIfNeeded: mask >> UInt64(shift))
        }
        return out
    }
}
