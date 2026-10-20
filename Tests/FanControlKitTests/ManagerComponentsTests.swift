#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
@testable import FanControlKit

/// The components behind the `FanControlManager` facade (docs/kit.md "Architecture"),
/// exercised on their own without SMC or helper I/O.
@MainActor
struct MonitoringServiceTests {

    private func makeService(onBattery: Bool = false) -> (MonitoringService, MockPowerSource) {
        let power = MockPowerSource(onBattery: onBattery)
        let poller = FanControlPoller(helperClient: HelperClient(), label: "MonitoringServiceTests.poll")
        return (MonitoringService(poller: poller, powerSource: power), power)
    }

    @Test func testStartStopAndTimerInterval() {
        let (service, power) = makeService()
        #expect(service.markStarted())
        #expect(!service.markStarted())
        service.scheduleTimer()
        #expect(service.scheduledTimerInterval == 2)
        power.simulate(onBattery: true)
        #expect(service.effectivePollingInterval == 10)
        #expect(service.scheduledTimerInterval == 10)
        #expect(service.stop())
        #expect(!service.stop())
        #expect(!service.isMonitoring)
    }

    /// Polls go through the hooks, and only while monitoring.
    @Test func testPollHooksOnlyWhileMonitoring() {
        let (service, _) = makeService()
        var before = 0, polls = 0
        service.beforePoll = { before += 1 }
        service.poll = { polls += 1 }
        service.pollIfMonitoring()
        #expect(polls == 0)
        _ = service.markStarted()
        service.pollIfMonitoring()
        #expect(before == 1 && polls == 1)
        // Ending the pause polls at once.
        service.setPaused(true)
        service.setPaused(false)
        #expect(polls == 2)
        _ = service.stop()
    }

    /// While paused, the slow poll runs only with a session or with alerts kept.
    @Test func testPausedTimerNeedsSessionOrAlerts() {
        let (service, _) = makeService()
        var sessionOpen = false
        service.isSessionOpen = { sessionOpen }
        service.poll = {}
        _ = service.markStarted()
        service.scheduleTimer()
        service.keepAlertsWhilePaused = false
        service.setPaused(true)
        #expect(service.isPauseInEffect)
        #expect(service.scheduledTimerInterval == nil)
        sessionOpen = true
        service.sessionStateDidChange()
        #expect(service.scheduledTimerInterval == 10)
        service.setLiveDataHold(true, for: "test")
        #expect(!service.isPauseInEffect)
        #expect(service.scheduledTimerInterval == 2)
        service.setLiveDataHold(false, for: "test")
        _ = service.stop()
    }
}

/// Records what `WakeCoordinator` asks of its host.
@MainActor
private final class FakeWakeHost: WakeCoordinatorHost {
    var isSessionOpen = true
    var polls = 0
    var sleeping: [Bool] = []
    var closes = 0
    var reapplies: [Bool] = []

    func pollIfMonitoring() { polls += 1 }
    func setSystemSleeping(_ sleeping: Bool) { self.sleeping.append(sleeping) }
    func closeSessionAfterWake() { closes += 1 }
    func reapplyActiveProfileAfterWake(recordingErrors: Bool) { reapplies.append(recordingErrors) }
}

@MainActor
struct WakeCoordinatorTests {

    /// Runs every scheduled attempt immediately, recording its delay.
    private func makeCoordinator(_ host: FakeWakeHost) -> (WakeCoordinator, () -> [TimeInterval]) {
        var delays: [TimeInterval] = []
        let coordinator = WakeCoordinator { delay, item in
            delays.append(delay)
            item.perform()
        }
        coordinator.host = host
        return (coordinator, { delays })
    }

    @Test func testWakeReappliesAtEveryDelayRecordingOnlyTheLast() {
        let host = FakeWakeHost()
        let (coordinator, delays) = makeCoordinator(host)
        coordinator.handleWake()
        #expect(host.sleeping == [false])
        #expect(delays() == [0, 2, 5])
        #expect(host.reapplies == [false, false, true])
        // One immediate poll, then one per delayed attempt.
        #expect(host.polls == 3)
        #expect(host.closes == 0)
    }

    @Test func testWakeClosesSessionWhenReapplyIsOff() {
        let host = FakeWakeHost()
        let (coordinator, delays) = makeCoordinator(host)
        coordinator.reapplyProfileAfterWake = false
        coordinator.handleWake()
        #expect(host.closes == 1)
        #expect(host.reapplies.isEmpty)
        #expect(delays().isEmpty)
    }

    @Test func testWakeWithoutSessionOnlyPolls() {
        let host = FakeWakeHost()
        host.isSessionOpen = false
        let (coordinator, delays) = makeCoordinator(host)
        coordinator.handleWake()
        #expect(host.polls == 1)
        #expect(delays().isEmpty)
        #expect(host.reapplies.isEmpty && host.closes == 0)
    }

    /// Sleep cancels attempts that have not run yet.
    @Test func testSleepCancelsPendingAttempts() {
        let host = FakeWakeHost()
        let coordinator = WakeCoordinator { _, _ in }   // never runs the attempts
        coordinator.host = host
        coordinator.handleWake()
        #expect(coordinator.pendingAttemptCount == 3)
        coordinator.handleWillSleep()
        #expect(coordinator.pendingAttemptCount == 0)
        #expect(host.sleeping == [false, true])
        #expect(host.reapplies.isEmpty)
    }
}

struct ProfileSelectionRollbackTests {

    @Test func testNewUserProfileIsRemovedOnUndo() {
        var store = ProfileStore()
        let previous = store
        let profile = FanProfile(id: UUID(), name: "New", modes: [0: .constant(rpm: 3000)], isBuiltIn: false)
        let rollback = ProfileSelectionRollback.select(profile, in: &store)
        #expect(store.activeProfileID == profile.id)
        #expect(store.profiles.contains { $0.id == profile.id })
        rollback.undo(in: &store)
        #expect(store == previous)
    }

    @Test func testExistingUserProfileIsRestoredOnUndo() {
        let id = UUID()
        let original = FanProfile(id: id, name: "Mine", modes: [0: .constant(rpm: 3000)], isBuiltIn: false)
        var store = ProfileStore()
        store.upsert(original)
        store.activeProfileID = FanProfile.BuiltInID.automatic
        let previous = store
        var edited = original
        edited.modes[0] = .constant(rpm: 4000)
        let rollback = ProfileSelectionRollback.select(edited, in: &store)
        #expect(store.profiles.first { $0.id == id }?.modes[0] == .constant(rpm: 4000))
        rollback.undo(in: &store)
        #expect(store == previous)
    }

    @Test func testBuiltInIsOnlySelected() {
        var store = ProfileStore()
        let count = store.profiles.count
        let rollback = ProfileSelectionRollback.select(.automatic(), in: &store)
        #expect(store.profiles.count == count)
        #expect(store.activeProfileID == FanProfile.BuiltInID.automatic)
        rollback.undo(in: &store)
        #expect(store.activeProfileID == nil)
    }
}

/// `FanControllerHost` without SMC or helper.
@MainActor
private final class FakeControllerHost: FanControllerHost {
    var profileStore = ProfileStore()
    var resolvedActiveProfile: FanProfile = .automatic()
    var safetyPolicy: SafetyPolicy = FanControlPlatform.defaultSafetyPolicy
    var tuning: FanControlTuning = .default
    var fans: [FanDevice] = []
    var isMonitoring = false
    var monitoringStarts = 0
    var applied = 0

    func startMonitoring() { monitoringStarts += 1 }
    func registerSystemObserversIfNeeded() {}
    func fanControllerDidApply(modes: [Int: FanControlMode], emergencyOverride: Bool) { applied += 1 }
}

@MainActor
struct FanControllerTests {

    private func makeController(_ host: FakeControllerHost) -> FanController {
        let client = HelperClient()
        let helper = HelperCoordinator(client: client, installer: HelperInstaller(),
                                   conflictDetector: ConflictingControllerDetector(isAppRunning: { _ in false },
                                                                                   fileExists: { _ in false }))
        let controller = FanController(poller: FanControlPoller(helperClient: client,
                                                                label: "FanControllerTests.poll"),
                                       helper: helper)
        controller.host = host
        return controller
    }

    /// An automatic profile needs no session: it is selected, nothing is written.
    @Test func testAutomaticApplyWithoutSessionOnlySelects() async throws {
        let host = FakeControllerHost()
        let controller = makeController(host)
        try await controller.apply(.automatic(), force: true, allowOpeningSession: true, makeActive: true)
        #expect(host.profileStore.activeProfileID == FanProfile.BuiltInID.automatic)
        #expect(host.applied == 0)
        #expect(host.monitoringStarts == 0)
    }

    /// A wake re-apply (`allowOpeningSession: false`) without a session changes nothing.
    @Test func testReapplyWithoutSessionIsANoOp() async throws {
        let host = FakeControllerHost()
        let controller = makeController(host)
        let manual = FanProfile(id: UUID(), name: "Manual", modes: [0: .constant(rpm: 3000)], isBuiltIn: false)
        try await controller.apply(manual, force: true, allowOpeningSession: false, makeActive: true)
        #expect(host.profileStore.activeProfileID == nil)
        #expect(host.monitoringStarts == 0)
    }

    /// "Every fan" presets keep their manual mode in `defaultMode` with empty
    /// `modes`; applied unresolved or resolved before the fans are known
    /// (`resolved(for: [])`), they must still open the session (review fix:
    /// deciding from `modes` alone selected the preset and wrote nothing).
    @Test func testDefaultModePresetsRequireSession() {
        #expect(!FanController.requiresSession(.automatic()))
        let presets: [FanProfile] = [.constantQuiet(), .constantHigh(), .boost(), .max(),
                                     .defaultCustom1(), .defaultCustom2()]
        for preset in presets {
            #expect(preset.modes.isEmpty)
            #expect(FanController.requiresSession(preset), "\(preset.name)")
            #expect(FanController.requiresSession(preset.resolved(for: [])), "\(preset.name)")
        }
        let explicit = FanProfile(id: UUID(), name: "Manual", modes: [1: .constant(rpm: 3000)], isBuiltIn: false)
        #expect(FanController.requiresSession(explicit))
        let allAutomatic = FanProfile(id: UUID(), name: "Auto", modes: [0: .automatic], isBuiltIn: false,
                                      defaultMode: .automatic)
        #expect(!FanController.requiresSession(allAutomatic))
    }
}

/// `FanControlPoller.closeReaderIfIdle`: the reader a user action opened while
/// monitoring was off is closed again unless monitoring or a session needs it
/// (review fix: it stayed open for the life of the process). `strategy` stands in
/// for the reader (no SMC in tests): `closeReader()` clears both.
struct PollerIdleReaderTests {

    private func pollerWithStrategy(monitoring: Bool) async -> FanControlPoller {
        let poller = FanControlPoller(helperClient: HelperClient(), label: "PollerIdleReaderTests.poll")
        await poller.run { poller in
            poller.monitoringActive = monitoring
            poller.strategy = FanWriteStrategy(reader: MockSMCReader([]), fanIndices: [0])
        }
        return poller
    }

    @Test func testClosesWhenIdle() async {
        let poller = await pollerWithStrategy(monitoring: false)
        await poller.run { $0.closeReaderIfIdle(sessionOpen: false) }
        #expect(await poller.run { $0.strategy == nil && $0.reader == nil })
    }

    @Test func testKeepsWhileMonitoringOrSessionOpen() async {
        let monitoring = await pollerWithStrategy(monitoring: true)
        await monitoring.run { $0.closeReaderIfIdle(sessionOpen: false) }
        #expect(await monitoring.run { $0.strategy != nil })
        let session = await pollerWithStrategy(monitoring: false)
        await session.run { $0.closeReaderIfIdle(sessionOpen: true) }
        #expect(await session.run { $0.strategy != nil })
    }
}

@MainActor
struct HelperCoordinatorTests {

    @Test func testConflictCheckIsThrottled() {
        let running = Mutex<Set<String>>([])
        let detector = ConflictingControllerDetector(isAppRunning: { id in running.withLock { $0.contains(id) } },
                                                     fileExists: { _ in false })
        let service = HelperCoordinator(client: HelperClient(), installer: HelperInstaller(), conflictDetector: detector)
        var changes: [[String]] = []
        service.onConflictingControllersChange = { changes.append($0) }
        let start = Date()
        #expect(service.isConflictCheckDue(now: start))
        service.refreshConflictingControllersIfDue(now: start)
        #expect(!service.isConflictCheckDue(now: start.addingTimeInterval(59)))
        running.withLock { $0 = ["com.fanfi.fanfi"] }
        service.refreshConflictingControllersIfDue(now: start.addingTimeInterval(59))
        #expect(service.conflictingControllers.isEmpty)
        service.refreshConflictingControllersIfDue(now: start.addingTimeInterval(HelperCoordinator.conflictCheckInterval))
        #expect(service.conflictingControllers == ["FanFi"])
        #expect(changes == [["FanFi"]])
    }

    /// `installHelper()`'s status → error mapping (`.requiresApproval` is left out:
    /// it opens System Settings).
    @Test func testRequireUsable() {
        #expect(throws: Never.self) { try HelperCoordinator.requireUsable(.enabled) }
        #expect(throws: FanControlError.helperNotInstalled) { try HelperCoordinator.requireUsable(.notRegistered) }
        #expect(throws: (any Error).self) { try HelperCoordinator.requireUsable(.notFound) }
    }
}
#endif
