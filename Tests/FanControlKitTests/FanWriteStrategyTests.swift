import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

struct FanWriteStrategyTests {

    private func appleSilicon() -> MockSMCReader {
        MockSMCReader([
            ("FNum", .ui8, [2]),
            ("F0Md", .ui8, [0]),
            ("F0Tg", .flt, Bytes.flt(1200)),
            ("F1Md", .ui8, [0]),
            ("F1Tg", .flt, Bytes.flt(1200)),
        ])
    }

    private func intel(mask: [UInt8] = [0x00, 0x02]) -> MockSMCReader {
        MockSMCReader([
            ("FNum", .ui8, [2]),
            ("FS! ", .ui16, mask),
            ("F0Tg", .fpe2, Bytes.fpe2(1200)),
            ("F1Tg", .fpe2, Bytes.fpe2(1300)),
        ])
    }

    private func names(_ writes: [(SMCKey, [UInt8])]) -> [String] { writes.map { $0.0.name } }
    private func bytes(_ writes: [(SMCKey, [UInt8])]) -> [[UInt8]] { writes.map { $0.1 } }

    @Test func testDetectsStyles() {
        #expect(FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1]).style(for: 0) == .modeKey)
        #expect(FanWriteStrategy(reader: intel(), fanIndices: [0, 1]).style(for: 1) == .forceBits)
        let bare = MockSMCReader([("F0Tg", .fpe2, Bytes.fpe2(1000))])
        #expect(FanWriteStrategy(reader: bare, fanIndices: [0]).style(for: 0) == .targetOnly)
        // No F2Tg -> not controllable.
        #expect(FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1, 2]).style(for: 2) == nil)
    }

    @Test func testAppleSiliconManualWritesModeThenFloatTarget() throws {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let writes = try strategy.setManual(fan: 0, rpm: 3000)
        #expect(names(writes) == ["F0Md", "F0Tg"])
        #expect(bytes(writes) == [[1], Bytes.flt(3000)])
    }

    @Test func testAppleSiliconAutomatic() throws {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let writes = try strategy.setAutomatic(fan: 1)
        #expect(names(writes) == ["F1Md"])
        #expect(bytes(writes) == [[0]])
    }

    @Test func testIntelManualSetsBitPreservingOthers() throws {
        let strategy = FanWriteStrategy(reader: intel(), fanIndices: [0, 1])
        let writes = try strategy.setManual(fan: 0, rpm: 2000)
        #expect(names(writes) == ["FS! ", "F0Tg"])
        #expect(bytes(writes) == [[0x00, 0x03], Bytes.fpe2(2000)])
    }

    @Test func testIntelAutomaticClearsBit() throws {
        let strategy = FanWriteStrategy(reader: intel(mask: [0x00, 0x03]), fanIndices: [0, 1])
        let writes = try strategy.setAutomatic(fan: 1)
        #expect(names(writes) == ["FS! "])
        #expect(bytes(writes) == [[0x00, 0x01]])
    }

    @Test func testBatchOrdersModesBeforeTargetsAndMergesMask() throws {
        let strategy = FanWriteStrategy(reader: intel(mask: [0x00, 0x00]), fanIndices: [0, 1])
        let writes = try strategy.writes(for: [1: .manual(rpm: 4000), 0: .manual(rpm: 2500)])
        #expect(names(writes) == ["FS! ", "F0Tg", "F1Tg"])
        #expect(bytes(writes) == [[0x00, 0x03], Bytes.fpe2(2500), Bytes.fpe2(4000)])

        let silicon = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let mixed = try silicon.writes(for: [0: .manual(rpm: 2000), 1: .automatic])
        #expect(names(mixed) == ["F0Md", "F1Md", "F0Tg"])
        #expect(bytes(mixed) == [[1], [0], Bytes.flt(2000)])
    }

    @Test func testTargetOnlyFan() throws {
        let bare = MockSMCReader([("F0Tg", .fpe2, Bytes.fpe2(1000))])
        let strategy = FanWriteStrategy(reader: bare, fanIndices: [0])
        #expect(names(try strategy.setManual(fan: 0, rpm: 1800)) == ["F0Tg"])
        #expect(try strategy.setAutomatic(fan: 0).isEmpty)
    }

    @Test func testUnknownFanThrows() {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        #expect(throws: FanControlError.keyNotFound("F5Tg")) {
            try strategy.setManual(fan: 5, rpm: 2000)
        }
    }

    @Test func testUnencodableTargetTypeThrows() {
        let reader = MockSMCReader([("F0Md", .ui8, [0]), ("F0Tg", .ch8, Array("abcd".utf8))])
        let strategy = FanWriteStrategy(reader: reader, fanIndices: [0])
        do {
            _ = try strategy.setManual(fan: 0, rpm: 2000)
            Issue.record("expected an error")
        } catch {
            guard case .unsupportedDataType? = error as? FanControlError else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    // MARK: Pre-write review 2026-10-20 (Mac14,9 key layout)

    /// Mac14,9 idle state: Md = 0, Tg = 0 (below Mn), Mn 2317, Mx 6800, no FS!.
    private func mac14_9() -> MockSMCReader {
        var list: [(String, SMCDataType, [UInt8])] = [("FNum", .ui8, [2])]
        for i in 0..<2 {
            list += [("F\(i)Ac", .flt, Bytes.flt(0)), ("F\(i)Md", .ui8, [0]),
                     ("F\(i)Mn", .flt, [0x00, 0xd0, 0x10, 0x45]), ("F\(i)Mx", .flt, [0x00, 0x80, 0xd4, 0x45]),
                     ("F\(i)Tg", .flt, Bytes.flt(0))]
        }
        return MockSMCReader(list)
    }

    @Test func testMac14_9UsesModeKeyAndReadsLimits() throws {
        let strategy = FanWriteStrategy(reader: mac14_9(), fanIndices: [0, 1])
        #expect(strategy.forceBits == nil)
        #expect(strategy.style(for: 0) == .modeKey)
        #expect(strategy.fans[1]?.rpmLimits == 2317...6800)
        let writes = try strategy.writes(for: [0: .manual(rpm: 2317), 1: .manual(rpm: 6800)])
        #expect(names(writes) == ["F0Md", "F1Md", "F0Tg", "F1Tg"])
        // ui8 1 and little-endian flt, byte-identical to the dump's F<n>Mn / F<n>Mx.
        #expect(bytes(writes) == [[1], [1], [0x00, 0xd0, 0x10, 0x45], [0x00, 0x80, 0xd4, 0x45]])
        // Never Mn, Ftst or FS!.
        #expect(!names(writes).contains { $0.hasSuffix("Mn") || $0 == "Ftst" || $0 == "FS! " })
    }

    @Test func testTargetOutsideHardwareRangeThrowsBeforeAnyWrite() {
        let strategy = FanWriteStrategy(reader: mac14_9(), fanIndices: [0, 1])
        // Sub-minimum (e.g. enforceHardwareMinimum = false) and the idle value 0.
        for rpm in [0, 1000, 2315, 6802] {
            #expect(throws: FanControlError.rpmOutOfRange(fan: 1, rpm: rpm, allowed: 2317...6800)) {
                try strategy.writes(for: [0: .manual(rpm: 3000), 1: .manual(rpm: rpm)])
            }
        }
        #expect((try? strategy.setManual(fan: 0, rpm: 2316)) != nil) // within ±1 slack
    }

    @Test func testRollbackWritesReturnForcedFansToAutomatic() throws {
        let strategy = FanWriteStrategy(reader: mac14_9(), fanIndices: [0, 1])
        let rollback = try strategy.rollbackWrites(afterFailureOf: [0: .manual(rpm: 3000), 1: .automatic, 7: .manual(rpm: 1)])
        #expect(names(rollback) == ["F0Md"])
        #expect(bytes(rollback) == [[0]])
        #expect(try strategy.rollbackWrites(afterFailureOf: [1: .automatic]).isEmpty)

        let intelStrategy = FanWriteStrategy(reader: intel(mask: [0x00, 0x03]), fanIndices: [0, 1])
        let intelRollback = try intelStrategy.rollbackWrites(afterFailureOf: [0: .manual(rpm: 2000)])
        #expect(names(intelRollback) == ["FS! "])
        #expect(bytes(intelRollback) == [[0x00, 0x02]])

        let bare = FanWriteStrategy(reader: MockSMCReader([("F0Tg", .fpe2, Bytes.fpe2(1000))]), fanIndices: [0])
        #expect(try bare.rollbackWrites(afterFailureOf: [0: .manual(rpm: 1800)]).isEmpty)
    }

    @Test func testKitInfo() {
        #expect(FanControlKitInfo.version == "0.1.0")
    }
}
