import Testing
import FanControlCore
@testable import FanControlKit

struct UnsettledFanDetectorTests {
    private let fans = [FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
                        FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)]
    private let controllable: Set<Int> = [0, 1]
    private typealias O = UnsettledFanDetector.Observation

    private func detect(_ applied: [Int: FanTarget], _ observed: [Int: O],
                        controllable: Set<Int>? = nil) -> Set<Int> {
        UnsettledFanDetector.unsettledFans(fans: fans, controllable: controllable ?? self.controllable,
                                           applied: applied, observed: observed)
    }

    @Test func settledFansAreNotFlagged() {
        #expect(detect([0: .manual(rpm: 3000), 1: .automatic],
                       [0: O(isManual: true, targetRPM: 3000), 1: O(isManual: false, targetRPM: 0)]).isEmpty)
        // Within tolerance.
        #expect(detect([0: .manual(rpm: 3000)], [0: O(isManual: true, targetRPM: 3040)]).isEmpty)
    }

    /// First-write test 4: after wake both fans read Md=1 / Tg=0.
    @Test func manualWithTargetBelowMinimumAfterWake() {
        #expect(detect([0: .manual(rpm: 3000), 1: .automatic],
                       [0: O(isManual: true, targetRPM: 0), 1: O(isManual: true, targetRPM: 0)]) == [0, 1])
        // Also for a fan never written in this session.
        #expect(detect([:], [1: O(isManual: true, targetRPM: 0)]) == [1])
    }

    @Test func manualControlDropped() {
        #expect(detect([0: .manual(rpm: 3000)], [0: O(isManual: false, targetRPM: 2468)]) == [0])
    }

    @Test func targetDrifted() {
        #expect(detect([0: .manual(rpm: 3000)], [0: O(isManual: true, targetRPM: 4000)]) == [0])
    }

    @Test func forcedAlthoughAppliedAutomatic() {
        #expect(detect([1: .automatic], [1: O(isManual: true, targetRPM: 3000)]) == [1])
        // Not written by us and at a sane target: left alone (could be another tool).
        #expect(detect([:], [1: O(isManual: true, targetRPM: 3000)]).isEmpty)
    }

    @Test func uncontrollableOrUnreadFansSkipped() {
        #expect(detect([0: .manual(rpm: 3000)], [0: O(isManual: true, targetRPM: 0)], controllable: []).isEmpty)
        #expect(detect([0: .manual(rpm: 3000)], [:]).isEmpty)
    }
}
