import FanControlCore

/// The desired control state of one fan, as fed to `FanWriteStrategy.writes(for:)`.
public enum FanTarget: Hashable, Sendable {
    /// Hand the fan back to the SMC.
    case automatic
    /// Force the fan to `rpm` (the caller validates/clamps the value).
    case manual(rpm: Int)
}

/// SMC write sequences for switching fans between automatic and manual control.
/// **Apple Silicon only** (Intel support dropped 2026-10-20):
///
/// - each fan has a mode key `F<i>Md` (`ui8`, 0 = automatic, 1 = forced);
/// - targets `F<i>Tg` are written with the type/size reported by `keyInfo`
///   (`flt ` on Apple Silicon).
///
/// A fan that has `F<i>Tg` but no `F<i>Md` is **not** controllable: it is
/// listed in `fansMissingModeKey`, and `writes(for:)` throws
/// `FanControlError.fanModeKeyMissing` for it instead of falling back to a
/// target-only or Intel `FS! ` scheme (both removed).
///
/// **Order matters**: every write list puts the `F<i>Md` writes *before* the
/// `F<i>Tg` writes. While a fan is in automatic mode the SMC owns `F<i>Tg` and
/// overwrites (or rejects) a target written before the fan is forced.
///
/// The type is pure apart from reads through the supplied `SMCReader` at init,
/// so it is unit-tested with a mock reader. It is not thread-safe; use it from
/// the same queue that owns the reader.
///
/// Mac14,9 / macOS 26 (dump in `docs/verification/`): `F<i>Md` is `ui8 `
/// (attr 0xd0) and `F<i>Tg` is little-endian `flt ` (attr 0xd4); `FS! ` and
/// `Ftst` are absent. Writes verified on hardware
/// (`docs/verification/first-write-2026-10-20.md`).
public struct FanWriteStrategy {

    /// Per-fan write metadata gathered at init.
    public struct FanWriteInfo: Hashable, Sendable {
        public let fan: Int
        /// `keyInfo(F<i>Tg)` (type + size used to encode targets).
        public let target: SMCKeyInfo
        /// `keyInfo(F<i>Md)` (type + size used to encode the mode).
        public let mode: SMCKeyInfo
        /// Hardware `F<i>Mn...F<i>Mx` read at init (`nil` if unreadable). Manual
        /// targets outside it (± `rpmTolerance`) are refused by `writes(for:)`
        /// before any write is produced, because the helper would reject the
        /// `F<i>Tg` write *after* the mode write had already forced the fan.
        public var rpmLimits: ClosedRange<Double>? = nil
    }

    /// Same slack as the helper (`HelperWritePolicy.rpmTolerance`).
    public static let rpmTolerance: Double = 1

    /// Metadata per controllable fan index (both `F<i>Tg` and `F<i>Md` have key
    /// info). Other fans are absent.
    public let fans: [Int: FanWriteInfo]
    /// Fans that have `F<i>Tg` but no `F<i>Md`: not controllable on the only
    /// supported (Apple Silicon) scheme; `writes(for:)` throws
    /// `.fanModeKeyMissing` for them.
    public let fansMissingModeKey: Set<Int>

    /// Probes the reader for every fan index in `fanIndices` (0...9).
    public init(reader: SMCReader, fanIndices: [Int]) {
        var fans: [Int: FanWriteInfo] = [:]
        var missing = Set<Int>()
        for index in fanIndices where (0...9).contains(index) {
            guard let target = try? reader.keyInfo(.fanTarget(index)) else { continue }
            guard let mode = try? reader.keyInfo(.fanMode(index)) else {
                missing.insert(index)
                continue
            }
            var limits: ClosedRange<Double>?
            if let lo = try? reader.readNumber(.fanMin(index)), let hi = try? reader.readNumber(.fanMax(index)),
               lo.isFinite, hi.isFinite, lo <= hi {
                limits = lo...hi
            }
            fans[index] = FanWriteInfo(fan: index, target: target, mode: mode, rpmLimits: limits)
        }
        self.fans = fans
        self.fansMissingModeKey = missing
    }

    /// Convenience: probes every fan in `fans`.
    public init(reader: SMCReader, fans: [FanDevice]) {
        self.init(reader: reader, fanIndices: fans.map(\.id))
    }

    /// Writes that force `fan` to `rpm`: `[F<i>Md ← 1, F<i>Tg ← rpm]`.
    public func setManual(fan: Int, rpm: Int) throws -> [(SMCKey, [UInt8])] {
        try writes(for: [fan: .manual(rpm: rpm)])
    }

    /// Writes that return `fan` to automatic control: `[F<i>Md ← 0]`.
    public func setAutomatic(fan: Int) throws -> [(SMCKey, [UInt8])] {
        try writes(for: [fan: .automatic])
    }

    /// Combined write list for several fans, in this order:
    /// 1. `F<i>Md` writes (ascending fan index),
    /// 2. `F<i>Tg` writes for manual fans (ascending fan index).
    ///
    /// Throws `.fanModeKeyMissing(fan:)` for a fan without `F<i>Md`,
    /// `.keyNotFound("F<i>Tg")` for an unknown fan, `.rpmOutOfRange` for a
    /// manual target outside the fan's hardware `F<i>Mn...F<i>Mx` (when known),
    /// and `.unsupportedDataType` if a value cannot be encoded as the key's
    /// type. Nothing is returned on a throw, so a list is never started that
    /// the helper would reject half-way.
    public func writes(for targets: [Int: FanTarget]) throws -> [(SMCKey, [UInt8])] {
        var modeWrites: [(SMCKey, [UInt8])] = []
        var targetWrites: [(SMCKey, [UInt8])] = []

        for fan in targets.keys.sorted() {
            if fansMissingModeKey.contains(fan) {
                throw FanControlError.fanModeKeyMissing(fan: fan)
            }
            guard let info = fans[fan], let target = targets[fan] else {
                throw FanControlError.keyNotFound(Self.keyName(fan, "Tg"))
            }
            switch target {
            case .automatic:
                modeWrites.append((.fanMode(fan), try Self.encode(0, as: info.mode, key: .fanMode(fan))))
            case .manual(let rpm):
                if let limits = info.rpmLimits,
                   Double(rpm) < limits.lowerBound - Self.rpmTolerance
                    || Double(rpm) > limits.upperBound + Self.rpmTolerance {
                    let allowed = Int(limits.lowerBound.rounded(.up))...Int(limits.upperBound.rounded(.down))
                    throw FanControlError.rpmOutOfRange(fan: fan, rpm: rpm, allowed: allowed)
                }
                modeWrites.append((.fanMode(fan), try Self.encode(1, as: info.mode, key: .fanMode(fan))))
                targetWrites.append((.fanTarget(fan), try Self.encode(Double(rpm), as: info.target, key: .fanTarget(fan))))
            }
        }
        return modeWrites + targetWrites
    }

    /// Writes that undo a write list for `pending` that failed part-way: every
    /// fan that was to be forced (`.manual`) is returned to automatic
    /// (`[F<i>Md ← 0]`). Fans that were to become automatic need nothing.
    /// Uncontrollable fans are skipped instead of throwing, so a partial
    /// rollback is still produced.
    public func rollbackWrites(afterFailureOf pending: [Int: FanTarget]) throws -> [(SMCKey, [UInt8])] {
        var targets: [Int: FanTarget] = [:]
        for (fan, target) in pending where fans[fan] != nil {
            if case .manual = target { targets[fan] = .automatic }
        }
        guard !targets.isEmpty else { return [] }
        return try writes(for: targets)
    }

    // MARK: - Helpers

    private static func encode(_ value: Double, as info: SMCKeyInfo, key: SMCKey) throws -> [UInt8] {
        guard let bytes = SMCCodec.encode(value, as: info.dataType, size: info.dataSize) else {
            throw FanControlError.unsupportedDataType("\(info.dataType.name) (\(key.name), \(info.dataSize) bytes)")
        }
        return bytes
    }

    private static func keyName(_ fan: Int, _ suffix: String) -> String {
        "F\(fan)\(suffix)"
    }
}
