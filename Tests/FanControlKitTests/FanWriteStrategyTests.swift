import XCTest
import FanControlCore
@testable import FanControlKit

final class FanWriteStrategyTests: XCTestCase {

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

    func testDetectsStyles() {
        XCTAssertEqual(FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1]).style(for: 0), .modeKey)
        XCTAssertEqual(FanWriteStrategy(reader: intel(), fanIndices: [0, 1]).style(for: 1), .forceBits)
        let bare = MockSMCReader([("F0Tg", .fpe2, Bytes.fpe2(1000))])
        XCTAssertEqual(FanWriteStrategy(reader: bare, fanIndices: [0]).style(for: 0), .targetOnly)
        // No F2Tg -> not controllable.
        XCTAssertNil(FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1, 2]).style(for: 2))
    }

    func testAppleSiliconManualWritesModeThenFloatTarget() throws {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let writes = try strategy.setManual(fan: 0, rpm: 3000)
        XCTAssertEqual(names(writes), ["F0Md", "F0Tg"])
        XCTAssertEqual(bytes(writes), [[1], Bytes.flt(3000)])
    }

    func testAppleSiliconAutomatic() throws {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let writes = try strategy.setAutomatic(fan: 1)
        XCTAssertEqual(names(writes), ["F1Md"])
        XCTAssertEqual(bytes(writes), [[0]])
    }

    func testIntelManualSetsBitPreservingOthers() throws {
        let strategy = FanWriteStrategy(reader: intel(), fanIndices: [0, 1])
        let writes = try strategy.setManual(fan: 0, rpm: 2000)
        XCTAssertEqual(names(writes), ["FS! ", "F0Tg"])
        XCTAssertEqual(bytes(writes), [[0x00, 0x03], Bytes.fpe2(2000)])
    }

    func testIntelAutomaticClearsBit() throws {
        let strategy = FanWriteStrategy(reader: intel(mask: [0x00, 0x03]), fanIndices: [0, 1])
        let writes = try strategy.setAutomatic(fan: 1)
        XCTAssertEqual(names(writes), ["FS! "])
        XCTAssertEqual(bytes(writes), [[0x00, 0x01]])
    }

    func testBatchOrdersModesBeforeTargetsAndMergesMask() throws {
        let strategy = FanWriteStrategy(reader: intel(mask: [0x00, 0x00]), fanIndices: [0, 1])
        let writes = try strategy.writes(for: [1: .manual(rpm: 4000), 0: .manual(rpm: 2500)])
        XCTAssertEqual(names(writes), ["FS! ", "F0Tg", "F1Tg"])
        XCTAssertEqual(bytes(writes), [[0x00, 0x03], Bytes.fpe2(2500), Bytes.fpe2(4000)])

        let silicon = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        let mixed = try silicon.writes(for: [0: .manual(rpm: 2000), 1: .automatic])
        XCTAssertEqual(names(mixed), ["F0Md", "F1Md", "F0Tg"])
        XCTAssertEqual(bytes(mixed), [[1], [0], Bytes.flt(2000)])
    }

    func testTargetOnlyFan() throws {
        let bare = MockSMCReader([("F0Tg", .fpe2, Bytes.fpe2(1000))])
        let strategy = FanWriteStrategy(reader: bare, fanIndices: [0])
        XCTAssertEqual(names(try strategy.setManual(fan: 0, rpm: 1800)), ["F0Tg"])
        XCTAssertTrue(try strategy.setAutomatic(fan: 0).isEmpty)
    }

    func testUnknownFanThrows() {
        let strategy = FanWriteStrategy(reader: appleSilicon(), fanIndices: [0, 1])
        XCTAssertThrowsError(try strategy.setManual(fan: 5, rpm: 2000)) { error in
            XCTAssertEqual(error as? FanControlError, .keyNotFound("F5Tg"))
        }
    }

    func testUnencodableTargetTypeThrows() {
        let reader = MockSMCReader([("F0Md", .ui8, [0]), ("F0Tg", .ch8, Array("abcd".utf8))])
        let strategy = FanWriteStrategy(reader: reader, fanIndices: [0])
        XCTAssertThrowsError(try strategy.setManual(fan: 0, rpm: 2000)) { error in
            guard case .unsupportedDataType? = error as? FanControlError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testKitInfo() {
        XCTAssertEqual(FanControlKitInfo.version, "0.1.0")
    }
}
