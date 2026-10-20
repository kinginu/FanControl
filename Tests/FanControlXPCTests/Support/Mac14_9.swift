import FanControlCore

/// Key layout of the Mac14,9 / macOS 26 dump (`docs/verification/Mac14,9-macOS26-dump.txt`):
/// `F<n>Md` ui8 (0xd0), `F<n>Tg` little-endian flt (0xd4), read-only `F<n>Mn` (0x84),
/// both fans 2317...6800 RPM.
enum Mac14_9 {
    static let md = SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd0)
    static let tg = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0xd4)
    static let mn = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0x84)
    static let limits: [Int: ClosedRange<Double>] = [0: 2317...6800, 1: 2317...6800]

    static func flt(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .flt, size: 4)! }

    /// Key info by suffix (`Md`, `Tg`, `Mn`), `nil` for anything else.
    static func info(_ key: SMCKey) -> SMCKeyInfo? {
        switch key.name.suffix(2) {
        case "Md": return md
        case "Tg": return tg
        case "Mn": return mn
        default: return nil
        }
    }
}

/// Minimal read-only in-memory `SMCReader` (no enumeration).
final class InMemorySMCReader: SMCReader {
    private var entries: [SMCKey: (type: SMCDataType, bytes: [UInt8])] = [:]

    init(_ list: [(String, SMCDataType, [UInt8])]) {
        for (name, type, bytes) in list { entries[SMCKey(name)!] = (type, bytes) }
    }

    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return SMCKeyInfo(dataSize: entry.bytes.count, dataType: entry.type)
    }

    func readBytes(_ key: SMCKey) throws -> [UInt8] {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return entry.bytes
    }

    func keyCount() throws -> Int { entries.count }
    func key(at index: Int) throws -> SMCKey { throw FanControlError.invalidKey("#\(index)") }
}
