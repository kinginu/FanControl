#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
@testable import FanControlKit

/// Test double for `PowerSourceProviding`.
@MainActor
final class MockPowerSource: PowerSourceProviding {
    private(set) var isOnBattery: Bool
    private var onChange: (@MainActor (Bool) -> Void)?

    init(onBattery: Bool) { isOnBattery = onBattery }

    func startObserving(_ onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }

    func simulate(onBattery: Bool) {
        isOnBattery = onBattery
        onChange?(onBattery)
    }
}

/// Power-aware polling (design doc §5.4 (a)) and conflict detection (§5.2) at the manager level.
@MainActor
struct PowerAwarePollingTests {

    private func makeManager(_ power: MockPowerSource, suite: String,
                             running: Set<String> = []) -> FanControlManager {
        FanControlManager(defaults: UserDefaults(suiteName: suite)!, powerSource: power,
                          conflictDetector: ConflictingControllerDetector(isAppRunning: { running.contains($0) },
                                                                          fileExists: { _ in false }))
    }

    @Test func testEffectiveIntervalFollowsPowerSource() {
        let power = MockPowerSource(onBattery: false)
        let manager = makeManager(power, suite: "PowerAwarePollingTests.follow")
        #expect(manager.slowPollingOnBattery)
        #expect(manager.batteryPollingInterval == 10)
        #expect(!manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 2)

        power.simulate(onBattery: true)
        #expect(manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 10)

        manager.slowPollingOnBattery = false
        #expect(manager.effectivePollingInterval == 2)
        manager.slowPollingOnBattery = true
        manager.pollingInterval = 30
        #expect(manager.effectivePollingInterval == 30)
        manager.pollingInterval = 1
        manager.batteryPollingInterval = 20
        #expect(manager.effectivePollingInterval == 20)

        power.simulate(onBattery: false)
        #expect(manager.effectivePollingInterval == 1)
    }

    @Test func testStartsOnBattery() {
        let manager = makeManager(MockPowerSource(onBattery: true), suite: "PowerAwarePollingTests.start")
        #expect(manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 10)
    }

    /// The timer is rescheduled with the effective interval, and the paused
    /// alert-only poll derives from it. Monitoring performs read-only SMC polls.
    @Test func testTimerRescheduledOnPowerChange() {
        let power = MockPowerSource(onBattery: false)
        let manager = makeManager(power, suite: "PowerAwarePollingTests.timer")
        #expect(manager.scheduledTimerInterval == nil)
        manager.startMonitoring()
        defer { manager.stopMonitoring() }
        #expect(manager.scheduledTimerInterval == 2)
        power.simulate(onBattery: true)
        #expect(manager.scheduledTimerInterval == 10)
        manager.setMonitoringPaused(true)   // keepAlertsWhilePaused defaults to true
        #expect(manager.scheduledTimerInterval == 50)
        manager.setMonitoringPaused(false)
        power.simulate(onBattery: false)
        #expect(manager.scheduledTimerInterval == 2)
    }

    @Test func testConflictingControllersRefreshedOnStart() {
        let manager = makeManager(MockPowerSource(onBattery: false), suite: "PowerAwarePollingTests.conflict",
                                  running: ["com.fanfi.fanfi"])
        #expect(manager.conflictingControllers.isEmpty)
        let posted = Mutex<[String]?>(nil)
        let token = NotificationCenter.default.addObserver(forName: .fanControlConflictingControllersChanged,
                                                           object: manager, queue: nil) { note in
            let names = note.userInfo?["names"] as? [String]
            posted.withLock { $0 = names }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        manager.refreshConflictingControllers()
        #expect(manager.conflictingControllers == ["FanFi"])
        #expect(manager.conflictingControllerStatuses.first?.isAppRunning == true)
        #expect(posted.withLock { $0 } == ["FanFi"])
    }
}
#endif
