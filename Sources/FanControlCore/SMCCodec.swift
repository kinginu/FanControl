import Foundation

/// A decoded SMC value.
public enum SMCValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bytes([UInt8])
    case flag(Bool)

    /// The numeric value: numbers as-is, flags as 1/0, otherwise `nil`.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .flag(let value): return value ? 1 : 0
        case .string, .bytes: return nil
        }
    }
}

/// Converts between raw SMC byte buffers and values.
///
/// Encoding rules (publicly known AppleSMC conventions):
/// - `flt `: 4 bytes, **little-endian** IEEE 754 Float32. Apple Silicon fan and
///   temperature keys use this type.
/// - `fpXY`: big-endian `UInt16`, value = raw / 2^Y (`fpe2` → /4, `fp88` → /256,
///   `fp1f` → /32768).
/// - `spXY`: big-endian `Int16` (two's complement), value = raw / 2^Y
///   (`sp78` → /256).
/// - `ui8 `/`ui16`/`ui32`/`ui64`: big-endian unsigned integers;
///   `si8 `/`si16`/`si32`/`si64`: big-endian signed integers.
///   Caveat (Mac14,9 / macOS 26 dump, `docs/verification/`): `#KEY`, `FOFC`,
///   `F<n>Fc` are big-endian, but many other integer keys (battery `B*`, all
///   observed `ui64`/`si64`) look little-endian. Endianness of integer keys is
///   therefore per key; only rely on integer decoding for keys verified on
///   hardware (the fan/temperature path uses `flt ` and `ui8 ` only).
/// - `flag`: 1 byte, non-zero = `true`.
/// - `ch8*`: ASCII text, terminated by the first NUL, whitespace-trimmed.
/// - `ioft`: 8-byte **little-endian** unsigned fixed point with 16 fractional
///   bits (value = raw / 65536). Verified on Mac14,9 / macOS 26: `TG0B` =
///   `66 e6 20 00 00 00 00 00` → 32.9 °C, matching `TB0T` (`flt `) = 32.9 °C.
/// - `hex_` and unknown types: returned as raw `.bytes`.
///
/// Fixed-size types require the buffer to have exactly the type's width;
/// otherwise decoding returns `nil`.
public enum SMCCodec {

    /// Decodes `bytes` according to `type`. Returns `nil` when the buffer
    /// length does not match the type's width.
    public static func decode(_ bytes: [UInt8], as type: SMCDataType) -> SMCValue? {
        switch type {
        case .flt:
            guard bytes.count == 4 else { return nil }
            let bits = littleEndian(bytes)
            return .number(Double(Float(bitPattern: UInt32(bits))))
        case .ui8, .ui16, .ui32, .ui64:
            guard bytes.count == width(of: type) else { return nil }
            return .number(Double(bigEndian(bytes)))
        case .si8, .si16, .si32, .si64:
            guard let width = width(of: type), bytes.count == width else { return nil }
            let raw = bigEndian(bytes)
            let shift = UInt64(64 - width * 8)
            // Sign-extend from `width` bytes to 64 bits.
            let signed = Int64(bitPattern: raw << shift) >> Int64(shift)
            return .number(Double(signed))
        case .flag:
            guard bytes.count == 1 else { return nil }
            return .flag(bytes[0] != 0)
        case .ch8:
            let text = bytes.prefix { $0 != 0 }
            return .string(String(decoding: text, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        case .ioft:
            guard bytes.count == 8 else { return nil }
            return .number(Double(littleEndian(bytes)) / 65536.0)
        case .hex:
            return .bytes(bytes)
        default:
            // fpXY / spXY (known cases and unknown names following the pattern).
            if let layout = type.fixedPointLayout {
                guard bytes.count == 2 else { return nil }
                let raw = UInt16(bigEndian(bytes))
                let scale = Double(1 << layout.fractionalBits)
                let value = layout.signed ? Double(Int16(bitPattern: raw)) : Double(raw)
                return .number(value / scale)
            }
            return .bytes(bytes)
        }
    }

    /// Encodes a numeric `value` as `type` into a buffer of `size` bytes.
    ///
    /// The value is rounded to the nearest representable value and clamped into
    /// the type's range. Returns `nil` if `size` does not match the type's
    /// width, if the type is not numeric (`ch8*`, `hex_`, unknown), or if
    /// `value` is NaN.
    public static func encode(_ value: Double, as type: SMCDataType, size: Int) -> [UInt8]? {
        guard !value.isNaN else { return nil }
        switch type {
        case .flt:
            guard size == 4 else { return nil }
            let clamped = min(max(value, -Double(Float.greatestFiniteMagnitude)),
                              Double(Float.greatestFiniteMagnitude))
            return toLittleEndian(UInt64(Float(clamped).bitPattern), width: 4)
        case .ui8, .ui16, .ui32, .ui64:
            guard let width = width(of: type), size == width else { return nil }
            return toBigEndian(clampUnsigned(value.rounded(), bits: width * 8), width: width)
        case .si8, .si16, .si32, .si64:
            guard let width = width(of: type), size == width else { return nil }
            let raw = clampSigned(value.rounded(), bits: width * 8)
            return toBigEndian(UInt64(bitPattern: raw), width: width)
        case .flag:
            guard size == 1 else { return nil }
            return [value != 0 ? 1 : 0]
        case .ioft:
            guard size == 8 else { return nil }
            return toLittleEndian(clampUnsigned((value * 65536.0).rounded(), bits: 64), width: 8)
        case .ch8, .hex:
            return nil
        default:
            guard let layout = type.fixedPointLayout, size == 2 else { return nil }
            let scaled = (value * Double(1 << layout.fractionalBits)).rounded()
            let raw: UInt16
            if layout.signed {
                raw = UInt16(bitPattern: Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max))))
            } else {
                raw = UInt16(min(max(scaled, 0), Double(UInt16.max)))
            }
            return toBigEndian(UInt64(raw), width: 2)
        }
    }

    // MARK: - Helpers

    private static func width(of type: SMCDataType) -> Int? {
        switch type {
        case .ui8, .si8, .flag: return 1
        case .ui16, .si16: return 2
        case .ui32, .si32, .flt: return 4
        case .ui64, .si64, .ioft: return 8
        default: return type.fixedPointLayout != nil ? 2 : nil
        }
    }

    /// Clamps a rounded double into `0 ... 2^bits - 1` without trapping.
    private static func clampUnsigned(_ value: Double, bits: Int) -> UInt64 {
        guard value > 0 else { return 0 }
        let limit = bits == 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
        // 2^64 is exactly representable as a Double; anything >= it saturates.
        if value >= 18_446_744_073_709_551_616.0 { return limit }
        return min(UInt64(value), limit)
    }

    /// Clamps a rounded double into the signed `bits`-wide range without trapping
    /// (`Double(Int64.max)` rounds up to 2^63, so 64-bit saturates explicitly).
    private static func clampSigned(_ value: Double, bits: Int) -> Int64 {
        let bound = Double(sign: .plus, exponent: bits - 1, significand: 1) // 2^(bits-1)
        if value >= bound { return bits == 64 ? Int64.max : (Int64(1) << Int64(bits - 1)) - 1 }
        if value <= -bound { return bits == 64 ? Int64.min : -(Int64(1) << Int64(bits - 1)) }
        return Int64(value)
    }

    private static func bigEndian(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func littleEndian(_ bytes: [UInt8]) -> UInt64 {
        bytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func toBigEndian(_ value: UInt64, width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64((width - 1 - $0) * 8)) }
    }

    private static func toLittleEndian(_ value: UInt64, width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}
