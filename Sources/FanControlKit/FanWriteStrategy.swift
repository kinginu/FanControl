import FanControlCore

/// The desired control state of one fan, as fed to `FanWriteStrategy.writes(for:)`.
public enum FanTarget: Hashable, Sendable {
    /// Hand the fan back to the SMC.
    case automatic
    /// Force the fan to `rpm` (the caller validates/clamps the value).
    case manual(rpm: Int)
}

/// Platform-specific SMC write sequences for switching fans between automatic
/// and manual control (design doc §5.7).
///
/// Two schemes are publicly known:
/// - **Apple Silicon** (and some late Intel models): each fan has a mode key
///   `F<i>Md` (`ui8`, 0 = automatic, 1 = forced). Targets `F<i>Tg` are `flt `.
/// - **Intel**: a single `FS! ` bitmask (`ui16`), bit *i* = fan *i* forced.
///   Targets `F<i>Tg` are `fpe2`.
///
/// The strategy is detected per fan from key presence (`F<i>Md` first, then
/// `FS! `) and the data type/size of `F<i>Tg` from `keyInfo`, so it does not
/// hard-code the CPU architecture.
///
/// **Order matters**: every write list puts the mode writes (`F<i>Md` /
/// `FS! `) *before* the target writes (`F<i>Tg`). While a fan is in automatic
/// mode the SMC owns `F<i>Tg` and overwrites (or rejects) a target written
/// before the fan is forced.
///
/// The type is pure apart from reads through the supplied `SMCReader` (key
/// info at init, the current `FS! ` mask when building Intel write lists), so
/// it is unit-tested on Linux with a mock reader. It is not thread-safe; use it
/// from the same queue that owns the reader.
///
/// Mac14,9 / macOS 26 (dump in `docs/verification/`): `FS! ` and `Ftst` are
/// absent, `F<i>Md` is `ui8 ` (attr 0xd0) and `F<i>Tg` is little-endian `flt `
/// (attr 0xd4), so every fan is `.modeKey`. Some newer Apple Silicon models are
/// reported to additionally need an unlock key (`Ftst`) before `F<i>Md`
/// sticks; that key is not in the helper's write allowlist. No write has been
/// attempted on hardware yet (`docs/verification/pre-write-review-2026-10-20.md`).
public struct FanWriteStrategy {

    /// How a fan is switched into manual mode.
    public enum ControlStyle: Hashable, Sendable {
        /// `F<i>Md` exists (Apple Silicon style).
        case modeKey
        /// `FS! ` exists (Intel style).
        case forceBits
        /// Neither exists: only `F<i>Tg` is written; returning to automatic
        /// relies on the helper restoring the original values when the write
        /// session closes.
        case targetOnly
    }

    /// Per-fan write metadata gathered at init.
    public struct FanWriteInfo: Hashable, Sendable {
        public let fan: Int
        public let style: ControlStyle
        /// `keyInfo(F<i>Tg)` (type + size used to encode targets).
        public let target: SMCKeyInfo
        /// `keyInfo(F<i>Md)` for `.modeKey` fans.
        public let mode: SMCKeyInfo?
        /// Hardware `F<i>Mn...F<i>Mx` read at init (`nil` if unreadable). Manual
        /// targets outside it (± `rpmTolerance`) are refused by `writes(for:)`
        /// before any write is produced, because the helper would reject the
        /// `F<i>Tg` write *after* the mode write had already forced the fan.
        public var rpmLimits: ClosedRange<Double>? = nil
    }

    /// Same slack as the helper (`HelperWritePolicy.rpmTolerance`).
    public static let rpmTolerance: Double = 1

    /// Metadata per fan index. Fans whose `F<i>Tg` has no key info are absent
    /// (they cannot be controlled).
    public let fans: [Int: FanWriteInfo]
    /// `keyInfo(FS! )`, if the key exists.
    public let forceBits: SMCKeyInfo?

    private let reader: SMCReader

    /// Probes the reader for every fan index in `fanIndices` (0...9).
    public init(reader: SMCReader, fanIndices: [Int]) {
        self.reader = reader
        let forceInfo = try? reader.keyInfo(.forceBits)
        self.forceBits = forceInfo
        var fans: [Int: FanWriteInfo] = [:]
        for index in fanIndices where (0...9).contains(index) {
            guard let target = try? reader.keyInfo(.fanTarget(index)) else { continue }
            let mode = try? reader.keyInfo(.fanMode(index))
            let style: ControlStyle = mode != nil ? .modeKey : (forceInfo != nil ? .forceBits : .targetOnly)
            var limits: ClosedRange<Double>?
            if let lo = try? reader.readNumber(.fanMin(index)), let hi = try? reader.readNumber(.fanMax(index)),
               lo.isFinite, hi.isFinite, lo <= hi {
                limits = lo...hi
            }
            fans[index] = FanWriteInfo(fan: index, style: style, target: target, mode: mode, rpmLimits: limits)
        }
        self.fans = fans
    }

    /// Convenience: probes every fan in `fans`.
    public init(reader: SMCReader, fans: [FanDevice]) {
        self.init(reader: reader, fanIndices: fans.map(\.id))
    }

    /// The detected style for `fan`, or `nil` if the fan cannot be controlled.
    public func style(for fan: Int) -> ControlStyle? {
        fans[fan]?.style
    }

    /// Writes that force `fan` to `rpm`: mode write first, then the target.
    /// - Apple Silicon: `[F<i>Md ← 1, F<i>Tg ← rpm]`
    /// - Intel: `[FS! ← mask | (1 << i), F<i>Tg ← rpm]` (current mask read first)
    public func setManual(fan: Int, rpm: Int) throws -> [(SMCKey, [UInt8])] {
        try writes(for: [fan: .manual(rpm: rpm)])
    }

    /// Writes that return `fan` to automatic control.
    /// - Apple Silicon: `[F<i>Md ← 0]`
    /// - Intel: `[FS! ← mask & ~(1 << i)]`
    /// - target-only fans: `[]`
    public func setAutomatic(fan: Int) throws -> [(SMCKey, [UInt8])] {
        try writes(for: [fan: .automatic])
    }

    /// Combined write list for several fans, in this order:
    /// 1. `F<i>Md` writes (ascending fan index),
    /// 2. one `FS! ` write if any Intel-style fan is involved (the mask is read
    ///    once and every requested bit applied, so fans do not clobber each other),
    /// 3. `F<i>Tg` writes for manual fans (ascending fan index).
    ///
    /// Throws `.keyNotFound("F<i>Tg")` for an unknown/uncontrollable fan,
    /// `.rpmOutOfRange` for a manual target outside the fan's hardware
    /// `F<i>Mn...F<i>Mx` (when known), and `.unsupportedDataType` if a value
    /// cannot be encoded as the key's type. Nothing is returned on a throw, so a
    /// list is never started that the helper would reject half-way.
    public func writes(for targets: [Int: FanTarget]) throws -> [(SMCKey, [UInt8])] {
        var modeWrites: [(SMCKey, [UInt8])] = []
        var targetWrites: [(SMCKey, [UInt8])] = []
        var setBits: UInt64 = 0
        var clearBits: UInt64 = 0

        for fan in targets.keys.sorted() {
            guard let info = fans[fan], let target = targets[fan] else {
                throw FanControlError.keyNotFound(Self.keyName(fan, "Tg"))
            }
            let manual: Bool
            if case .manual = target { manual = true } else { manual = false }

            switch info.style {
            case .modeKey:
                let modeInfo = info.mode ?? SMCKeyInfo(dataSize: 1, dataType: .ui8)
                modeWrites.append((.fanMode(fan), try Self.encode(manual ? 1 : 0, as: modeInfo, key: .fanMode(fan))))
            case .forceBits:
                if manual { setBits |= UInt64(1) << UInt64(fan) } else { clearBits |= UInt64(1) << UInt64(fan) }
            case .targetOnly:
                break
            }

            if case .manual(let rpm) = target {
                if let limits = info.rpmLimits,
                   Double(rpm) < limits.lowerBound - Self.rpmTolerance
                    || Double(rpm) > limits.upperBound + Self.rpmTolerance {
                    let allowed = Int(limits.lowerBound.rounded(.up))...Int(limits.upperBound.rounded(.down))
                    throw FanControlError.rpmOutOfRange(fan: fan, rpm: rpm, allowed: allowed)
                }
                targetWrites.append((.fanTarget(fan), try Self.encode(Double(rpm), as: info.target, key: .fanTarget(fan))))
            }
        }

        if setBits != 0 || clearBits != 0, let forceInfo = forceBits {
            let current = try reader.readNumber(.forceBits)
            guard current.isFinite, current >= 0 else {
                throw FanControlError.readFailed(key: SMCKey.forceBits.name, code: -1)
            }
            let mask = (UInt64(min(current, 65535)) | setBits) & ~clearBits
            modeWrites.append((.forceBits, try Self.encode(Double(mask), as: forceInfo, key: .forceBits)))
        }
        return modeWrites + targetWrites
    }

    /// Writes that undo a write list for `pending` that failed part-way: every
    /// fan that was to be forced (`.manual`) is returned to automatic
    /// (`[F<i>Md ← 0]` / one `FS! ` write with those bits cleared). Fans that were
    /// to become automatic and target-only fans need nothing. Uncontrollable fans
    /// are skipped instead of throwing, so a partial rollback is still produced.
    public func rollbackWrites(afterFailureOf pending: [Int: FanTarget]) throws -> [(SMCKey, [UInt8])] {
        var targets: [Int: FanTarget] = [:]
        for (fan, target) in pending where fans[fan] != nil && fans[fan]?.style != .targetOnly {
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
