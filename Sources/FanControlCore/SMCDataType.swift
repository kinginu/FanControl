import Foundation

/// The SMC data type of a key, as reported by the SMC key-info call
/// (a FourCC such as `"flt "`, `"fpe2"`, `"sp78"`, `"ui8 "`).
///
/// Fixed-point types follow the pattern `fpXY` (unsigned) and `spXY`
/// (signed), where `X` is the number of integer bits (sign bit included for
/// `sp`) and `Y` the number of fractional bits, each a single hex digit, for a
/// total of 16 bits. Unrecognised names are preserved in `.unknown`.
public enum SMCDataType: Hashable, Sendable {
    case flt
    case fpe2, fp1f, fp4c, fp5b, fp6a, fp79, fp88, fpa6, fpc4
    case sp78, sp5a, sp69, sp87, sp96, spb4, spf0
    case ui8, ui16, ui32, ui64
    case si8, si16, si32
    case flag
    case ch8
    case hex
    case ioft
    case unknown(String)

    private static let table: [(SMCDataType, String)] = [
        (.flt, "flt "),
        (.fpe2, "fpe2"), (.fp1f, "fp1f"), (.fp4c, "fp4c"), (.fp5b, "fp5b"), (.fp6a, "fp6a"),
        (.fp79, "fp79"), (.fp88, "fp88"), (.fpa6, "fpa6"), (.fpc4, "fpc4"),
        (.sp78, "sp78"), (.sp5a, "sp5a"), (.sp69, "sp69"), (.sp87, "sp87"), (.sp96, "sp96"),
        (.spb4, "spb4"), (.spf0, "spf0"),
        (.ui8, "ui8 "), (.ui16, "ui16"), (.ui32, "ui32"), (.ui64, "ui64"),
        (.si8, "si8 "), (.si16, "si16"), (.si32, "si32"),
        (.flag, "flag"), (.ch8, "ch8*"), (.hex, "hex_"), (.ioft, "ioft"),
    ]

    private static let byName: [String: SMCDataType] =
        Dictionary(uniqueKeysWithValues: table.map { ($0.1, $0.0) })

    /// Parses an SMC type name. Exact 4-character names are preferred; names
    /// whose trailing spaces/NULs were stripped (e.g. `"flt"`, `"ui8"`) are
    /// accepted too. Anything else becomes `.unknown(name)`.
    public init(name: String) {
        if let known = SMCDataType.byName[name] {
            self = known
            return
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        let padded = trimmed.padding(toLength: 4, withPad: " ", startingAt: 0)
        if trimmed.count < 4, let known = SMCDataType.byName[padded] {
            self = known
        } else {
            self = .unknown(name)
        }
    }

    /// Parses a big-endian FourCC data-type code as returned by the SMC.
    public init(fourCC: UInt32) {
        self.init(name: SMCKey(code: fourCC).name)
    }

    /// The 4-character SMC name (e.g. `"ui8 "`, `"ch8*"`).
    public var name: String {
        if case .unknown(let raw) = self { return raw }
        return SMCDataType.table.first { $0.0 == self }!.1
    }

    /// Fractional bit count for fixed-point types (`fpXY` / `spXY` → `Y`),
    /// including unrecognised names that follow that pattern. `nil` otherwise.
    public var fractionalBits: Int? {
        fixedPointLayout?.fractionalBits
    }

    /// `true` if the type decodes to a number (floats, fixed point, integers,
    /// `ioft`). `flag`, `ch8*`, `hex_` and unknown non-fixed-point types are not numeric.
    public var isNumeric: Bool {
        switch self {
        case .flt, .ui8, .ui16, .ui32, .ui64, .si8, .si16, .si32, .ioft:
            return true
        case .flag, .ch8, .hex:
            return false
        default:
            return fixedPointLayout != nil
        }
    }

    /// Layout of a 16-bit fixed-point type, parsed from the `fpXY`/`spXY` name.
    var fixedPointLayout: (signed: Bool, fractionalBits: Int)? {
        let chars = Array(name)
        guard chars.count == 4 else { return nil }
        let prefix = String(chars[0...1])
        let signed: Bool
        switch prefix {
        case "fp": signed = false
        case "sp": signed = true
        default: return nil
        }
        guard chars[2].isHexDigit, let frac = chars[3].hexDigitValue else { return nil }
        return (signed, frac)
    }
}
