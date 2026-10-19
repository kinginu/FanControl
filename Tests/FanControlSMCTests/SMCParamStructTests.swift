import XCTest
@testable import FanControlSMC

final class SMCParamStructLayoutTests: XCTestCase {
    func testSizeAndOffsetsMatchC() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
        XCTAssertEqual(SMCParamStruct.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.vers), 4)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.pLimitData), 12)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
        XCTAssertEqual(MemoryLayout<SMCBytesTuple>.size, SMCParamStruct.bytesCapacity)
    }

    func testPayloadRoundTrip() {
        var s = SMCParamStruct()
        XCTAssertEqual(s.payload(count: 32), [UInt8](repeating: 0, count: 32))
        let full = (0..<32).map { UInt8($0 + 1) }
        s.setPayload(full)
        XCTAssertEqual(s.payload(count: 32), full)
        XCTAssertEqual(s.payload(count: 4), [1, 2, 3, 4])
        XCTAssertEqual(s.payload(count: 0), [])

        // Shorter payload zero-fills the rest.
        s.setPayload([0xAA, 0xBB])
        XCTAssertEqual(s.payload(count: 4), [0xAA, 0xBB, 0, 0])
        XCTAssertEqual(s.bytes.0, 0xAA)
        XCTAssertEqual(s.bytes.31, 0)
    }

    func testPayloadClampsAt32() {
        var s = SMCParamStruct()
        let long = (0..<40).map { UInt8($0) }
        s.setPayload(long)
        XCTAssertEqual(s.payload(count: 40), Array(long.prefix(32)))
        XCTAssertEqual(s.payload(count: 1000).count, 32)
        XCTAssertEqual(s.payload(count: -5), [])
    }
}
