import Foundation
import Testing
@testable import FanControlKit

@Suite("Apply generation gate", .tags(.control, .concurrency))
struct ApplyGenerationGateTests {

    @Test func startsAtZeroAndNothingIsStale() {
        let gate = ApplyGenerationGate()
        #expect(gate.current == 0)
        #expect(!gate.isStale(0))
    }

    @Test func advanceIsStrictlyIncreasing() {
        var gate = ApplyGenerationGate()
        let first = gate.advance()
        let second = gate.advance()
        #expect(first == 1)
        #expect(second == 2)
        #expect(gate.current == 2)
    }

    /// A poll batch planned before a user apply is dropped; one planned after it is kept.
    @Test func batchPlannedBeforeApplyIsDropped() {
        var gate = ApplyGenerationGate()
        let plannedBefore = gate.current      // poll snapshots the generation when planning
        gate.advance()                        // user apply starts before the batch is written
        let plannedAfter = gate.current
        #expect(gate.isStale(plannedBefore))
        #expect(!gate.isStale(plannedAfter))
    }

    @Test func severalAppliesInARow() {
        var gate = ApplyGenerationGate()
        let batch = gate.current
        gate.advance()
        gate.advance()
        #expect(gate.isStale(batch))
        #expect(gate.isStale(gate.current - 1))
        #expect(!gate.isStale(gate.current))
    }
}
