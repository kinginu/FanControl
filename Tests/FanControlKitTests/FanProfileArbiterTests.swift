#if os(macOS)
import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

// F2: `FanProfileArbiter` against a fake fan host whose apply can be held mid-flight
// (the gate, manual picks during an apply, the persisted baseline). No SMC, no helper.

private typealias ID = FanProfile.BuiltInID

private struct ApplyFailure: LocalizedError {
    var errorDescription: String? { "apply failed" }
}

/// Like `FanController.apply`: awaits the session (held while `isHeld`), then selects the
/// profile; on failure rolls the selection back.
@MainActor
private final class HeldFanHost: FanProfileHosting {
    var active: UUID = ID.automatic
    private(set) var applied: [UUID] = []
    var failing: Set<UUID> = []
    /// Hold the next applies before (`.beforeSelect`) or after (`.afterSelect`) selecting.
    enum Hold { case none, beforeSelect, afterSelect }
    var hold = Hold.none
    private var waiter: CheckedContinuation<Void, Never>?
    private let store = ProfileStore()
    weak var arbiter: FanProfileArbiter?

    var isWaiting: Bool { waiter != nil }
    var activeFanProfileID: UUID { active }
    func fanProfile(id: UUID) -> FanProfile? { store.profile(id: id) }

    func release() {
        hold = .none
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume()
    }

    private func wait() async { await withCheckedContinuation { waiter = $0 } }

    func applyFanProfile(id: UUID) async throws {
        applied.append(id)
        let previous = active
        if hold == .beforeSelect { await wait() }
        select(id)
        if hold == .afterSelect { await wait() }
        if failing.contains(id) {
            select(previous)
            throw ApplyFailure()
        }
    }

    /// Selects and notifies the arbiter, as the observation of `activeFanProfileID` does.
    func select(_ id: UUID) {
        active = id
        arbiter?.activeProfileDidChange()
    }

    /// The user picks a profile in the widget (the manager selects it).
    func userSelects(_ id: UUID) { select(id) }
}

@MainActor
private func makeArbiter(_ host: HeldFanHost, defaults: UserDefaults? = nil) -> FanProfileArbiter {
    let arbiter = FanProfileArbiter(host: host, defaults: defaults)
    host.arbiter = arbiter
    return arbiter
}

@MainActor
private func waitUntilHeld(_ host: HeldFanHost) async {
    for _ in 0..<500 where !host.isWaiting { await Task.yield() }
    #expect(host.isWaiting)
}

/// The "Fan Control enabled" switch.
@MainActor
private final class Gate {
    var allowed = false
}

private let boost = ProfileClaim(profileID: ID.boost, reason: "Xcode")
private let quietOnBattery = ProfileClaim(profileID: ID.constantQuiet, reason: "On Battery")

@MainActor
@Suite("Fan profile arbiter (F2)", .serialized)
struct FanProfileArbiterTests {

    // MARK: Gate (isApplyAllowed)

    @Test func decisionBlockedByTheGateIsAppliedWhenItAllowsAgain() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        let gate = Gate()
        arbiter.isApplyAllowed = { gate.allowed }
        await arbiter.setClaim(quietOnBattery, for: .power)
        #expect(host.applied.isEmpty)
        await arbiter.applyAllowedDidChange()
        #expect(host.applied.isEmpty)   // still refused
        gate.allowed = true
        await arbiter.applyAllowedDidChange()
        #expect(host.active == ID.constantQuiet)
        #expect(arbiter.appliedDecision?.layer == .power)
    }

    @Test func unchangedClaimAppliesAHeldBackDecisionOnceAllowed() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        let gate = Gate()
        arbiter.isApplyAllowed = { gate.allowed }
        await arbiter.setClaim(quietOnBattery, for: .power)
        gate.allowed = true
        await arbiter.setClaim(quietOnBattery, for: .power)   // the power engine's next tick
        #expect(host.applied == [ID.constantQuiet])
        await arbiter.setClaim(quietOnBattery, for: .power)
        #expect(host.applied == [ID.constantQuiet])           // nothing pending any more
    }

    // MARK: Manual picks during an apply

    @Test func pickDuringTheSessionAwaitWinsAndIsReapplied() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        var manual: [UUID] = []
        let observer = NotificationCenter.default.addObserver(
            forName: FanProfileArbiter.manualSelectionNotification, object: arbiter, queue: nil
        ) { note in
            if let id = note.userInfo?["profileID"] as? UUID { MainActor.assumeIsolated { manual.append(id) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        host.hold = .beforeSelect
        let apply = Task { @MainActor in await arbiter.setClaim(boost, for: .workload) }
        await waitUntilHeld(host)
        host.userSelects(ID.constantQuiet)
        #expect(manual == [ID.constantQuiet])
        #expect(arbiter.arbitration.isManualOverrideActive)
        host.release()   // the arbiter's late select(Boost) overwrites Quiet …
        await apply.value
        #expect(host.active == ID.constantQuiet)   // … and the manual pick is put back
        #expect(arbiter.decision?.layer == .manual)
        #expect(arbiter.appliedDecision?.layer == .manual)
        #expect(manual == [ID.constantQuiet])      // the arbiter's own selects are not manual
    }

    @Test func pickAfterTheSelectIsClassifiedAndKept() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        host.hold = .afterSelect
        let apply = Task { @MainActor in await arbiter.setClaim(boost, for: .workload) }
        await waitUntilHeld(host)
        host.userSelects(ID.constantQuiet)
        host.release()
        await apply.value
        #expect(host.active == ID.constantQuiet)
        #expect(arbiter.decision?.layer == .manual)
        #expect(arbiter.lastAutomaticApplyID == nil)
        // A later unrelated claim change does not re-apply automation over the pick.
        await arbiter.setClaim(boost, for: .workload)
        #expect(host.active == ID.constantQuiet)
    }

    @Test func rollbackOfAFailedApplyDoesNotUndoAPick() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        host.failing = [ID.boost]
        host.hold = .afterSelect
        let apply = Task { @MainActor in await arbiter.setClaim(boost, for: .workload) }
        await waitUntilHeld(host)
        host.userSelects(ID.constantQuiet)
        host.release()   // fails and rolls back to Automatic
        await apply.value
        #expect(host.active == ID.constantQuiet)
        #expect(arbiter.decision?.layer == .manual)
    }

    @Test func ownApplyAndRollbackAreNotManual() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        host.failing = [ID.boost]
        await arbiter.setClaim(boost, for: .workload)
        #expect(host.active == ID.automatic)   // rolled back
        #expect(!arbiter.arbitration.isManualOverrideActive)
        #expect(arbiter.lastError == "apply failed")
        #expect(arbiter.failedDecision?.profileID == ID.boost)
    }

    @Test func callDuringAnApplyReturnsAfterItsPass() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        host.hold = .beforeSelect
        let first = Task { @MainActor in await arbiter.setClaim(quietOnBattery, for: .power) }
        await waitUntilHeld(host)
        host.failing = [ID.boost]
        let second = Task { @MainActor in await arbiter.setClaim(boost, for: .workload) }
        for _ in 0..<50 { await Task.yield() }
        host.release()
        await second.value
        // The coalesced Boost pass has run (and failed) by the time the second call returns.
        #expect(host.applied == [ID.constantQuiet, ID.boost])
        #expect(arbiter.failedDecision?.layer == .workload)
        #expect(arbiter.lastError == "apply failed")
        await first.value
    }

    // MARK: Baseline across a relaunch

    @Test func baselineSurvivesARelaunch() async {
        let defaults = UserDefaults(suiteName: "FanProfileArbiterTests.baseline")!
        defaults.removePersistentDomain(forName: "FanProfileArbiterTests.baseline")
        defer { defaults.removePersistentDomain(forName: "FanProfileArbiterTests.baseline") }
        do {
            let host = HeldFanHost()
            host.active = ID.constantQuiet   // the user's profile
            let arbiter = makeArbiter(host, defaults: defaults)
            await arbiter.setClaim(ProfileClaim(profileID: ID.automatic, reason: "On Battery"), for: .power)
            #expect(host.active == ID.automatic)
        }
        // Relaunch: the store persisted Automatic (the rule's profile) as active.
        let host = HeldFanHost()
        host.active = ID.automatic
        let arbiter = makeArbiter(host, defaults: defaults)
        #expect(arbiter.arbitration.baselineProfileID == ID.constantQuiet)
        await arbiter.setClaim(ProfileClaim(profileID: ID.automatic, reason: "On Battery"), for: .power)
        await arbiter.setClaim(nil, for: .power)   // plugged in
        #expect(host.active == ID.constantQuiet)
    }

    @Test func automationProfileLeftActiveIsUndoneAfterARelaunchWithoutAClaim() async {
        let suite = "FanProfileArbiterTests.relaunchNoClaim"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let host = HeldFanHost()
            host.active = ID.constantQuiet
            let arbiter = makeArbiter(host, defaults: defaults)
            await arbiter.setClaim(boost, for: .workload)
            #expect(host.active == ID.boost)
        }
        let host = HeldFanHost()
        host.active = ID.boost
        let arbiter = makeArbiter(host, defaults: defaults)
        await arbiter.setClaim(nil, for: .power)   // first evaluation: no rule matches
        #expect(host.active == ID.constantQuiet)
        #expect(defaults.string(forKey: FanProfileArbiter.automaticActiveDefaultsKey) == nil)
    }

    @Test func manualPickAfterARelaunchIsNotUndone() async {
        let suite = "FanProfileArbiterTests.relaunchManual"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let host = HeldFanHost()
            host.active = ID.constantQuiet
            let arbiter = makeArbiter(host, defaults: defaults)
            await arbiter.setClaim(boost, for: .workload)
            host.userSelects(ID.max)   // manual pick: no longer the automation's profile
            #expect(arbiter.arbitration.baselineProfileID == ID.max)
        }
        let host = HeldFanHost()
        host.active = ID.max
        let arbiter = makeArbiter(host, defaults: defaults)
        await arbiter.setClaim(nil, for: .power)
        #expect(host.active == ID.max)
        #expect(host.applied.isEmpty)
    }

    // MARK: Withdrawing a claim without ending the manual override

    @Test func withdrawingWhilePausedKeepsTheManualPick() async {
        let host = HeldFanHost()
        let arbiter = makeArbiter(host)
        await arbiter.setClaim(quietOnBattery, for: .power)
        await arbiter.setClaim(boost, for: .workload)
        host.userSelects(ID.max)
        await arbiter.setClaim(nil, for: .workload, endsManualOverride: false)
        #expect(host.active == ID.max)
        #expect(arbiter.arbitration.isManualOverrideActive)
        await arbiter.resumeAutomation()   // Power status line "Resume": the power rule, not Boost
        #expect(host.active == ID.constantQuiet)
    }
}
#endif
