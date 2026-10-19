import XCTest
@testable import FanControlKit

final class ApplyGenerationGateTests: XCTestCase {

    func testStartsAtZeroAndNothingIsStale() {
        let gate = ApplyGenerationGate()
        XCTAssertEqual(gate.current, 0)
        XCTAssertFalse(gate.isStale(0))
    }

    func testAdvanceIsStrictlyIncreasing() {
        var gate = ApplyGenerationGate()
        let first = gate.advance()
        let second = gate.advance()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(gate.current, 2)
    }

    /// A poll batch planned before a user apply is dropped; one planned after it is kept.
    func testBatchPlannedBeforeApplyIsDropped() {
        var gate = ApplyGenerationGate()
        let plannedBefore = gate.current      // poll snapshots the generation when planning
        gate.advance()                        // user apply starts before the batch is written
        let plannedAfter = gate.current
        XCTAssertTrue(gate.isStale(plannedBefore))
        XCTAssertFalse(gate.isStale(plannedAfter))
    }

    func testSeveralAppliesInARow() {
        var gate = ApplyGenerationGate()
        let batch = gate.current
        gate.advance()
        gate.advance()
        XCTAssertTrue(gate.isStale(batch))
        XCTAssertTrue(gate.isStale(gate.current - 1))
        XCTAssertFalse(gate.isStale(gate.current))
    }
}
