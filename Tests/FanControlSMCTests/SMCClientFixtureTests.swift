import Foundation
import Testing
import FanControlCore
@testable import FanControlSMC

/// `SMCClient` against an in-memory SMC loaded with the Mac14,9 / macOS 26 dump.
struct SMCClientFixtureTests {
    @Test func fixtureLoads() throws {
        #expect(DumpFixture.lines.first == "# SMC keys: 2299")
        #expect(DumpFixture.entries.count == 2299)
        #expect(DumpFixture.entries.count == DumpFixture.lines.count - 1)
    }

    /// `dump()` of the fixture reproduces the fixture line for line, so the dump format
    /// (and `fanfi-probe --dump`) is unchanged.
    @Test func dumpRoundTripsTheFixture() {
        let client = SMCClient(transport: DumpFixture.smc())
        let lines = client.dump().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == DumpFixture.lines.count)
        var mismatches: [String] = []
        for (got, want) in zip(lines, DumpFixture.lines) where !DumpFixture.isRedacted(want) && got != want {
            mismatches.append("got  \(got)\nwant \(want)")
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).joined(separator: "\n"))")
    }

    @Test func keyCountReadsBigEndianKEY() throws {
        let client = SMCClient(transport: DumpFixture.smc())
        #expect(try client.keyCount() == 2299) // 00 00 08 fb
        #expect(try client.key(at: 0) == "#KEY")
    }

    // MARK: Decoding real byte patterns

    struct Case: Sendable, CustomTestStringConvertible {
        let key: SMCKey
        let type: String
        let value: SMCValue
        var testDescription: String { "\(key.name) [\(type)]" }
    }

    static let decodeCases: [Case] = [
        // flt: little-endian Float32 (fans and temperatures on Apple Silicon).
        Case(key: "F0Mn", type: "flt ", value: .number(2317)),           // 00 d0 10 45
        Case(key: "F0Mx", type: "flt ", value: .number(6800)),           // 00 80 d4 45
        Case(key: "F1Mx", type: "flt ", value: .number(6800)),
        Case(key: "F0Ac", type: "flt ", value: .number(0)),              // idle fan
        Case(key: "F0Tg", type: "flt ", value: .number(0)),
        Case(key: "TB0T", type: "flt ", value: .number(33)),             // 00 00 04 42
        Case(key: "TCMz", type: "flt ", value: .number(Double(Float(bitPattern: 0x429b_f19a)))), // ≈ 77.97
        Case(key: "Tp01", type: "flt ", value: .number(Double(Float(bitPattern: 0x4271_92f5)))), // ≈ 60.39
        // ui8 / ui16 / ui32: big-endian.
        Case(key: "FNum", type: "ui8 ", value: .number(2)),
        Case(key: "F0Md", type: "ui8 ", value: .number(0)),
        Case(key: "ACCF", type: "ui8 ", value: .number(0x1e)),
        Case(key: "F0Fc", type: "ui16", value: .number(4)),              // 00 04
        Case(key: "ACDI", type: "ui16", value: .number(0x780f)),
        Case(key: "#KEY", type: "ui32", value: .number(2299)),
        Case(key: "FOFC", type: "ui32", value: .number(0x2d1)),          // 00 00 02 d1
        // si8: two's complement.
        Case(key: "AC-B", type: "si8 ", value: .number(-1)),             // ff
        Case(key: "AC-W", type: "si8 ", value: .number(1)),
        // flag.
        Case(key: "AC-C", type: "flag", value: .flag(false)),
        Case(key: "AC-S", type: "flag", value: .flag(true)),
        // ioft: little-endian 48.16 fixed point.
        Case(key: "TG0B", type: "ioft", value: .number(33)),             // 00 00 21 00 00 00 00 00
        // ch8*: NUL-terminated ASCII.
        Case(key: "RPlt", type: "ch8*", value: .string("j414s")),
        Case(key: "BMDN", type: "ch8*", value: .string("bq40z651")),
        // hex_ and unknown types: raw bytes.
        Case(key: "AC-M", type: "hex_", value: .bytes([0x02, 0x02])),
        Case(key: "D2JD", type: "{jst", value: .bytes([0, 0, 0, 0, 0, 0, 0, 0, 0x4c, 0x1d, 0x4c, 0x1d,
                                                       0, 0, 0, 0, 0x4c, 0x1d, 0, 0, 0])),
    ]

    @Test(arguments: decodeCases)
    func decodesRealBytes(_ c: Case) throws {
        let client = SMCClient(transport: DumpFixture.smc())
        let info = try client.keyInfo(c.key)
        #expect(info.dataType.name == c.type)
        #expect(try client.readBytes(c.key).count == info.dataSize)
        #expect(try client.readValue(c.key) == c.value)
    }

    /// Every readable fixture key whose type is a fixed-width numeric type decodes to a
    /// finite number (the sizes the SMC reports always match the type widths).
    @Test func everyReadableNumericKeyDecodes() throws {
        let client = SMCClient(transport: DumpFixture.smc())
        var checked = 0
        for entry in DumpFixture.entries {
            guard let info = entry.info, info.dataType.isNumeric, entry.bytes != nil,
                  info.dataSize <= SMCParamStruct.bytesCapacity else { continue }
            let key = SMCKey(code: InMemorySMC.code(entry.name))
            let number = try client.readNumber(key)
            #expect(number.isFinite, "\(entry.name)")
            checked += 1
        }
        #expect(checked > 1500)
    }

    @Test func attributesMatchTheFanKeys() throws {
        let client = SMCClient(transport: DumpFixture.smc())
        let target = try client.keyInfo(.fanTarget(0))   // attr d4
        let mode = try client.keyInfo(.fanMode(0))       // attr d0
        let minimum = try client.keyInfo(.fanMin(0))     // attr 84
        #expect(target.isReadable && target.isWritable)
        #expect(mode.isReadable && mode.isWritable)
        #expect(minimum.isReadable && !minimum.isWritable)
        #expect(target.dataSize == 4 && mode.dataSize == 1)
    }

    // MARK: Failures

    @Test func missingKeyThrowsKeyNotFound() {
        let client = SMCClient(transport: DumpFixture.smc())
        #expect(throws: FanControlError.keyNotFound("Ftst")) { try client.keyInfo("Ftst") }
        #expect(throws: FanControlError.keyNotFound("Ftst")) { try client.readBytes("Ftst") }
        #expect(!client.exists("Ftst"))
        #expect(client.exists(.fanTarget(1)))
    }

    @Test func keyWithoutInfoThrowsKeyNotFound() {
        let client = SMCClient(transport: DumpFixture.smc())
        #expect(throws: FanControlError.keyNotFound("BDFU")) { try client.keyInfo("BDFU") }
    }

    @Test func unreadableKeyReportsTheSMCResultByte() {
        let client = SMCClient(transport: DumpFixture.smc())
        // AC-E [flag] attr=50: no read bit; the SMC answers 0x85.
        #expect(throws: FanControlError.readFailed(key: "AC-E", code: Int32(InMemorySMC.resultNotReadable))) {
            try client.readBytes("AC-E")
        }
    }

    @Test func oversizedKeyFailsLocallyWithoutReading() throws {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        // ACKG [hex_] size=118 does not fit the 32-byte payload.
        #expect(try client.keyInfo("ACKG").dataSize == 118)
        #expect(throws: FanControlError.readFailed(key: "ACKG", code: -1)) { try client.readBytes("ACKG") }
        #expect(smc.requests(command: kSMCReadKey).isEmpty)
    }

    @Test func keyIndexOutOfRange() {
        let client = SMCClient(transport: DumpFixture.smc())
        #expect(throws: FanControlError.readFailed(key: "#-1", code: -1)) { try client.key(at: -1) }
        #expect(throws: FanControlError.readFailed(key: "#\(Int(UInt32.max) + 1)", code: -1)) {
            try client.key(at: Int(UInt32.max) + 1)
        }
        #expect(throws: FanControlError.readFailed(key: "#2299", code: Int32(InMemorySMC.resultIndexRange))) {
            try client.key(at: 2299)
        }
    }

    @Test func transportFailuresPropagate() {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        let notPrivileged = Int32(bitPattern: 0xE000_02C1) // kIOReturnNotPrivileged
        smc.failTransport(with: notPrivileged)
        #expect(throws: FanControlError.readFailed(key: "FNum", code: notPrivileged)) { try client.keyInfo(.fanCount) }
        #expect(client.dump() == "SMC dump failed: \(FanControlError.readFailed(key: "#KEY", code: notPrivileged))")
    }

    // MARK: Cache and lifetime

    @Test func keyInfoIsCachedButFailuresAreNot() throws {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        _ = try client.keyInfo(.fanTarget(0))
        _ = try client.keyInfo(.fanTarget(0))
        _ = try client.readNumber(.fanTarget(0))
        _ = try client.readNumber(.fanTarget(0))
        _ = client.exists("Ftst")
        _ = client.exists("Ftst")
        let infoRequests = smc.requests(command: kSMCGetKeyInfo).map { SMCKey(code: $0.key).name }
        #expect(infoRequests == ["F0Tg", "Ftst", "Ftst"])
        #expect(smc.requests(command: kSMCReadKey).count == 2)
    }

    @Test func readRequestCarriesTheKeySize() throws {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        _ = try client.readBytes("TG0B")
        let read = try #require(smc.requests(command: kSMCReadKey).first)
        #expect(read.key == SMCKey("TG0B").code)
        #expect(read.keyInfo.dataSize == 8)
    }

    @Test func closeStopsReadsButKeepsCachedInfo() throws {
        let client = SMCClient(transport: DumpFixture.smc())
        let info = try client.keyInfo(.fanCount)
        client.close()
        client.close() // idempotent
        #expect(try client.keyInfo(.fanCount) == info)
        #expect(throws: FanControlError.smcUnavailable) { try client.readBytes(.fanCount) }
        #expect(throws: FanControlError.smcUnavailable) { try client.keyInfo(.fanMode(0)) }
        #expect(client.dump() == "SMC dump failed: \(FanControlError.smcUnavailable)")
    }

    // MARK: Writing (in-memory only; never against the real SMC)

    @Test func writeSendsExactlyTheKeySize() throws {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        let rpm = try #require(SMCCodec.encode(3000, as: .flt, size: 4))
        try client.writeBytes(rpm, to: .fanTarget(0))
        try client.writeBytes([1], to: .fanMode(0))
        let writes = smc.requests(command: kSMCWriteKey)
        #expect(writes.map { SMCKey(code: $0.key).name } == ["F0Tg", "F0Md"])
        #expect(writes.map(\.keyInfo.dataSize) == [4, 1])
        #expect(smc.bytes(of: "F0Tg") == rpm)
        #expect(try client.readNumber(.fanTarget(0)) == 3000)
        #expect(try client.readNumber(.fanMode(0)) == 1)
    }

    @Test func writeValidatesSizeBeforeTouchingTheSMC() {
        let smc = DumpFixture.smc()
        let client = SMCClient(transport: smc)
        #expect(throws: FanControlError.writeFailed(key: "F0Tg", code: -1)) { try client.writeBytes([], to: .fanTarget(0)) }
        #expect(throws: FanControlError.writeFailed(key: "F0Tg", code: -1)) { try client.writeBytes([0, 0], to: .fanTarget(0)) }
        #expect(throws: FanControlError.writeFailed(key: "F0Tg", code: -1)) {
            try client.writeBytes([UInt8](repeating: 0, count: 33), to: .fanTarget(0))
        }
        #expect(throws: FanControlError.keyNotFound("Ftst")) { try client.writeBytes([1], to: "Ftst") }
        #expect(smc.requests(command: kSMCWriteKey).isEmpty)
    }

    @Test func writeRejectionReportsTheSMCResultByte() {
        let client = SMCClient(transport: DumpFixture.smc())
        // F0Mn attr=84: no write bit; the SMC answers 0x86.
        #expect(throws: FanControlError.writeFailed(key: "F0Mn", code: Int32(InMemorySMC.resultNotWritable))) {
            try client.writeBytes([0, 0, 0, 0], to: .fanMin(0))
        }
    }

    @Test func concurrentReadsAreSafe() async throws {
        let client = SMCClient(transport: DumpFixture.smc())
        let total = try await withThrowingTaskGroup(of: Double.self) { group in
            for i in 0..<64 {
                group.addTask { try client.readNumber(i.isMultiple(of: 2) ? .fanMax(0) : .fanMax(1)) }
            }
            return try await group.reduce(0, +)
        }
        #expect(total == 64 * 6800)
    }
}
