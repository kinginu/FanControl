import Foundation
import Testing
@testable import FanControlSMC

struct SMCParamStructLayoutTests {
    @Test func testSizeAndOffsetsMatchC() {
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
        #expect(SMCParamStruct.size == 80)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.key) == 0)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.vers) == 4)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.pLimitData) == 12)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo) == 28)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.status) == 41)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.bytes) == 48)
        #expect(MemoryLayout<SMCBytesTuple>.size == SMCParamStruct.bytesCapacity)
    }

    @Test func testPayloadRoundTrip() {
        var s = SMCParamStruct()
        #expect(s.payload(count: 32) == [UInt8](repeating: 0, count: 32))
        let full = (0..<32).map { UInt8($0 + 1) }
        s.setPayload(full)
        #expect(s.payload(count: 32) == full)
        #expect(s.payload(count: 4) == [1, 2, 3, 4])
        #expect(s.payload(count: 0) == [])

        // Shorter payload zero-fills the rest.
        s.setPayload([0xAA, 0xBB])
        #expect(s.payload(count: 4) == [0xAA, 0xBB, 0, 0])
        #expect(s.bytes.0 == 0xAA)
        #expect(s.bytes.31 == 0)
    }

    @Test func testPayloadClampsAt32() {
        var s = SMCParamStruct()
        let long = (0..<40).map { UInt8($0) }
        s.setPayload(long)
        #expect(s.payload(count: 40) == Array(long.prefix(32)))
        #expect(s.payload(count: 1000).count == 32)
        #expect(s.payload(count: -5) == [])
    }
}
