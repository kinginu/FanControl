import Foundation
import Testing
import FanControlCore
@testable import FanControlXPC

/// Values from the Mac14,9 / macOS 26 dump (`docs/verification/Mac14,9-macOS26-dump.txt`).
private enum Mac14_9 {
    static let md = SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd0)
    static let tg = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0xd4)
    static let mn = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0x84)
    static let limits: [Int: ClosedRange<Double>] = [0: 2317...6800, 1: 2317...6800]
    static func flt(_ v: Double) -> [UInt8] { SMCCodec.encode(v, as: .flt, size: 4)! }
    static func info(_ key: SMCKey) -> SMCKeyInfo? {
        switch key.name.suffix(2) {
        case "Md": return md
        case "Tg": return tg
        case "Mn": return mn
        default: return nil
        }
    }
}

/// Records restore writes; keys in `failing` throw.
private final class RecordingWriter {
    var writes: [(String, [UInt8])] = []
    var failing: Set<String> = []
    struct Failure: Error {}
    func write(_ key: SMCKey, _ bytes: [UInt8]) throws {
        writes.append((key.name, bytes))
        if failing.contains(key.name) { throw Failure() }
    }
}

struct HelperWritePolicyTests {

    private func validate(_ bytes: [UInt8], _ key: SMCKey, _ info: SMCKeyInfo) -> HelperWritePolicy.Rejection? {
        HelperWritePolicy.validate(bytes, for: key, info: info, fanCount: 2, fanLimits: Mac14_9.limits)
    }

    // MARK: Validation

    @Test func testMac14_9FloatEncodingMatchesDump() {
        // F0Mn / F0Mx raw bytes as read on hardware.
        #expect(Mac14_9.flt(2317) == [0x00, 0xd0, 0x10, 0x45])
        #expect(Mac14_9.flt(6800) == [0x00, 0x80, 0xd4, 0x45])
    }

    @Test func testAcceptsValidAppleSiliconWrites() {
        #expect(validate([1], "F0Md", Mac14_9.md) == nil)
        #expect(validate([0], "F1Md", Mac14_9.md) == nil)
        #expect(validate(Mac14_9.flt(2317), "F0Tg", Mac14_9.tg) == nil)
        #expect(validate(Mac14_9.flt(6800), "F1Tg", Mac14_9.tg) == nil)
        #expect(validate(Mac14_9.flt(2316.5), "F0Tg", Mac14_9.tg) == nil) // ±1 RPM rounding slack
    }

    @Test func testRejectsTargetsOutsideHardwareRange() {
        // The Apple Silicon idle snapshot (Tg = 0) is not a valid write.
        #expect(validate(Mac14_9.flt(0), "F0Tg", Mac14_9.tg)?.code == .badRequest)
        #expect(validate(Mac14_9.flt(2315), "F0Tg", Mac14_9.tg)?.code == .badRequest)
        #expect(validate(Mac14_9.flt(6802), "F0Tg", Mac14_9.tg)?.code == .badRequest)
        #expect(validate([0x00, 0x00, 0xc0, 0x7f], "F0Tg", Mac14_9.tg)?.code == .badRequest) // NaN
        // Fan without limits.
        #expect(validate(Mac14_9.flt(3000), "F2Tg", Mac14_9.tg)?.code == .smcError)
    }

    @Test func testRejectsBadModeValuesAndSizes() {
        #expect(validate([2], "F0Md", Mac14_9.md)?.code == .badRequest)
        #expect(validate([0xff], "F0Md", Mac14_9.md)?.code == .badRequest)
        #expect(validate([1, 0], "F0Md", Mac14_9.md)?.code == .badRequest)
        #expect(validate([0, 0], "F0Tg", Mac14_9.tg)?.code == .badRequest)
    }

    @Test func testRejectsKeysWithoutWriteAttribute() {
        // F<n>Mn is 0x84 on Mac14,9: refused even with an in-range value.
        #expect(validate(Mac14_9.flt(2317), "F0Mn", Mac14_9.mn)?.code == .badRequest)
        let readOnlyTarget = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0x84)
        #expect(validate(Mac14_9.flt(3000), "F0Tg", readOnlyTarget)?.code == .badRequest)
    }

    @Test func testForceBitsValidation() {
        let fs = SMCKeyInfo(dataSize: 2, dataType: .ui16, attributes: 0xd4)
        #expect(validate([0x00, 0x03], .forceBits, fs) == nil)
        #expect(validate([0x00, 0x04], .forceBits, fs)?.code == .badRequest) // fan 2 >= FNum
        #expect(HelperWritePolicy.validate([0, 1], for: .forceBits, info: fs, fanCount: nil, fanLimits: [:])?.code == .smcError)
    }

    // MARK: Restore

    @discardableResult
    private func restore(_ originals: [(key: SMCKey, bytes: [UInt8])], touched: UInt64 = 0,
                         writer: RecordingWriter) -> [HelperWritePolicy.RestoreWrite] {
        HelperWritePolicy.restore(originals: originals, touchedForceBits: touched, fanLimits: Mac14_9.limits,
                                  keyInfo: Mac14_9.info, write: writer.write)
    }

    @Test func testAppleSiliconIdleSnapshotRestoresModeOnly() {
        // Session started at idle (Md = 0, Tg = 0 < Mn), client wrote Md = 1 and Tg.
        let writer = RecordingWriter()
        restore([("F0Md", [0]), ("F0Tg", Mac14_9.flt(0)), ("F1Md", [0]), ("F1Tg", Mac14_9.flt(0))], writer: writer)
        #expect(writer.writes.map(\.0) == ["F0Md", "F1Md"])
        #expect(writer.writes.map(\.1) == [[0], [0]])
    }

    @Test func testModeKeyForcedToAutomaticEvenIfSnapshotWasManual() {
        let writer = RecordingWriter()
        restore([("F0Md", [1]), ("F0Tg", Mac14_9.flt(4000))], writer: writer)
        #expect(writer.writes.map(\.0) == ["F0Md"])
        #expect(writer.writes.map(\.1) == [[0]])
    }

    @Test func testFailedModeRestoreIsRetriedAndTargetLeftAlone() {
        let writer = RecordingWriter()
        writer.failing = ["F0Md"]
        var logs: [String] = []
        let result = HelperWritePolicy.restore(
            originals: [("F0Md", [0]), ("F0Tg", Mac14_9.flt(0)), ("F1Md", [0])],
            touchedForceBits: 0, fanLimits: Mac14_9.limits, keyInfo: Mac14_9.info,
            write: writer.write, log: { logs.append($0) })
        // Two attempts at F0Md, then F1Md; the sub-minimum Tg snapshot is never written.
        #expect(writer.writes.map(\.0) == ["F0Md", "F0Md", "F1Md"])
        #expect(result.filter { !$0.succeeded }.count == 2)
        #expect(logs.contains { $0.contains("F0Md could not be set to automatic") })
    }

    @Test func testTargetOnlyFanRestoredClampedIntoRange() {
        let writer = RecordingWriter()
        restore([("F0Tg", Mac14_9.flt(0)), ("F1Tg", Mac14_9.flt(3000))], writer: writer)
        #expect(writer.writes.map(\.0) == ["F0Tg", "F1Tg"])
        #expect(writer.writes.map(\.1) == [Mac14_9.flt(2317), Mac14_9.flt(3000)])
    }

    @Test func testIntelForceBitsClearedAndTargetsOfForcedFansSkipped() {
        let writer = RecordingWriter()
        // Snapshot FS! = 0b10 (fan 1 forced by someone else), this session forced fan 0.
        restore([("FS! ", [0x00, 0x02]), ("F0Tg", [0x00, 0x00]), ("F0Mn", [0x1f, 0x40])], touched: 0b01, writer: writer)
        // Mn first, then FS! with only our bit cleared; F0Tg skipped (fan 0 handed back).
        #expect(writer.writes.map(\.0) == ["F0Mn", "FS! "])
        #expect(writer.writes.map(\.1) == [[0x1f, 0x40], [0x00, 0x02]])
    }

    @Test func testEmptySessionWritesNothing() {
        let writer = RecordingWriter()
        #expect(restore([], writer: writer).isEmpty)
        #expect(writer.writes.isEmpty)
    }

    @Test func testModeKeyClassification() {
        #expect(HelperWritePolicy.isModeKey("F0Md"))
        #expect(HelperWritePolicy.isModeKey(.forceBits))
        #expect(!HelperWritePolicy.isModeKey("F0Tg"))
        #expect(!HelperWritePolicy.isModeKey("FNum"))
        #expect(HelperWritePolicy.clearingBits(0b01, in: [0x00, 0x03]) == [0x00, 0x02])
    }
}
