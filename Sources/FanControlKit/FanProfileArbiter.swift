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
///   profile as the baseline ("default", where automation returns to).
/// - A profile change the arbiter did not make (the user picked one in the widget, menu or
///   settings) is a manual selection: it wins until the automatic winner changes to another
///   profile, or `resumeAutomation()` (`ProfileArbitration`).
/// - Applies only when the decision differs from the active profile; a failed decision is not
///   retried until the decision changes or `retry()`.
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

    public static let shared = FanProfileArbiter(host: FanControlManager.shared)

    /// Posted (main thread, `object` = the arbiter) after the arbiter switched the profile.
    /// `userInfo`: `"profileID"` (`UUID`), `"layer"` (`ProfileLayer.rawValue`), `"reason"` (`String`).
    public nonisolated static let automaticApplyNotification = Notification.Name("FanProfileArbiterAutomaticApply")
    /// Posted (main thread, `object` = the arbiter) when a profile change the arbiter did not
    /// make was classified as a manual selection. `userInfo`: `"profileID"` (`UUID`).
    public nonisolated static let manualSelectionNotification = Notification.Name("FanProfileArbiterManualSelection")

    /// The profile the arbiter is applying or applied last; `nil` after a manual pick.
    public private(set) var lastAutomaticApplyID: UUID?

    public private(set) var arbitration = ProfileArbitration()
    /// The decision last applied successfully (or found already active).
    public private(set) var appliedDecision: ProfileDecision?
    /// English message of the last failed apply, cleared by the next success.
    public private(set) var lastError: String?
    public private(set) var isApplying = false

    /// Extra gate (the app: "Fan Control" enabled). `nil` = always allowed. While it returns
    /// `false`, decisions are tracked but not applied.
    @ObservationIgnored public var isApplyAllowed: (@MainActor () -> Bool)?

    @ObservationIgnored private let host: any FanProfileHosting
    @ObservationIgnored private var lastObservedActiveID: UUID
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var failedDecision: ProfileDecision?
    @ObservationIgnored private var isObservingHost = false

    public init(host: any FanProfileHosting) {
        self.host = host
        self.lastObservedActiveID = host.activeFanProfileID
    }

    /// manual > emergency > workload > power > default.
    public var decision: ProfileDecision? { arbitration.decision }

    /// Sets (or withdraws with `nil`) one automatic layer's claim and applies the new decision.
    public func setClaim(_ claim: ProfileClaim?, for layer: ProfileLayer) async {
        if claim != nil, arbitration.baselineProfileID == nil {
            arbitration.baselineProfileID = host.activeFanProfileID
        }
        guard arbitration.setClaim(claim, for: layer) else { return }
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

    /// The host's active profile may have changed (observation, or called directly). A change
    /// the arbiter did not make is a manual selection.
    public func activeProfileDidChange() {
        let current = host.activeFanProfileID
        guard current != lastObservedActiveID else { return }
        lastObservedActiveID = current
        guard !isApplying else { return }  // our own apply (or its rollback); re-synced after
        lastAutomaticApplyID = nil
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
    /// arriving during an apply runs once more afterwards.
    func reconcile() async {
        if isApplying {
            reconcileAgain = true
            return
        }
        repeat {
            reconcileAgain = false
            guard let decision = arbitration.decision else { return }
            if host.activeFanProfileID == decision.profileID {
                appliedDecision = decision
                lastError = nil
                continue
            }
            guard decision != failedDecision, isApplyAllowed?() ?? true else { return }
            isApplying = true
            lastAutomaticApplyID = decision.profileID
            do {
                try await host.applyFanProfile(id: decision.profileID)
                appliedDecision = decision
                lastError = nil
                NotificationCenter.default.post(name: Self.automaticApplyNotification, object: self, userInfo: [
                    "profileID": decision.profileID, "layer": decision.layer.rawValue, "reason": decision.reason,
                ])
                kitLog.notice("Fan profile switched by \(decision.layer.displayName, privacy: .public): \(decision.reason, privacy: .public)")
            } catch {
                failedDecision = decision
                lastError = error.localizedDescription
                kitLog.error("Fan profile switch (\(decision.layer.displayName, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
            isApplying = false
            lastObservedActiveID = host.activeFanProfileID
        } while reconcileAgain
    }
}
#endif
