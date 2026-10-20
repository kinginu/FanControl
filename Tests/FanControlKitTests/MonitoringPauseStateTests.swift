import Testing
@testable import FanControlKit

@Suite("Monitoring pause state", .tags(.manager))
struct MonitoringPauseStateTests {

    @Test func pauseOnlyInEffectWithoutHolds() {
        var state = MonitoringPauseState()
        #expect(!state.isInEffect)
        state.requested = true
        #expect(state.isInEffect)
        // Settings pane opened while the Nook is hidden: live polling.
        state.setHold(true, for: "settings")
        #expect(!state.isInEffect)
        // Pane closed: back to the requested pause, nothing to restore by hand.
        state.setHold(false, for: "settings")
        #expect(state.isInEffect)
    }

    @Test func holdsAreKeyedAndIdempotent() {
        var state = MonitoringPauseState()
        state.requested = true
        state.setHold(true, for: "settings")
        state.setHold(true, for: "settings")
        state.setHold(true, for: "sensors")
        state.setHold(false, for: "settings")
        #expect(!state.isInEffect)          // "sensors" still holds
        state.setHold(false, for: "sensors")
        #expect(state.isInEffect)
        state.setHold(false, for: "unknown") // releasing an absent hold is a no-op
        #expect(state.isInEffect)
    }

    @Test func hostResumeWinsRegardlessOfHolds() {
        var state = MonitoringPauseState()
        state.setHold(true, for: "settings")
        state.requested = true
        #expect(!state.isInEffect)
        state.requested = false
        state.setHold(false, for: "settings")
        #expect(!state.isInEffect)
    }
}
