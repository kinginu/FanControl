import Foundation

/// A four-character AppleSMC key such as `"#KEY"`, `"F0Ac"` or `"TC0P"`.
///
/// The SMC addresses every value by a FourCC: four ASCII characters packed
/// big-endian into a `UInt32` (`"#KEY"` → `0x234B4559`). `SMCKey` stores that
/// packed code and exposes the human-readable name.
///
/// Encodes to / decodes from a single JSON string (the 4-character name).
///
/// Note: because of `ExpressibleByStringLiteral`, `SMCKey("TC0P")` with a
/// *literal* argument is a literal coercion (SE-0213) and is non-optional; it
/// traps on an invalid literal. Pass a `String` variable to get the failable
/// `init?(_:)`.
public struct SMCKey: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    /// Big-endian FourCC code (`"#KEY"` → `0x234B4559`).
    public let code: UInt32

    /// Creates a key from its 4-character ASCII name. Returns `nil` unless the
    /// string is exactly four ASCII characters.
    public init?(_ name: String) {
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        self.code = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Creates a key from its packed big-endian FourCC code.
    public init(code: UInt32) {
        self.code = code
    }

    /// Creates a key from a string literal. The literal must be exactly four
    /// ASCII characters; anything else is a programmer error and traps.
    public init(stringLiteral value: String) {
        guard let key = SMCKey(value) else {
            preconditionFailure("SMCKey literal must be exactly 4 ASCII characters: \"\(value)\"")
        }
        self = key
    }

    /// The 4-character ASCII name (e.g. `"FS! "` including the trailing space).
    public var name: String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24),
                     UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8),
                     UInt8(truncatingIfNeeded: code)]
        return String(decoding: bytes, as: UTF8.self)
    }

    public var description: String { name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = SMCKey(string) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Invalid SMC key \"\(string)\"")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

// MARK: - Well-known keys

public extension SMCKey {
    /// `#KEY`: total number of keys exposed by the SMC (ui32).
    static let keyCount: SMCKey = "#KEY"
    /// `FNum`: number of fans (ui8).
    static let fanCount: SMCKey = "FNum"
    /// `FS! `: Intel-era "force" bitmask, bit *i* = fan *i* under manual control.
    /// Note the trailing space.
    static let forceBits: SMCKey = "FS! "

    /// `F<i>Md`: fan mode (0 = automatic, non-zero = manual/forced).
    static func fanMode(_ i: Int) -> SMCKey { fanKey(i, "Md") }
    /// `F<i>Ac`: actual (measured) fan speed in RPM.
    static func fanActual(_ i: Int) -> SMCKey { fanKey(i, "Ac") }
    /// `F<i>Mn`: minimum fan speed in RPM.
    static func fanMin(_ i: Int) -> SMCKey { fanKey(i, "Mn") }
    /// `F<i>Mx`: maximum fan speed in RPM.
    static func fanMax(_ i: Int) -> SMCKey { fanKey(i, "Mx") }
    /// `F<i>Tg`: target fan speed in RPM.
    static func fanTarget(_ i: Int) -> SMCKey { fanKey(i, "Tg") }
    /// `F<i>ID`: fan identification record (contains a name such as "Exhaust").
    static func fanID(_ i: Int) -> SMCKey { fanKey(i, "ID") }
    /// `F<i>Sf`: fan "safe" speed in RPM.
    static func fanSafe(_ i: Int) -> SMCKey { fanKey(i, "Sf") }

    /// Builds `F<i><suffix>`. Fan indices are single decimal digits (0...9);
    /// larger indices cannot form a 4-character key and trap.
    private static func fanKey(_ i: Int, _ suffix: String) -> SMCKey {
        precondition((0...9).contains(i), "Fan index must be 0...9, got \(i)")
        return SMCKey("F\(i)\(suffix)")!
    }
}
