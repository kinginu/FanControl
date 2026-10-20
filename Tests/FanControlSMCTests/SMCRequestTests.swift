import Testing
import FanControlCore
@testable import FanControlSMC

/// Request construction and reply interpretation (`SMCParamStruct` extensions).
struct SMCRequestTests {
    @Test func keyInfoRequest() {
        let r = SMCParamStruct.keyInfoRequest("F0Tg")
        #expect(r.key == 0x4630_5467)
        #expect(r.data8 == kSMCGetKeyInfo)
        #expect(r.keyInfo.dataSize == 0)
        #expect(r.payload(count: 32) == [UInt8](repeating: 0, count: 32))
    }

    @Test func readRequest() {
        let r = SMCParamStruct.readRequest("TG0B", size: 8)
        #expect(r.key == SMCKey("TG0B").code)
        #expect(r.data8 == kSMCReadKey)
        #expect(r.keyInfo.dataSize == 8)
    }

    @Test func keyAtIndexRequest() {
        let r = SMCParamStruct.keyAtIndexRequest(2298)
        #expect(r.key == 0)
        #expect(r.data8 == kSMCGetKeyFromIndex)
        #expect(r.data32 == 2298)
        #expect(r.subjectDescription == "#2298")
    }

    @Test func writeRequest() {
        let r = SMCParamStruct.writeRequest("F0Tg", bytes: [0x00, 0x80, 0x3b, 0x45]) // 3000.0 flt
        #expect(r.key == SMCKey("F0Tg").code)
        #expect(r.data8 == kSMCWriteKey)
        #expect(r.keyInfo.dataSize == 4)
        #expect(r.payload(count: 6) == [0x00, 0x80, 0x3b, 0x45, 0, 0])
    }

    @Test func failureKindFollowsTheCommand() {
        #expect(SMCParamStruct.writeRequest("F0Md", bytes: [1]).failure(code: 7)
                == .writeFailed(key: "F0Md", code: 7))
        #expect(SMCParamStruct.readRequest("F0Md", size: 1).failure(code: 7)
                == .readFailed(key: "F0Md", code: 7))
        #expect(SMCParamStruct.keyInfoRequest("F0Md").failure(code: 7)
                == .readFailed(key: "F0Md", code: 7))
        #expect(SMCParamStruct.keyAtIndexRequest(3).failure(code: 7)
                == .readFailed(key: "#3", code: 7))
    }

    @Test func validateInterpretsTheResultByte() throws {
        let read = SMCParamStruct.readRequest("FNum", size: 1)
        var reply = SMCParamStruct()
        reply.setPayload([2])
        #expect(try read.validate(reply: reply).payload(count: 1) == [2])

        reply.result = kSMCKeyNotFound
        #expect(throws: FanControlError.keyNotFound("FNum")) { try read.validate(reply: reply) }

        reply.result = 0x85
        #expect(throws: FanControlError.readFailed(key: "FNum", code: 0x85)) { try read.validate(reply: reply) }

        let write = SMCParamStruct.writeRequest("F0Mn", bytes: [0, 0, 0, 0])
        reply.result = 0x86
        #expect(throws: FanControlError.writeFailed(key: "F0Mn", code: 0x86)) { try write.validate(reply: reply) }

        reply.result = kSMCKeyNotFound
        #expect(throws: FanControlError.keyNotFound("#9")) {
            try SMCParamStruct.keyAtIndexRequest(9).validate(reply: reply)
        }
    }

    @Test func dumpLineFormat() {
        let flt = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0xd4, rawType: 0x666c_7420)
        #expect(SMCClient.dumpLine(key: "F0Tg", info: flt, bytes: [0, 0x80, 0x3b, 0x45])
                == "F0Tg  [flt ] size=4 attr=d4  00 80 3b 45")
        #expect(SMCClient.dumpLine(key: "F0Tg", info: flt, bytes: nil)
                == "F0Tg  [flt ] size=4 attr=d4  <read failed>")
        #expect(SMCClient.dumpLine(key: "BDFU", info: nil, bytes: nil) == "BDFU  <no key info>")
        // NULs: shown as "?" in names and as spaces in type names.
        let nulType = SMCKeyInfo(dataSize: 1, dataType: .unknown("ab\0\0"), attributes: 0x0f)
        #expect(SMCClient.dumpLine(key: SMCKey(code: 0x6144_4300), info: nulType, bytes: [])
                == "aDC?  [ab  ] size=1 attr=0f  ")
    }
}
