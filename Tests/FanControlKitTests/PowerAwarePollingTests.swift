#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
@testable import FanControlKit

/// Power-aware polling (design doc §5.4 (a)) and conflict detection (§5.2) at the
/// manager level. The timer itself is covered by `MonitoringServiceTests` (starting
/// monitoring on a manager would open the IOKit SMC reader).
@Suite("Power-aware polling (manager)", .tags(.power, .manager))
@MainActor
struct PowerAwarePollingTests {

    @Test func effectiveIntervalFollowsPowerSource() {
        let defaults = ScratchDefaults()
        let power = MockPowerSource(onBattery: false)
        let manager = Isolated.manager(defaults: defaults, power: power)
        #expect(manager.slowPollingOnBattery)
        #expect(manager.batteryPollingInterval == 10)
        #expect(!manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 2)

        power.simulate(onBattery: true)
        #expect(manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 10)

        manager.slowPollingOnBattery = false
        #expect(manager.effectivePollingInterval == 2, "slow polling off: AC interval on battery")
        manager.slowPollingOnBattery = true
        manager.pollingInterval = 30
        #expect(manager.effectivePollingInterval == 30, "a longer user interval wins on battery")
        manager.pollingInterval = 1
        manager.batteryPollingInterval = 20
        #expect(manager.effectivePollingInterval == 20)

        power.simulate(onBattery: false)
        #expect(manager.effectivePollingInterval == 1)
    }

    @Test func startsOnBattery() {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults, power: MockPowerSource(onBattery: true))
        #expect(manager.isOnBattery)
        #expect(manager.effectivePollingInterval == 10)
        #expect(manager.scheduledTimerInterval == nil, "no timer before startMonitoring()")
    }

    @Test func conflictingControllersRefreshedOnRequest() {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults, running: ["com.fanfi.fanfi"])
        #expect(manager.conflictingControllers.isEmpty, "nothing is detected before the first refresh")
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
        #expect(posted.withLock { $0 } == ["FanFi"], "the change is posted synchronously")
    }
}
#endif
