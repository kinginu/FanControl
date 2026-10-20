#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
@testable import FanControlKit

/// The Swift 6 thread model (docs/kit.md "Threading model"): `FanControlPoller` runs on
/// its dispatch-queue executor, `ResumeOnce` resumes at most once, and the
/// `@MainActor` manager's pause / profile bookkeeping needs no SMC.
@Suite("Concurrency model", .tags(.concurrency, .manager))
struct ConcurrencyModelTests {
    /// `enqueue` (`queue.async` + `assumeIsolated`) and `await run` share one FIFO queue.
    @Test func pollerEnqueueAndRunAreFIFO() async {
        let poller = Isolated.poller(label: "ConcurrencyModelTests.poll")
        for generation in 1...5 {
            poller.enqueue { poller in
                poller.monitoringActive = generation.isMultiple(of: 2)
                _ = poller.applyGate.advance()
            }
        }
        let (active, current) = await poller.run { ($0.monitoringActive, $0.applyGate.current) }
        #expect(active == false, "the last of 5 jobs (odd) set monitoringActive = false")
        #expect(current == 5, "every enqueued job ran before run")
    }

    /// The poller's isolated code really runs on its queue.
    @Test func pollerRunsOnItsQueue() async {
        let poller = Isolated.poller(label: "ConcurrencyModelTests.queue")
        let label = await poller.run { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == "ConcurrencyModelTests.queue")
    }

    @Test func resumeOnceResumesOnlyOnce() async throws {
        let handlerRuns = Counter()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            box.onResume { handlerRuns.increment() }
            #expect(box.resume(returning: 1))
            #expect(!box.resume(returning: 2))
            #expect(!box.resume(throwing: CancellationError()))
            // Registered after the resume: runs immediately.
            box.onResume { handlerRuns.increment() }
        }
        #expect(value == 1)
        #expect(handlerRuns.value == 2)
    }

    @Test @MainActor func managerPauseAndHoldWithoutMonitoring() {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults)
        manager.setMonitoringPaused(true)
        #expect(manager.isMonitoringPaused)
        #expect(manager.isPauseInEffect)
        manager.setLiveDataHold(true, for: "settings")
        #expect(manager.isMonitoringPaused)
        #expect(!manager.isPauseInEffect)
        manager.setLiveDataHold(false, for: "settings")
        #expect(manager.isPauseInEffect)
        manager.setMonitoringPaused(false)
        #expect(!manager.isPauseInEffect)
        #expect(!manager.isMonitoring)
    }

    @Test @MainActor func managerSaveAndDeleteProfilePersist() throws {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults)
        let profile = FanProfile(id: UUID(), name: "Test", modes: [0: .constant(rpm: 3000)], isBuiltIn: false)
        manager.saveProfile(profile)
        #expect(manager.profileStore.profiles.contains { $0.id == profile.id })
        let data = try #require(defaults.defaults.data(forKey: FanControlManager.profileStoreDefaultsKey),
                                "saveProfile persists the store")
        #expect(try ProfileStore.decodeJSON(data).profiles.contains { $0.id == profile.id })
        manager.deleteProfile(profile)
        #expect(!manager.profileStore.profiles.contains { $0.id == profile.id })
    }

    /// The constants stay usable from nonisolated code.
    @Test func nonisolatedConstants() {
        #expect(FanControlManager.writeThresholdRPM == 25)
        #expect(FanControlManager.wakeReapplyDelays == [0, 2, 5])
        #expect(!FanControlManager.helperApprovalInstructions.contains("macOS 14"))
    }
}

private final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}
#endif
