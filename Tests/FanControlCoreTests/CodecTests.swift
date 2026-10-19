import XCTest
@testable import FanControlCore

final class SMCKeyTests: XCTestCase {
    func testCodeNameRoundtrip() {
        let name = "#KEY"
        let key = SMCKey(name)!
        XCTAssertEqual(key.code, 0x234B_4559)
        XCTAssertEqual(SMCKey(code: 0x234B_4559).name, "#KEY")
        XCTAssertEqual(SMCKey(code: key.code), key)
        XCTAssertEqual(SMCKey.forceBits.name, "FS! ")
        XCTAssertEqual(SMCKey.forceBits.description, "FS! ")
        let literal: SMCKey = "TC0P"
        XCTAssertEqual(literal.name, "TC0P")
    }

    func testRejectsBadKeys() {
        // Runtime strings: `SMCKey("literal")` would be a literal coercion (SE-0213).
        for bad in ["", "ABC", "ABCDE", "TC0é"] {
            XCTAssertNil(SMCKey(bad), bad)
        }
    }

    func testFanHelpers() {
        XCTAssertEqual(SMCKey.keyCount.name, "#KEY")
        XCTAssertEqual(SMCKey.fanCount.name, "FNum")
        XCTAssertEqual(SMCKey.fanMode(0).name, "F0Md")
        XCTAssertEqual(SMCKey.fanActual(1).name, "F1Ac")
        XCTAssertEqual(SMCKey.fanMin(2).name, "F2Mn")
        XCTAssertEqual(SMCKey.fanMax(3).name, "F3Mx")
        XCTAssertEqual(SMCKey.fanTarget(4).name, "F4Tg")
        XCTAssertEqual(SMCKey.fanID(5).name, "F5ID")
        XCTAssertEqual(SMCKey.fanSafe(6).name, "F6Sf")
    }

    func testCodable() throws {
        let data = try JSONEncoder().encode([SMCKey.forceBits])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"FS! \"]")
        XCTAssertEqual(try JSONDecoder().decode([SMCKey].self, from: data), [.forceBits])
        XCTAssertThrowsError(try JSONDecoder().decode([SMCKey].self, from: Data("[\"TOOLONG\"]".utf8)))
    }
}

final class SMCDataTypeTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SMCDataType(name: "flt "), .flt)
        XCTAssertEqual(SMCDataType(name: "flt"), .flt)
        XCTAssertEqual(SMCDataType(name: "fpe2"), .fpe2)
        XCTAssertEqual(SMCDataType(name: "sp78"), .sp78)
        XCTAssertEqual(SMCDataType(name: "ui8 "), .ui8)
        XCTAssertEqual(SMCDataType(name: "ui16"), .ui16)
        XCTAssertEqual(SMCDataType(name: "si8 "), .si8)
        XCTAssertEqual(SMCDataType(name: "flag"), .flag)
        XCTAssertEqual(SMCDataType(name: "ch8*"), .ch8)
        XCTAssertEqual(SMCDataType(name: "hex_"), .hex)
        XCTAssertEqual(SMCDataType(name: "ioft"), .ioft)
        XCTAssertEqual(SMCDataType(name: "{fds"), .unknown("{fds"))
        XCTAssertEqual(SMCDataType(fourCC: 0x7370_3738), .sp78)
        XCTAssertEqual(SMCDataType(fourCC: 0x666C_7420), .flt)
    }

    func testNameRoundtrip() {
        for type: SMCDataType in [.flt, .fpe2, .fp1f, .sp78, .sp5a, .ui8, .ui64, .si32, .flag, .ch8, .hex, .ioft] {
            XCTAssertEqual(SMCDataType(name: type.name), type)
            XCTAssertEqual(type.name.count, 4)
        }
    }

    func testFractionalBits() {
        XCTAssertEqual(SMCDataType.fpe2.fractionalBits, 2)
        XCTAssertEqual(SMCDataType.fp88.fractionalBits, 8)
        XCTAssertEqual(SMCDataType.fp1f.fractionalBits, 15)
        XCTAssertEqual(SMCDataType.sp78.fractionalBits, 8)
        XCTAssertEqual(SMCDataType.sp5a.fractionalBits, 10)
        XCTAssertEqual(SMCDataType.spf0.fractionalBits, 0)
        XCTAssertEqual(SMCDataType.unknown("fp2e").fractionalBits, 14)
        XCTAssertNil(SMCDataType.flt.fractionalBits)
        XCTAssertNil(SMCDataType.ui16.fractionalBits)
    }

    func testIsNumeric() {
        XCTAssertTrue(SMCDataType.flt.isNumeric)
        XCTAssertTrue(SMCDataType.sp78.isNumeric)
        XCTAssertTrue(SMCDataType.ui32.isNumeric)
        XCTAssertTrue(SMCDataType.ioft.isNumeric)
        XCTAssertFalse(SMCDataType.flag.isNumeric)
        XCTAssertFalse(SMCDataType.ch8.isNumeric)
        XCTAssertFalse(SMCDataType.hex.isNumeric)
        XCTAssertFalse(SMCDataType.unknown("{fds").isNumeric)
    }
}

final class SMCCodecTests: XCTestCase {
    func testFixedPoint() {
        XCTAssertEqual(SMCCodec.decode([0x0B, 0xB8], as: .fpe2), .number(750))
        XCTAssertEqual(SMCCodec.encode(1200, as: .fpe2, size: 2), [0x12, 0xC0])
        XCTAssertEqual(SMCCodec.decode([0x2A, 0x80], as: .sp78), .number(42.5))
        XCTAssertEqual(SMCCodec.decode([0xFF, 0x80], as: .sp78), .number(-0.5))
        XCTAssertEqual(SMCCodec.encode(-0.5, as: .sp78, size: 2), [0xFF, 0x80])
        XCTAssertEqual(SMCCodec.decode([0x80, 0x00], as: .fp1f), .number(1))
        XCTAssertEqual(SMCCodec.decode([0x01, 0x80], as: .fp88), .number(1.5))
    }

    func testFixedPointClamping() {
        XCTAssertEqual(SMCCodec.encode(-5, as: .fpe2, size: 2), [0x00, 0x00])
        XCTAssertEqual(SMCCodec.encode(1e9, as: .fpe2, size: 2), [0xFF, 0xFF])
        XCTAssertEqual(SMCCodec.encode(1e9, as: .sp78, size: 2), [0x7F, 0xFF])
        XCTAssertEqual(SMCCodec.encode(-1e9, as: .sp78, size: 2), [0x80, 0x00])
        XCTAssertNil(SMCCodec.encode(1, as: .fpe2, size: 4))
    }

    func testFloat() {
        XCTAssertEqual(SMCCodec.decode([0x00, 0x00, 0x96, 0x44], as: .flt), .number(1200))
        XCTAssertEqual(SMCCodec.encode(1200, as: .flt, size: 4), [0x00, 0x00, 0x96, 0x44])
        XCTAssertNil(SMCCodec.decode([0x00, 0x00, 0x96], as: .flt))
        XCTAssertNil(SMCCodec.encode(1200, as: .flt, size: 2))
        XCTAssertNil(SMCCodec.encode(.nan, as: .flt, size: 4))
    }

    func testIntegers() {
        XCTAssertEqual(SMCCodec.decode([0x01, 0x02], as: .ui16), .number(258))
        XCTAssertEqual(SMCCodec.decode([0x02], as: .ui8), .number(2))
        XCTAssertEqual(SMCCodec.decode([0, 0, 0x01, 0x00], as: .ui32), .number(256))
        XCTAssertEqual(SMCCodec.decode([0xFF], as: .si8), .number(-1))
        XCTAssertEqual(SMCCodec.decode([0xFF, 0xFE], as: .si16), .number(-2))
        XCTAssertEqual(SMCCodec.decode([0x80, 0, 0, 0], as: .si32), .number(Double(Int32.min)))
        XCTAssertEqual(SMCCodec.encode(258, as: .ui16, size: 2), [0x01, 0x02])
        XCTAssertEqual(SMCCodec.encode(300, as: .ui8, size: 1), [0xFF])
        XCTAssertEqual(SMCCodec.encode(-3, as: .ui8, size: 1), [0x00])
        XCTAssertEqual(SMCCodec.encode(1e30, as: .ui64, size: 8), [UInt8](repeating: 0xFF, count: 8))
        XCTAssertEqual(SMCCodec.encode(-2, as: .si16, size: 2), [0xFF, 0xFE])
        XCTAssertNil(SMCCodec.encode(1, as: .ui16, size: 1))
        XCTAssertNil(SMCCodec.decode([0x01], as: .ui16))
    }

    func testFlagStringBytes() {
        XCTAssertEqual(SMCCodec.decode([0x01], as: .flag), .flag(true))
        XCTAssertEqual(SMCCodec.decode([0x00], as: .flag), .flag(false))
        XCTAssertEqual(SMCCodec.encode(1, as: .flag, size: 1), [0x01])
        XCTAssertEqual(SMCCodec.decode(Array(" Exhaust".utf8) + [0, 0x41], as: .ch8), .string("Exhaust"))
        XCTAssertEqual(SMCCodec.decode([0xDE, 0xAD], as: .hex), .bytes([0xDE, 0xAD]))
        XCTAssertEqual(SMCCodec.decode([1, 2, 3], as: .unknown("{fds")), .bytes([1, 2, 3]))
        XCTAssertNil(SMCCodec.encode(1, as: .ch8, size: 4))
    }

    func testIoft() {
        XCTAssertEqual(SMCCodec.decode([0, 0, 0, 0, 0, 0x01, 0x80, 0x00], as: .ioft), .number(1.5))
        XCTAssertEqual(SMCCodec.encode(1.5, as: .ioft, size: 8), [0, 0, 0, 0, 0, 0x01, 0x80, 0x00])
    }

    func testDoubleValue() {
        XCTAssertEqual(SMCValue.number(3).doubleValue, 3)
        XCTAssertEqual(SMCValue.flag(true).doubleValue, 1)
        XCTAssertNil(SMCValue.string("x").doubleValue)
        XCTAssertNil(SMCValue.bytes([]).doubleValue)
    }
}
