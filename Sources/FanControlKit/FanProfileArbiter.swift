#if os(macOS)
import Foundation
import Observation
import FanControlCore

// F2: Applies the winner of `ProfileArbitration` (manual > emergency > workload > power >
// default) through `FanControlManager.applyProfile`. Power profiles claim `.power`; per-app /
// workload profiles (F3) claim `.workload`. DynamicNotchApp/docs/power-profiles.md "Precedence".

/// What the arbiter needs from the fan controller (a fake in tests).
@MainActor
public protocol FanProfileHosting: AnyObject {
    /// The active profile (Automatic when nothing is selected).
    var activeFanProfileID: UUID { get }
    /// A stored or built-in profile, `nil` if it no longer exists.
    func fanProfile(id: UUID) -> FanProfile?
    /// Activates the profile (writes immediately). Throws on failure.
    func applyFanProfile(id: UUID) async throws
}

extension FanControlManager: FanProfileHosting {
    public var activeFanProfileID: UUID {
        profileStore.activeProfileID ?? FanProfile.BuiltInID.automatic
    }

    public func fanProfile(id: UUID) -> FanProfile? {
        if let stored = profileStore.profile(id: id) { return stored }
        return id == FanProfile.BuiltInID.automatic ? .automatic() : nil
    }

    /// Like the widget's selection: explicit per-fan modes (`FanProfile.resolved(for:)`).
    public func applyFanProfile(id: UUID) async throws {
        guard let profile = fanProfile(id: id) else {
            throw FanControlError.helperRejected(code: -1, message: "The fan profile no longer exists.")
        }
        try await applyProfile(profile.resolved(for: fans))
    }
}

/// Owns the profile precedence and applies its decision.
///
/// - Automatic features call `setClaim(_:for:)`; the first claim captures the active
///   profile as the baseline ("default", where automation returns to). The baseline is
///   persisted (`baselineDefaultsKey`), so after a relaunch automation still returns to the
///   user's own profile and not to one a rule had applied (the profile store persists the
///   active profile whoever chose it).
/// - A profile change the arbiter did not make (the user picked one in the widget, menu or
///   settings) is a manual selection: it wins until the automatic winner changes to another
///   profile, or `resumeAutomation()` (`ProfileArbitration`). This also holds for a pick made
///   **while an automatic apply is in flight**: it is classified at once, and if the apply
///   then overwrote it (or its rollback undid it), the pick is re-applied right after.
/// - Applies only when the decision differs from the active profile; a failed decision is not
///   retried until the decision changes or `retry()`.
/// - While `isApplyAllowed` refuses, decisions are tracked only; they are applied once it
///   allows again (`applyAllowedDidChange()`, or the next `setClaim`, even an unchanged one).
/// - `setClaim`, `resumeAutomation` and `retry` return only after the pass that applies
///   their decision has finished (a call arriving during an apply waits for the follow-up
///   pass), so `lastError` / `failedDecision` afterwards describe that decision.
///
/// Telling automatic switches from manual ones (for other observers of `activeFanProfileID`,
/// e.g. F3's workload coordinator): the arbiter is the single classifier. Either
/// - subscribe to `manualSelectionNotification` (posted when the arbiter classified a change
///   as the user's pick), or
/// - ignore a change while `isApplying` is `true` or when the new id equals
///   `lastAutomaticApplyID` (set *before* the arbiter calls `applyFanProfile`, so observers
///   that run during the apply already see it; cleared by the next manual pick).
/// `automaticApplyNotification` is posted after each successful automatic switch.
@MainActor
@Observable
public final class FanProfileArbiter {

    public static let shared = FanProfileArbiter(host: FanControlManager.shared, defaults: .standard)

    /// UserDefaults key of the persisted baseline profile id (`shared` only).
    public nonisolated static let baselineDefaultsKey = "fanControl.arbiter.baselineProfileID"
    /// UserDefaults key of the profile the arbiter applied automatically and that is still
    /// active (cleared by a manual pick or a return to the baseline).
    public nonisolated static let automaticActiveDefaultsKey = "fanControl.arbiter.automaticActiveProfileID"

    /// Posted (main thread, `object` = the arbiter) after the arbiter switched the profile.
    /// `userInfo`: `"profileID"` (`UUID`), `"layer"` (`ProfileLayer.rawValue`), `"reason"` (`String`).
    public nonisolated static let automaticApplyNotification = Notification.Name("FanProfileArbiterAutomaticApply")
    /// Posted (main thread, `object` = the arbiter) when a profile change the arbiter did not
    /// make was classified as a manual selection. `userInfo`: `"profileID"` (`UUID`).
    public nonisolated static let manualSelectionNotification = Notification.Name("FanProfileArbiterManualSelection")

    /// The profile the arbiter is applying or applied last; `nil` after a manual pick.
    public private(set) var lastAutomaticApplyID: UUID?

    public private(set) var arbitration = ProfileArbitration() {
        didSet {
            if arbitration.baselineProfileID != oldValue.baselineProfileID { persistBaseline() }
        }
    }
    /// The decision last applied successfully (or found already active).
    public private(set) var appliedDecision: ProfileDecision?
    /// English message of the last failed apply, cleared by the next success.
    public private(set) var lastError: String?
    /// The decision whose apply failed last (`lastError`); not retried until the decision
    /// changes or `retry()`. `nil` once a later pass succeeded or a claim changed.
    public private(set) var failedDecision: ProfileDecision?
    public private(set) var isApplying = false

    /// Extra gate (the app: "Fan Control" enabled). `nil` = always allowed. While it returns
    /// `false`, decisions are tracked but not applied; call `applyAllowedDidChange()` when it
    /// may return `true` again.
    @ObservationIgnored public var isApplyAllowed: (@MainActor () -> Bool)?

    @ObservationIgnored private let host: any FanProfileHosting
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var lastObservedActiveID: UUID
    @ObservationIgnored private var reconcileAgain = false
    /// The running reconcile loop; later callers wait for it (after asking for one more pass).
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// The profile being applied and the one active before (its rollback target): the only
    /// changes during an apply that are the arbiter's own.
    @ObservationIgnored private var applyingProfileID: UUID?
    @ObservationIgnored private var preApplyActiveID: UUID?
    /// A decision was held back by `isApplyAllowed`.
    @ObservationIgnored private var blockedByGate = false
    /// After a relaunch the active profile is one the arbiter had applied: reconcile on the
    /// first `setClaim`, even an unchanged one, so it returns to the baseline if no claim wants it.
    @ObservationIgnored private var needsInitialReconcile = false
    @ObservationIgnored private var isObservingHost = false

    /// `defaults` persists the baseline across launches (`nil`: memory only, as in tests).
    public init(host: any FanProfileHosting, defaults: UserDefaults? = nil) {
        self.host = host
        self.defaults = defaults
        self.lastObservedActiveID = host.activeFanProfileID
        if let defaults {
            if let saved = defaults.string(forKey: Self.baselineDefaultsKey).flatMap(UUID.init(uuidString:)),
               host.fanProfile(id: saved) != nil {
                arbitration = ProfileArbitration(baselineProfileID: saved)
            }
            if let automatic = defaults.string(forKey: Self.automaticActiveDefaultsKey).flatMap(UUID.init(uuidString:)) {
                if automatic == host.activeFanProfileID, arbitration.baselineProfileID != nil {
                    needsInitialReconcile = true
                } else {
                    defaults.removeObject(forKey: Self.automaticActiveDefaultsKey)
                }
            }
        }
    }

    /// manual > emergency > workload > power > default.
    public var decision: ProfileDecision? { arbitration.decision }

    /// Sets (or withdraws with `nil`) one automatic layer's claim and applies the new decision.
    /// `endsManualOverride: false` keeps an active manual pick even if the automatic winner
    /// changes (withdrawing a stale claim while paused by that pick).
    public func setClaim(_ claim: ProfileClaim?, for layer: ProfileLayer, endsManualOverride: Bool = true) async {
        if claim != nil, arbitration.baselineProfileID == nil {
            arbitration.baselineProfileID = host.activeFanProfileID
        }
        guard arbitration.setClaim(claim, for: layer, endsManualOverride: endsManualOverride) else {
            // Unchanged claim: still apply a decision the gate held back, or the relaunch check.
            if needsInitialReconcile || (blockedByGate && (isApplyAllowed?() ?? true)) {
                needsInitialReconcile = false
                await reconcile()
            }
            return
        }
        needsInitialReconcile = false
        failedDecision = nil
        await reconcile()
    }

    /// Ends a manual override and applies the automatic decision.
    public func resumeAutomation() async {
        arbitration.resumeAutomation()
        failedDecision = nil
        await reconcile()
    }

    /// Retries a failed decision.
    public func retry() async {
        failedDecision = nil
        await reconcile()
    }

    /// `isApplyAllowed` may have changed (the app: Fan Control switched on). Applies a
    /// decision it held back. Cheap when nothing is pending.
    public func applyAllowedDidChange() async {
        guard blockedByGate, isApplyAllowed?() ?? true else { return }
        await reconcile()
    }

    /// The host's active profile may have changed (observation, or called directly). A change
    /// the arbiter did not make is a manual selection.
    public func activeProfileDidChange() {
        let current = host.activeFanProfileID
        guard current != lastObservedActiveID else { return }
        lastObservedActiveID = current
        // Our own apply (or its rollback) is not a manual pick; anything else is, even mid-apply.
        if isApplying, current == applyingProfileID || current == preApplyActiveID { return }
        lastAutomaticApplyID = nil
        setAutomaticActive(nil)
        arbitration.noteManualSelection(current)
        NotificationCenter.default.post(name: Self.manualSelectionNotification, object: self,
                                        userInfo: ["profileID": current])
        if let decision = arbitration.decision, decision.profileID == current { appliedDecision = decision }
    }

    /// Observes `activeFanProfileID` (an `@Observable` host such as `FanControlManager`) and
    /// calls `activeProfileDidChange()` on every change. Idempotent.
    public func startObservingHost() {
        guard !isObservingHost else { return }
        isObservingHost = true
        lastObservedActiveID = host.activeFanProfileID
        observeHost()
    }

    private func observeHost() {
        withObservationTracking {
            _ = host.activeFanProfileID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeProfileDidChange()
                self.observeHost()
            }
        }
    }

    /// Applies `decision` if it differs from the active profile. Serialized: a request
    /// arriving during a pass asks for one more pass and waits until the loop is done.
    func reconcile() async {
        if let running = reconcileTask {
            reconcileAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileLoop()
            // Same actor turn as the loop's last `reconcileAgain` check: no request is lost.
            self.reconcileTask = nil
        }
        reconcileTask = task
        await task.value
    }

    private func reconcileLoop() async {
        repeat {
            reconcileAgain = false
            guard let decision = arbitration.decision else { return }
            if host.activeFanProfileID == decision.profileID {
                appliedDecision = decision
                lastError = nil
                failedDecision = nil
                blockedByGate = false
                if decision.layer == .baseline { setAutomaticActive(nil) }
                continue
            }
            guard decision != failedDecision else { return }
            guard isApplyAllowed?() ?? true else {
                blockedByGate = true
                return
            }
            blockedByGate = false
            let isAutomatic = decision.layer != .manual
            preApplyActiveID = host.activeFanProfileID
            applyingProfileID = decision.profileID
            isApplying = true
            if isAutomatic { lastAutomaticApplyID = decision.profileID }
            do {
                try await host.applyFanProfile(id: decision.profileID)
                appliedDecision = decision
                lastError = nil
                failedDecision = nil
                if isAutomatic, host.activeFanProfileID == decision.profileID {
                    setAutomaticActive(decision.layer == .baseline ? nil : decision.profileID)
                    NotificationCenter.default.post(name: Self.automaticApplyNotification, object: self, userInfo: [
                        "profileID": decision.profileID, "layer": decision.layer.rawValue, "reason": decision.reason,
                    ])
                }
                kitLog.notice("Fan profile switched by \(decision.layer.displayName, privacy: .public): \(decision.reason, privacy: .public)")
            } catch {
                failedDecision = decision
                lastError = error.localizedDescription
                kitLog.error("Fan profile switch (\(decision.layer.displayName, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
            isApplying = false
            let now = host.activeFanProfileID
            if now == decision.profileID || now == preApplyActiveID {
                lastObservedActiveID = now
            } else {
                activeProfileDidChange()  // someone else's pick landed during the apply
            }
            applyingProfileID = nil
            preApplyActiveID = nil
            // A manual pick during the apply changed the decision: apply it (it may have been
            // overwritten by our select, or undone by the rollback).
            if arbitration.decision != decision { reconcileAgain = true }
        } while reconcileAgain
    }

    // MARK: Persistence

    private func persistBaseline() {
        guard let defaults else { return }
        if let id = arbitration.baselineProfileID {
            defaults.set(id.uuidString, forKey: Self.baselineDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.baselineDefaultsKey)
        }
    }

    private func setAutomaticActive(_ id: UUID?) {
        guard let defaults else { return }
        if let id {
            defaults.set(id.uuidString, forKey: Self.automaticActiveDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.automaticActiveDefaultsKey)
        }
    }
}
#endif
