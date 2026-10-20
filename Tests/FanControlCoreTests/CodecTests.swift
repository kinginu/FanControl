import Foundation
import Testing
@testable import FanControlCore

@Suite("SMC keys", .tags(.smc))
struct SMCKeyTests {
    @Test func codeNameRoundtrip() {
        let name = "#KEY"
        let key = SMCKey(name)!
        #expect(key.code == 0x234B_4559)
        #expect(SMCKey(code: 0x234B_4559).name == "#KEY")
        #expect(SMCKey(code: key.code) == key)
        // Trailing space is part of the name (e.g. the legacy Intel `FS! ` key).
        let spaced: SMCKey = "FS! "
        #expect(spaced.name == "FS! ")
        #expect(spaced.description == "FS! ")
        let literal: SMCKey = "TC0P"
        #expect(literal.name == "TC0P")
    }

    @Test func rejectsBadKeys() {
        // Runtime strings: `SMCKey("literal")` would be a literal coercion (SE-0213).
        for bad in ["", "ABC", "ABCDE", "TC0é"] {
            #expect(SMCKey(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test func fanHelpers() {
        #expect(SMCKey.keyCount.name == "#KEY")
        #expect(SMCKey.fanCount.name == "FNum")
        #expect(SMCKey.fanMode(0).name == "F0Md")
        #expect(SMCKey.fanActual(1).name == "F1Ac")
        #expect(SMCKey.fanMin(2).name == "F2Mn")
        #expect(SMCKey.fanMax(3).name == "F3Mx")
        #expect(SMCKey.fanTarget(4).name == "F4Tg")
        #expect(SMCKey.fanID(5).name == "F5ID")
        #expect(SMCKey.fanSafe(6).name == "F6Sf")
    }

    @Test func codable() throws {
        let spaced: SMCKey = "FS! "
        let data = try JSONEncoder().encode([spaced])
        #expect(String(decoding: data, as: UTF8.self) == "[\"FS! \"]")
        #expect(try JSONDecoder().decode([SMCKey].self, from: data) == [spaced])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([SMCKey].self, from: Data("[\"TOOLONG\"]".utf8))
        }
    }
}

@Suite("SMC data types", .tags(.smc))
struct SMCDataTypeTests {
    @Test func parsing() {
        #expect(SMCDataType(name: "flt ") == .flt)
        #expect(SMCDataType(name: "flt") == .flt)
        #expect(SMCDataType(name: "fpe2") == .fpe2)
        #expect(SMCDataType(name: "sp78") == .sp78)
        #expect(SMCDataType(name: "ui8 ") == .ui8)
        #expect(SMCDataType(name: "ui16") == .ui16)
        #expect(SMCDataType(name: "si8 ") == .si8)
        #expect(SMCDataType(name: "flag") == .flag)
        #expect(SMCDataType(name: "ch8*") == .ch8)
        #expect(SMCDataType(name: "hex_") == .hex)
        #expect(SMCDataType(name: "ioft") == .ioft)
        #expect(SMCDataType(name: "si64") == .si64)
        #expect(SMCDataType(name: "{fds") == .unknown("{fds"))
        #expect(SMCDataType(fourCC: 0x7370_3738) == .sp78)
        #expect(SMCDataType(fourCC: 0x666C_7420) == .flt)
    }

    @Test func nameRoundtrip() {
        for type: SMCDataType in [.flt, .fpe2, .fp1f, .sp78, .sp5a, .ui8, .ui64, .si32, .si64, .flag, .ch8, .hex, .ioft] {
            #expect(SMCDataType(name: type.name) == type)
            #expect(type.name.count == 4, "\(type.name.debugDescription)")
        }
    }

    @Test func fractionalBits() {
        #expect(SMCDataType.fpe2.fractionalBits == 2)
        #expect(SMCDataType.fp88.fractionalBits == 8)
        #expect(SMCDataType.fp1f.fractionalBits == 15)
        #expect(SMCDataType.sp78.fractionalBits == 8)
        #expect(SMCDataType.sp5a.fractionalBits == 10)
        #expect(SMCDataType.spf0.fractionalBits == 0)
        #expect(SMCDataType.unknown("fp2e").fractionalBits == 14)
        #expect(SMCDataType.flt.fractionalBits == nil)
        #expect(SMCDataType.ui16.fractionalBits == nil)
    }

    @Test func isNumeric() {
        #expect(SMCDataType.flt.isNumeric)
        #expect(SMCDataType.sp78.isNumeric)
        #expect(SMCDataType.ui32.isNumeric)
        #expect(SMCDataType.ioft.isNumeric)
        #expect(SMCDataType.si64.isNumeric)
        #expect(!SMCDataType.flag.isNumeric)
        #expect(!SMCDataType.ch8.isNumeric)
        #expect(!SMCDataType.hex.isNumeric)
        #expect(!(SMCDataType.unknown("{fds").isNumeric))
    }
}

@Suite("SMC codec", .tags(.smc))
struct SMCCodecTests {
    @Test func fixedPoint() {
        #expect(SMCCodec.decode([0x0B, 0xB8], as: .fpe2) == .number(750))
        #expect(SMCCodec.encode(1200, as: .fpe2, size: 2) == [0x12, 0xC0])
        #expect(SMCCodec.decode([0x2A, 0x80], as: .sp78) == .number(42.5))
        #expect(SMCCodec.decode([0xFF, 0x80], as: .sp78) == .number(-0.5))
        #expect(SMCCodec.encode(-0.5, as: .sp78, size: 2) == [0xFF, 0x80])
        #expect(SMCCodec.decode([0x80, 0x00], as: .fp1f) == .number(1))
        #expect(SMCCodec.decode([0x01, 0x80], as: .fp88) == .number(1.5))
    }

    @Test func fixedPointClamping() {
        #expect(SMCCodec.encode(-5, as: .fpe2, size: 2) == [0x00, 0x00])
        #expect(SMCCodec.encode(1e9, as: .fpe2, size: 2) == [0xFF, 0xFF])
        #expect(SMCCodec.encode(1e9, as: .sp78, size: 2) == [0x7F, 0xFF])
        #expect(SMCCodec.encode(-1e9, as: .sp78, size: 2) == [0x80, 0x00])
        #expect(SMCCodec.encode(1, as: .fpe2, size: 4) == nil)
    }

    @Test func float() {
        #expect(SMCCodec.decode([0x00, 0x00, 0x96, 0x44], as: .flt) == .number(1200))
        #expect(SMCCodec.encode(1200, as: .flt, size: 4) == [0x00, 0x00, 0x96, 0x44])
        #expect(SMCCodec.decode([0x00, 0x00, 0x96], as: .flt) == nil)
        #expect(SMCCodec.encode(1200, as: .flt, size: 2) == nil)
        #expect(SMCCodec.encode(.nan, as: .flt, size: 4) == nil)
    }

    @Test func integers() {
        #expect(SMCCodec.decode([0x01, 0x02], as: .ui16) == .number(258))
        #expect(SMCCodec.decode([0x02], as: .ui8) == .number(2))
        #expect(SMCCodec.decode([0, 0, 0x01, 0x00], as: .ui32) == .number(256))
        #expect(SMCCodec.decode([0xFF], as: .si8) == .number(-1))
        #expect(SMCCodec.decode([0xFF, 0xFE], as: .si16) == .number(-2))
        #expect(SMCCodec.decode([0x80, 0, 0, 0], as: .si32) == .number(Double(Int32.min)))
        #expect(SMCCodec.encode(258, as: .ui16, size: 2) == [0x01, 0x02])
        #expect(SMCCodec.encode(300, as: .ui8, size: 1) == [0xFF])
        #expect(SMCCodec.encode(-3, as: .ui8, size: 1) == [0x00])
        #expect(SMCCodec.encode(1e30, as: .ui64, size: 8) == [UInt8](repeating: 0xFF, count: 8))
        #expect(SMCCodec.encode(-2, as: .si16, size: 2) == [0xFF, 0xFE])
        #expect(SMCCodec.encode(1, as: .ui16, size: 1) == nil)
        #expect(SMCCodec.decode([0x01], as: .ui16) == nil)
    }

    @Test func flagStringBytes() {
        #expect(SMCCodec.decode([0x01], as: .flag) == .flag(true))
        #expect(SMCCodec.decode([0x00], as: .flag) == .flag(false))
        #expect(SMCCodec.encode(1, as: .flag, size: 1) == [0x01])
        #expect(SMCCodec.decode(Array(" Exhaust".utf8) + [0, 0x41], as: .ch8) == .string("Exhaust"))
        #expect(SMCCodec.decode([0xDE, 0xAD], as: .hex) == .bytes([0xDE, 0xAD]))
        #expect(SMCCodec.decode([1, 2, 3], as: .unknown("{fds")) == .bytes([1, 2, 3]))
        #expect(SMCCodec.encode(1, as: .ch8, size: 4) == nil)
    }

    @Test func ioft() {
        // Little-endian 16.16 fixed point.
        #expect(SMCCodec.decode([0x00, 0x80, 0x01, 0, 0, 0, 0, 0], as: .ioft) == .number(1.5))
        #expect(SMCCodec.encode(1.5, as: .ioft, size: 8) == [0x00, 0x80, 0x01, 0, 0, 0, 0, 0])
        #expect(SMCCodec.decode([0x00, 0x80, 0x01], as: .ioft) == nil)
    }

    /// Raw `ioft` temperature keys from the Mac14,9 / macOS 26 dump.
    @Test func ioftRealDump() throws {
        let tg0b = try #require(SMCCodec.decode([0x66, 0xE6, 0x20, 0, 0, 0, 0, 0], as: .ioft)?.doubleValue)
        #expect(abs(tg0b - 32.9) < 0.001)   // TB0T (flt) read 32.90 °C at the same time
        let tr0z = try #require(SMCCodec.decode([0x9A, 0xD9, 0x33, 0, 0, 0, 0, 0], as: .ioft)?.doubleValue)
        #expect(abs(tr0z - 51.85) < 0.001)
        #expect(SMCCodec.decode([0, 0, 0x20, 0, 0, 0, 0, 0], as: .ioft) == .number(32))  // TG0C
    }

    @Test func si64() {
        #expect(SMCCodec.decode([0, 0, 0, 0, 0, 0, 0x01, 0x00], as: .si64) == .number(256))
        #expect(SMCCodec.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE], as: .si64) == .number(-2))
        #expect(SMCCodec.decode([0, 0, 0, 0], as: .si64) == nil)
        #expect(SMCCodec.encode(-2, as: .si64, size: 8) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        // Saturates instead of trapping at the 64-bit bounds.
        #expect(SMCCodec.encode(1e30, as: .si64, size: 8) == [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(SMCCodec.encode(-1e30, as: .si64, size: 8) == [0x80, 0, 0, 0, 0, 0, 0, 0])
        #expect(SMCCodec.encode(1e9, as: .si16, size: 2) == [0x7F, 0xFF])
        #expect(SMCCodec.encode(-1e9, as: .si16, size: 2) == [0x80, 0x00])
    }

    @Test func doubleValue() {
        #expect(SMCValue.number(3).doubleValue == 3)
        #expect(SMCValue.flag(true).doubleValue == 1)
        #expect(SMCValue.string("x").doubleValue == nil)
        #expect(SMCValue.bytes([]).doubleValue == nil)
    }
}
