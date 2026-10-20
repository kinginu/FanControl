import Foundation
import Testing
@testable import FanControlCore

struct PollingIntervalPolicyTests {

    @Test func testACUsesPollingInterval() {
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 2, batteryInterval: 10,
                                                        slowOnBattery: true, onBattery: false) == 2)
    }

    @Test func testBatterySlowsDown() {
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 2, batteryInterval: 10,
                                                        slowOnBattery: true, onBattery: true) == 10)
    }

    @Test func testBatteryWithSlowPollingOffKeepsInterval() {
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 2, batteryInterval: 10,
                                                        slowOnBattery: false, onBattery: true) == 2)
    }

    /// A user interval longer than the battery interval is never shortened.
    @Test func testLongerUserIntervalWinsOnBattery() {
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 30, batteryInterval: 10,
                                                        slowOnBattery: true, onBattery: true) == 30)
    }

    @Test func testClampedToAllowedRange() {
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 0.1, batteryInterval: 10,
                                                        slowOnBattery: true, onBattery: false) == 0.5)
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: 2, batteryInterval: 1000,
                                                        slowOnBattery: true, onBattery: true) == 300)
        #expect(PollingIntervalPolicy.effectiveInterval(pollingInterval: .nan, batteryInterval: .nan,
                                                        slowOnBattery: true, onBattery: true) == 2)
    }

    @Test func testPausedIntervalUsesEffectiveInterval() {
        #expect(PollingIntervalPolicy.pausedInterval(effective: 1) == 10)
        #expect(PollingIntervalPolicy.pausedInterval(effective: 2) == 10)
        // On battery (effective 10 s) the alert-only poll slows to 50 s.
        #expect(PollingIntervalPolicy.pausedInterval(effective: 10) == 50)
    }
}
