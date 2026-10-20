import Foundation
import FanControlCore

/// In-memory `SMCReader` backed by a dictionary of key → (type, bytes).
final class MockSMCReader: SMCReader {
    struct Entry {
        var type: SMCDataType
        var bytes: [UInt8]
        var attributes: UInt8 = 0
    }

    var entries: [SMCKey: Entry]
    /// Key order used for enumeration (`key(at:)`).
    var order: [SMCKey]
    /// Keys whose `readBytes` fails even though key-info succeeds.
    var failingReads: Set<SMCKey> = []

    init(_ entries: [(String, SMCDataType, [UInt8])]) {
        var dict: [SMCKey: Entry] = [:]
        var order: [SMCKey] = []
        for (name, type, bytes) in entries {
            let key = SMCKey(name)!
            dict[key] = Entry(type: type, bytes: bytes)
            order.append(key)
        }
        self.entries = dict
        self.order = order
    }

    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return SMCKeyInfo(dataSize: entry.bytes.count, dataType: entry.type, attributes: entry.attributes)
    }

    func readBytes(_ key: SMCKey) throws -> [UInt8] {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        if failingReads.contains(key) { throw FanControlError.readFailed(key: key.name, code: -1) }
        return entry.bytes
    }

    func keyCount() throws -> Int { order.count }

    func key(at index: Int) throws -> SMCKey {
        guard order.indices.contains(index) else { throw FanControlError.invalidKey("#\(index)") }
        return order[index]
    }
}

/// Shared SMC layouts and values of the Core tests.
enum Fixtures {
    /// The two fans of the Mac14,9 (M2 Pro): 2317...6800 RPM.
    static let mac14_9Fans = [FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
                              FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)]

    static func fpe2(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .fpe2, size: 2)! }
    static func sp78(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .sp78, size: 2)! }
    static func flt(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .flt, size: 4)! }

    /// 16-byte `F<i>ID` record with an ASCII name starting at byte 4.
    static func fanID(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x12, 0x00, 0x00] + Array(name.utf8)
        bytes += [UInt8](repeating: 0, count: max(0, 16 - bytes.count))
        return Array(bytes.prefix(16))
    }

    /// Intel-era SMC layout: fpe2 fan keys, sp78 temperatures, an `FS! ` force
    /// bitmask and no `F<n>Md`. Intel is unsupported since 2026-10-20; the fixture
    /// only covers generic decoding (fpe2/sp78) and that `FS! ` is ignored.
    static func intel() -> MockSMCReader {
        MockSMCReader([
            ("#KEY", .ui32, [0, 0, 0, 20]),
            ("FNum", .ui8, [2]),
            ("FS! ", .ui16, [0x00, 0x02]),
            ("F0ID", .unknown("{fds"), fanID("Left Side")),
            ("F0Mn", .fpe2, fpe2(1200)),
            ("F0Mx", .fpe2, fpe2(6000)),
            ("F0Ac", .fpe2, fpe2(1210)),
            ("F0Tg", .fpe2, fpe2(1200)),
            ("F1ID", .unknown("{fds"), fanID("Right Side")),
            ("F1Mn", .fpe2, fpe2(1300)),
            ("F1Mx", .fpe2, fpe2(5500)),
            ("F1Ac", .fpe2, fpe2(2500)),
            ("F1Tg", .fpe2, fpe2(2500)),
            ("TC0P", .sp78, sp78(55.5)),
            ("TG0D", .sp78, sp78(48.25)),
            ("TA0P", .sp78, sp78(-40)),      // implausible -> filtered
            ("TZZZ", .ch8, Array("abcd".utf8)), // non numeric -> skipped
            ("TB0T", .sp78, sp78(31)),
            ("BNum", .ui8, [1]),             // not a temperature
            ("Tm0P", .sp78, sp78(40)),
        ])
    }

    /// Apple Silicon-style SMC: flt fan and temperature keys, F%dMd mode keys.
    static func appleSilicon() -> MockSMCReader {
        MockSMCReader([
            ("#KEY", .ui32, [0, 0, 0, 12]),
            ("FNum", .ui8, [2]),
            ("F0Md", .ui8, [1]),
            ("F0Mn", .flt, flt(1200)),
            ("F0Mx", .flt, flt(5779)),
            ("F0Ac", .flt, flt(2400.4)),
            ("F0Tg", .flt, flt(2400)),
            ("F1Md", .ui8, [0]),
            ("F1Mn", .flt, flt(1200)),
            ("F1Mx", .flt, flt(6241)),
            ("F1Ac", .flt, flt(1199.6)),
            ("Tp09", .flt, flt(61.5)),
            ("Te05", .flt, flt(45)),
            ("Tg0f", .flt, flt(140)),        // implausible -> filtered
        ])
    }
}

/// Fixed wall-clock time for code that takes `now:` / `at:` (never `Date()` in assertions).
enum TestClock {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// `t0` plus `seconds`.
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}
