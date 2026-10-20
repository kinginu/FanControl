#if os(macOS)
import AppKit
import FanControlCore

/// What `FanController` needs from the rest of the kit (the facade implements it).
@MainActor
protocol FanControllerHost: AnyObject {
    /// User profiles + active selection (persisted by the host on every assignment).
    var profileStore: ProfileStore { get set }
    /// The active profile (Automatic when nothing valid is selected).
    var resolvedActiveProfile: FanProfile { get }
    var safetyPolicy: SafetyPolicy { get }
    var tuning: FanControlTuning { get }
    /// The last published fans (termination restore).
    var fans: [FanDevice] { get }
    var isMonitoring: Bool { get }
    func startMonitoring()
    /// Sleep / wake / termination / app-launch observers (idempotent).
    func registerSystemObserversIfNeeded()
    /// Publishes the outcome of a successful apply.
    func fanControllerDidApply(modes: [Int: FanControlMode], emergencyOverride: Bool)
}

/// The write side of `FanControlManager` (docs/kit.md "Architecture"): profile
/// apply with selection rollback, the helper session lifecycle, the return to
/// automatic, and the termination restore.
///
/// Safety rules (unchanged from the monolithic manager):
/// - The session is only opened by explicit user actions (`setFanControlMode`,
///   `setFanCurve`, `applyProfile`, `openSession`, and `restoreDefaultControl`
///   for orphaned manual fans). Wake re-applies use `allowOpeningSession: false`.
/// - Every user apply bumps the apply generation (`ApplyGenerationGate`, owned by
///   the poller) before writing, so a poll batch planned earlier cannot undo it.
/// - On termination all fans are returned to automatic (bounded wait).
@MainActor
final class FanController {

    /// Id of the user profile created when a single fan is changed while a
    /// built-in profile is active.
    nonisolated static let customProfileID = UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!

    weak var host: (any FanControllerHost)?
    /// The public operations record their errors here.
    var recordErrors: ErrorRecorder = .ignoring
    private let poller: FanControlPoller
    private let helper: HelperCoordinator
    private var terminationObserver: NSObjectProtocol?

    init(poller: FanControlPoller, helper: HelperCoordinator) {
        self.poller = poller
        self.helper = helper
    }

    // MARK: - User actions

    /// `FanControlManager.setFanControlMode(fanIndex:mode:)`.
    func setFanControlMode(fanIndex: Int, mode: FanControlMode) async throws {
        try await releasingIdleReader { try await self.recordErrors {
            guard let host = self.host else { return }
            let fans = try await self.poller.run { try $0.discoveredFans() }
            guard let fan = fans.first(where: { $0.id == fanIndex }) else {
                throw FanControlError.keyNotFound("F\(fanIndex)Tg")
            }
            let base = host.resolvedActiveProfile
            let policy = host.safetyPolicy
            if case .constant(let rpm) = mode {
                let allowed = policy.enforceHardwareMinimum ? fan.rpmRange : 0...fan.rpmRange.upperBound
                guard allowed.contains(rpm) else {
                    throw FanControlError.rpmOutOfRange(fan: fanIndex, rpm: rpm, allowed: allowed)
                }
            }
            let updated = Self.profile(changing: base, fanIndex: fanIndex, to: mode, fans: fans)
            try await self.apply(updated, force: true, allowOpeningSession: true, makeActive: true)
        } }
    }

    /// `FanControlManager.setFanCurve(fanIndex:sensorKey:curve:)`.
    func setFanCurve(fanIndex: Int, sensorKey: String, curve: FanCurve) async throws {
        try await releasingIdleReader { try await self.recordErrors {
            guard let host = self.host else { return }
            let fans = try await self.poller.run { try $0.discoveredFans() }
            guard fans.contains(where: { $0.id == fanIndex }) else {
                throw FanControlError.keyNotFound("F\(fanIndex)Tg")
            }
            var updated = Self.profile(changing: host.resolvedActiveProfile, fanIndex: fanIndex, to: .automatic,
                                       fans: fans)
            updated.setCurve(curve, sensorKey: sensorKey, forFan: fanIndex)
            try await self.apply(updated, force: true, allowOpeningSession: true, makeActive: true)
        } }
    }

    /// `FanControlManager.applyProfile(_:)`.
    func applyProfile(_ profile: FanProfile) async throws {
        try await recordErrors {
            try await self.apply(profile, force: true, allowOpeningSession: true, makeActive: true)
        }
    }

    /// The profile `setFanControlMode` applies: `base` with fan `fanIndex` set to
    /// `mode` (its curve, if any, is dropped: a `.sensor` mode set here runs linear).
    /// The other fans keep their *effective* mode: `base` is resolved for `fans`
    /// first, so a preset's `defaultMode` (Constant High, Boost, …) is materialised
    /// into per-fan modes instead of being dropped (untouched fans would otherwise
    /// fall back to automatic), and `apply` sees every manual fan in `modes`. A
    /// built-in base becomes the "Custom" profile (`customProfileID`, carrying the
    /// preset's `defaultMode` for fans not discovered yet); a user profile keeps
    /// its id, name and `defaultMode`.
    nonisolated static func profile(changing base: FanProfile, fanIndex: Int, to mode: FanControlMode,
                                    fans: [FanDevice]) -> FanProfile {
        let resolved = base.resolved(for: fans)
        var updated = resolved
        if base.isBuiltIn {
            updated = FanProfile(id: customProfileID, name: "Custom", modes: resolved.modes, isBuiltIn: false,
                                 defaultMode: base.defaultMode, curves: resolved.curves,
                                 defaultCurve: base.defaultCurve)
        }
        updated.modes[fanIndex] = mode
        updated.curves[fanIndex] = nil
        return updated
    }

    // MARK: - Session

    /// `FanControlManager.openSMCSession()`: handshake (`HelperCoordinator.openSession()`),
    /// fresh write state, observers, session flag.
    func openSession() async throws {
        try await recordErrors {
            try await self.helper.openSession()
            await self.poller.run { $0.resetWriteState() }
            // Termination restore and wake handling must work even if
            // monitoring was never started (idempotent).
            self.host?.registerSystemObserversIfNeeded()
            self.helper.syncSessionFlag()
        }
    }

    /// `FanControlManager.closeSMCSession()`: closes after pending writes; queued
    /// poll batches are dropped (apply generation bump).
    func closeSession() async {
        await poller.run { _ = $0.applyGate.advance() }
        _ = try? await poller.serializer.run { [helperClient = helper.client] in
            await helperClient.closeSession()
        }
        await poller.run { $0.resetWriteState() }
        helper.syncSessionFlag()
    }

    /// `closeSession()` in a new main-actor task (wake handling).
    func closeSessionInBackground() {
        Task { await self.closeSession() }
    }

    /// `FanControlManager.restoreDefaultControl()`.
    func restoreDefaultControl() async throws {
        try await releasingIdleReader { try await self.recordErrors {
            guard let host = self.host else { return }
            host.profileStore.activeProfileID = FanProfile.BuiltInID.automatic
            // Drop poll batches planned from the previous profile.
            await self.poller.run { _ = $0.applyGate.advance() }
            if !self.helper.isSessionOpen {
                let orphaned = try await self.poller.run { poller throws -> Bool in
                    try poller.prepareReader()
                    guard let reader = poller.reader else { return false }
                    return FanDiscovery.fanControlModes(fans: poller.polledFans, using: reader)
                        .values.contains { $0.isManual }
                }
                if orphaned { try await self.openSession() }
            }
            if self.helper.isSessionOpen {
                do {
                    let fans = try await self.poller.run { try $0.discoveredFans() }
                    try await self.poller.applyTargets(FanControlPoller.allAutomatic(fans), force: true)
                } catch {
                    await self.closeSession()
                    throw error
                }
            }
            await self.closeSession()
        } }
    }

    /// Runs `body`, then closes the SMC reader if `body` opened it outside
    /// monitoring and no session is open (`FanControlPoller.closeReaderIfIdle`):
    /// `discoveredFans()` and the orphan check open it, and with monitoring off
    /// nothing else would close it (`refreshNow()` one-shot polls only close a
    /// reader they opened themselves).
    private func releasingIdleReader(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await releaseIdleReader()
            throw error
        }
        await releaseIdleReader()
    }

    private func releaseIdleReader() async {
        let sessionOpen = helper.isSessionOpen
        await poller.run { $0.closeReaderIfIdle(sessionOpen: sessionOpen) }
    }

    // MARK: - Applying

    /// Plans `profile` against fresh fans/sensors and writes it.
    ///
    /// - `allowOpeningSession`: `true` only for explicit user actions. With `false`
    ///   (wake re-apply) the call returns immediately if no session is open, so it
    ///   can never open the helper session or trigger the install/approval flow.
    /// - A profile with manual modes (`requiresSession`: in `modes` or as
    ///   `defaultMode`) starts monitoring first if it is stopped
    ///   (sensor-based modes, the emergency override and the throttle baseline
    ///   rely on polling), then opens the session if needed. An automatic profile
    ///   without a session writes nothing.
    /// - `makeActive`: stores (user profiles) and selects `profile` on the main
    ///   actor *before* writing, so polls snapshotted from then on plan it; on a
    ///   failed write the previous selection and stored version are restored.
    /// - The apply generation is bumped on the poll queue before planning, so a poll
    ///   batch planned from the previous profile that is still queued in the
    ///   `WriteSerializer` is dropped instead of undoing this apply.
    func apply(_ profile: FanProfile, force: Bool, allowOpeningSession: Bool,
               makeActive: Bool) async throws {
        guard let host else { return }
        if !allowOpeningSession && !helper.isSessionOpen { return }
        if Self.requiresSession(profile) {
            if !host.isMonitoring { host.startMonitoring() }
            if !helper.isSessionOpen {
                guard allowOpeningSession else { return }
                try await openSession()
            }
        }
        var rollback: ProfileSelectionRollback?
        if makeActive {
            var store = host.profileStore
            rollback = ProfileSelectionRollback.select(profile, in: &store)
            host.profileStore = store
        }
        guard helper.isSessionOpen else { return }
        do {
            let policy = host.safetyPolicy
            let tuning = host.tuning
            let (fans, plan, emergency) = try await poller.run { poller throws in
                try poller.planApply(profile: profile, policy: policy, tuning: tuning)
            }
            try await poller.applyTargets(FanControlPoller.targets(from: plan), force: force)
            host.fanControllerDidApply(
                modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, profile.mode(for: $0)) }),
                emergencyOverride: emergency)
        } catch {
            if let rollback {
                var store = host.profileStore
                rollback.undo(in: &store)
                host.profileStore = store
            }
            throw error
        }
    }

    /// Whether applying `profile` needs the write session: a manual mode in
    /// `modes` or a manual `defaultMode`. The latter covers the "every fan"
    /// presets passed unresolved, or resolved before the fans are known
    /// (`resolved(for: [])` adds no `modes`); deciding from `modes` alone
    /// selected such a preset without opening the session or writing anything.
    /// (A manual `defaultMode` overridden by explicit `.automatic` entries for
    /// every fan opens a session that writes automatic: harmless.)
    nonisolated static func requiresSession(_ profile: FanProfile) -> Bool {
        profile.modes.values.contains { $0.isManual } || (profile.defaultMode?.isManual ?? false)
    }

    /// One wake re-apply of the active profile, in a new main-actor task: bypasses
    /// the throttle and never opens a session. The profile is resolved now.
    func reapplyActiveProfile(recordingErrors: Bool) {
        guard let profile = host?.resolvedActiveProfile else { return }
        Task {
            if recordingErrors {
                try? await self.recordErrors {
                    try await self.apply(profile, force: true, allowOpeningSession: false, makeActive: false)
                }
            } else {
                try? await self.apply(profile, force: true, allowOpeningSession: false, makeActive: false)
            }
        }
    }

    // MARK: - Termination

    /// Observes `NSApplication.willTerminateNotification` (main queue). Idempotent.
    func registerObserversIfNeeded() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOnTermination() }
        }
    }

    /// Returns every fan to automatic and closes the session, waiting at most
    /// 2 s. The detached task never hops to the main actor (whose thread is
    /// blocked here): it only uses the poller and the helper client.
    /// If it does not finish, the helper still restores the original values
    /// when the dying process's connection is invalidated.
    func restoreOnTermination() {
        guard helper.isSessionOpen else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let fans = host?.fans ?? []
        let helperClient = helper.client
        let poller = self.poller
        Task.detached {
            // Drop queued poll batches (the poll queue is not blocked here), then
            // close through the serializer so no batch can slip in between.
            await poller.run { _ = $0.applyGate.advance() }
            try? await poller.applyTargets(FanControlPoller.allAutomatic(fans), force: true)
            _ = try? await poller.serializer.run { await helperClient.closeSession() }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

/// What `ProfileSelectionRollback.select` changed in a `ProfileStore`, to undo it
/// after a failed apply.
struct ProfileSelectionRollback: Equatable, Sendable {
    var previousActiveID: UUID?
    var profileID: UUID
    var isBuiltIn: Bool
    var previousStored: FanProfile?

    /// Stores `profile` (user profiles only) and selects it in `store`.
    static func select(_ profile: FanProfile, in store: inout ProfileStore) -> ProfileSelectionRollback {
        let rollback = ProfileSelectionRollback(
            previousActiveID: store.activeProfileID,
            profileID: profile.id,
            isBuiltIn: profile.isBuiltIn,
            previousStored: store.profiles.first { $0.id == profile.id })
        if !profile.isBuiltIn { store.upsert(profile) }
        store.activeProfileID = profile.id
        return rollback
    }

    /// Restores the stored version (or removes a newly added user profile) and the
    /// previous selection.
    func undo(in store: inout ProfileStore) {
        if let previous = previousStored {
            store.upsert(previous)
        } else if !isBuiltIn {
            store.profiles.removeAll { $0.id == profileID }
        }
        store.activeProfileID = previousActiveID
    }
}
#endif
