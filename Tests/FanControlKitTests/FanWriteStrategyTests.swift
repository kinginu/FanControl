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

    private func names(_ writes: [(SMCKey, [UInt8])]) -> [String] { writes.map { $0.0.name } }
    private func bytes(_ writes: [(SMCKey, [UInt8])]) -> [[UInt8]] { writes.map { $0.1 } }

    @Test func testDetectsControllableFans() {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1, 2])
        #expect(Set(strategy.fans.keys) == [0, 1])
        #expect(strategy.fans[0]?.mode.dataType == .ui8)
        // No F2Tg -> not controllable, and not reported as missing a mode key.
        #expect(strategy.fansMissingModeKey.isEmpty)
    }

    /// Apple Silicon only (Intel dropped 2026-10-20): a fan with `F<n>Tg` but no
    /// `F<n>Md` (Intel `FS! ` layout, or a target-only SMC) is rejected with a clear
    /// error instead of falling back to `FS! ` or target-only writes.
    @Test func testRejectsFanSetWithoutModeKey() throws {
        let intelLayout = MockSMCReader([
            ("FNum", .ui8, [2]),
            ("FS! ", .ui16, [0x00, 0x00]),
            ("F0Tg", .fpe2, Bytes.fpe2(1200)),
            ("F1Tg", .fpe2, Bytes.fpe2(1300)),
        ])
        let strategy = FanWriteStrategy(reader: intelLayout, fanIndices: [0, 1])
        #expect(strategy.fans.isEmpty)
        #expect(strategy.fansMissingModeKey == [0, 1])
        #expect(throws: FanControlError.fanModeKeyMissing(fan: 0)) {
            try strategy.setManual(fan: 0, rpm: 2000)
        }
        #expect(throws: FanControlError.fanModeKeyMissing(fan: 1)) {
            try strategy.setAutomatic(fan: 1)
        }
        #expect(try strategy.rollbackWrites(afterFailureOf: [0: .manual(rpm: 2000)]).isEmpty)

        // Mixed: one fan with F<n>Md, one without -> the whole list is refused.
        let mixed = MockSMCReader([("F0Md", .ui8, [0]), ("F0Tg", .flt, Bytes.flt(0)), ("F1Tg", .flt, Bytes.flt(0))])
        let partial = FanWriteStrategy(reader: mixed, fanIndices: [0, 1])
        #expect(throws: FanControlError.fanModeKeyMissing(fan: 1)) {
            try partial.writes(for: [0: .manual(rpm: 2000), 1: .manual(rpm: 2000)])
        }
        #expect(FanControlError.fanModeKeyMissing(fan: 1).errorDescription?.contains("F1Md") == true)
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

    @Test func testBatchOrdersModesBeforeTargets() throws {
        let silicon = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let mixed = try silicon.writes(for: [0: .manual(rpm: 2000), 1: .automatic])
        #expect(names(mixed) == ["F0Md", "F1Md", "F0Tg"])
        #expect(bytes(mixed) == [[1], [0], Bytes.flt(2000)])
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
        #expect(strategy.fansMissingModeKey.isEmpty)
        #expect(strategy.fans[0]?.mode.dataType == .ui8)
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

    }

    @Test func testKitInfo() {
        #expect(FanControlKitInfo.version == "0.1.0")
    }
}
