import Foundation

public extension Notification.Name {
    /// Posted (object: `FanControlManager`) when `highTempAlertActive` changes.
    /// `userInfo["active"]` is the new `Bool`. Hook for a Live Activity (design doc §4.2).
    static let fanControlHighTemperatureChanged = Notification.Name("FanControlHighTemperatureChanged")
    /// Posted (object: `FanControlManager`) when `anomalousFanIDs` changes.
    /// `userInfo["fanIDs"]` is the new `Set<Int>`.
    static let fanControlFanAnomalyChanged = Notification.Name("FanControlFanAnomalyChanged")
    /// Posted (object: `FanControlManager`) on the main thread after every published poll.
    static let fanControlDidUpdate = Notification.Name("FanControlDidUpdate")
}

#if os(macOS)
import AppKit
import Observation
import FanControlCore
import FanControlSMC
import FanControlXPC

/// App-side fan control state and actions (design doc §3.1), following the
/// DynamicNotch manager pattern (`@Observable` + `static let shared`).
///
/// Threading model:
/// - Every observable property is read and written on the **main thread** only.
///   Public synchronous methods may be called from any thread (they hop to main);
///   async methods may be awaited from any context.
/// - SMC reads (`SMCClient`), discovery, alert evaluation and write planning run
///   on a private serial queue (`pollQueue`) that owns all poll state.
/// - Writes to the helper are serialized through `WriteSerializer`, so a write
///   list (mode first, then target) is never interleaved with another one.
///
/// Safety rules:
/// - The helper session is only ever opened by an explicit user action
///   (`setFanRPM`, `setFanControlMode`, `applyProfile` with manual modes,
///   `openSMCSession`). Polling, wake handling and the emergency override
///   never open it on their own (`apply(..., allowOpeningSession: false)`).
/// - A user apply bumps the apply generation (`ApplyGenerationGate`, owned by
///   `pollQueue`) before writing; poll-driven batches planned earlier are
///   dropped by the write queue, so a poll cannot undo the apply.
/// - While a session is open, every poll recomputes `FanControlEngine.plan`
///   (including the `SafetyPolicy` emergency override, which also applies to
///   the automatic profile) and writes only targets that moved by more than
///   `writeThresholdRPM`, or mode changes.
/// - On termination all fans are returned to automatic (bounded wait), and the
///   helper additionally restores original SMC values when our connection drops.
@Observable
public final class FanControlManager: @unchecked Sendable {

    public static let shared = FanControlManager()

    // MARK: - Constants

    /// UserDefaults key holding `ProfileStore` as JSON (`ProfileStore.encodeJSON`).
    /// The real app may swap this for a sindresorhus `Defaults` key with the same name.
    public static let profileStoreDefaultsKey = "fanControl.profileStore"
    /// Id of the user profile created when a single fan is changed while a
    /// built-in profile is active.
    public static let customProfileID = UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!
    /// Poll-driven target changes at or below this many RPM are not written.
    public static let writeThresholdRPM = 25
    /// Shown when `helperStatus == .requiresApproval` (`installHelper` throws
    /// `.helperNotInstalled` in that case, which carries no message of its own).
    /// English only; an app with its own localized text may show that instead.
    public static let helperApprovalInstructions =
        "Allow the DynamicNotch fan control helper in System Settings > General > Login Items & Extensions (macOS 15) / Login Items (macOS 14), then try again."

    // MARK: - State (read-only to views)

    public private(set) var fans: [FanDevice] = []
    public private(set) var currentRPMs: [Int: Int] = [:]
    public private(set) var targetRPMs: [Int: Int] = [:]
    public private(set) var sensorReadings: [SensorReading] = []
    /// While a write session is open: the active profile's mode per fan.
    /// Otherwise: the mode detected from the SMC (`FanDiscovery.fanControlModes`).
    public private(set) var fanControlModes: [Int: FanControlMode] = [:]
    public private(set) var isSMCConnected: Bool = false
    public private(set) var isMonitoring: Bool = false
    public private(set) var isMonitoringPaused: Bool = false
    public private(set) var lastUpdate: Date?
    public private(set) var lastError: FanControlError?
    public private(set) var helperStatus: HelperInstallStatus = .notRegistered
    public private(set) var helperConnectionState: HelperConnectionState = .disconnected
    public private(set) var isSMCWriteSessionOpen: Bool = false
    public private(set) var highTempAlertActive: Bool = false {
        didSet {
            guard highTempAlertActive != oldValue else { return }
            NotificationCenter.default.post(name: .fanControlHighTemperatureChanged, object: self,
                                            userInfo: ["active": highTempAlertActive])
        }
    }
    /// Emergency latch (`AlertEvaluator.evaluateEmergency`): turns on when the
    /// hottest emergency sensor reaches `safetyPolicy.emergencyTemperature`, off
    /// at `emergencyTemperature - alertHysteresis`. Evaluated on every poll.
    /// While it is on and a write session is open, every fan is driven to its
    /// maximum speed regardless of the active profile (also under Automatic).
    /// Without a session the latch is still reported but nothing is written.
    public private(set) var emergencyOverrideActive: Bool = false
    public private(set) var anomalousFanIDs: Set<Int> = [] {
        didSet {
            guard anomalousFanIDs != oldValue else { return }
            NotificationCenter.default.post(name: .fanControlFanAnomalyChanged, object: self,
                                            userInfo: ["fanIDs": anomalousFanIDs])
        }
    }

    // MARK: - Settings

    /// Seconds between polls (effective value clamped to 0.5...300). Changing it
    /// reschedules the timer while monitoring.
    public var pollingInterval: TimeInterval = 2.0 {
        didSet { if isMonitoring { scheduleTimer() } }
    }
    public var safetyPolicy: SafetyPolicy = .default
    /// When `true` (default), the active profile is re-applied 5 s after the Mac
    /// wakes, if a write session is still open. The app mirrors its own setting
    /// (e.g. `FanControlGeneralSettings.reapplyProfileAfterWake`) into this.
    ///
    /// When `false` and a session is open at wake, the session is **closed**
    /// 5 s after wake instead: the SMC may have silently reset the fans to
    /// automatic during sleep, which would leave the throttle baseline (and
    /// `fanControlModes`) claiming manual control that is no longer in effect.
    /// The helper restores the pre-session values on close; the user re-applies
    /// a profile to take control again.
    public var reapplyProfileAfterWake: Bool = true
    /// When `true` (default), `setMonitoringPaused(true)` without a write session
    /// keeps a slow poll (`max(5 × pollingInterval, 10 s)`, the same rate as with
    /// a session) so the high-temperature and fan-anomaly alerts still fire while
    /// the Nook is hidden. When `false`, polling stops while paused unless a
    /// session is open. The app mirrors "any alert enabled" into this.
    public var keepAlertsWhilePaused: Bool = true {
        didSet {
            if keepAlertsWhilePaused != oldValue, isMonitoring, isMonitoringPaused { scheduleTimer() }
        }
    }
    /// Team ID the helper's code signature must carry
    /// (`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)`, checked by
    /// `NSXPCConnection.setCodeSigningRequirement` on every new helper connection).
    /// Defaults to `FanControlHelperConstants.teamIdentifierPlaceholder`; set it at
    /// launch (before the first helper call) unless that constant was replaced.
    public var clientTeamID: String {
        get { helperClient.clientTeamID }
        set { helperClient.clientTeamID = newValue }
    }
    /// User profiles + active selection, persisted under `profileStoreDefaultsKey`.
    public var profileStore: ProfileStore {
        didSet { persistProfileStore() }
    }

    /// Built-ins (Automatic / Silent / Maximum for the current fans) followed by user profiles.
    public var availableProfiles: [FanProfile] {
        let builtInIDs: Set<UUID> = [FanProfile.BuiltInID.automatic, FanProfile.BuiltInID.silent,
                                     FanProfile.BuiltInID.maximum]
        return [FanProfile.automatic(), FanProfile.silent(for: fans), FanProfile.maximum(for: fans)]
            + profileStore.profiles.filter { !builtInIDs.contains($0.id) }
    }

    /// The active profile (built-ins included); Automatic when nothing is selected
    /// or the selection no longer exists. Never `nil` in practice.
    public var activeProfile: FanProfile? {
        resolvedActiveProfile
    }

    /// Hottest CPU/GPU sensor (per `safetyPolicy.emergencySensorPrefixes`),
    /// falling back to the hottest sensor overall.
    public var hottestSensor: SensorReading? {
        FanControlEngine.hottestEmergencySensor(sensorReadings, policy: safetyPolicy)
            ?? sensorReadings.filter { $0.temperature.isFinite }.max { $0.temperature < $1.temperature }
    }

    // MARK: - Private (main thread)

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var wakeWorkItem: DispatchWorkItem?

    // MARK: - Private (thread-safe)

    @ObservationIgnored private let helperClient: HelperClient
    @ObservationIgnored private let installer: HelperInstaller
    @ObservationIgnored private let serializer = WriteSerializer()
    @ObservationIgnored private let pollQueue = DispatchQueue(label: "com.example.dynamicnotch.DynamicNotch.fancontrol.poll",
                                                              qos: .utility)
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Private (pollQueue only)

    @ObservationIgnored private var reader: SMCClient?
    @ObservationIgnored private var strategy: FanWriteStrategy?
    @ObservationIgnored private var polledFans: [FanDevice] = []
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var alertEvaluator = AlertEvaluator()
    /// Last successfully written state per fan (throttle baseline).
    @ObservationIgnored private var appliedTargets: [Int: FanTarget] = [:]
    @ObservationIgnored private var pollWriteInFlight = false
    /// Bumped by every user apply / restore / session close before it writes;
    /// poll batches planned at an older generation are dropped.
    @ObservationIgnored private var applyGate = ApplyGenerationGate()
    /// pollQueue's view of `isMonitoring` (set in order with the queued work),
    /// so queued polls do not reopen the reader after `stopMonitoring()`.
    @ObservationIgnored private var monitoringActive = false

    // MARK: - Init

    /// Cheap: no SMC or XPC I/O (only the profile store is read from UserDefaults).
    public init(defaults: UserDefaults = .standard,
                helperClient: HelperClient = HelperClient(),
                installer: HelperInstaller = HelperInstaller()) {
        self.defaults = defaults
        self.helperClient = helperClient
        self.installer = installer
        if let data = defaults.data(forKey: Self.profileStoreDefaultsKey),
           let store = try? ProfileStore.decodeJSON(data) {
            self.profileStore = store
        } else {
            self.profileStore = ProfileStore()
        }
        helperClient.onStateChange = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                self.helperConnectionState = state
                self.syncSessionFlag()
            }
        }
    }

    // MARK: - Lifecycle

    /// Opens the SMC, discovers fans and sensors once, then polls every `pollingInterval`.
    public func startMonitoring() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startMonitoring() }
            return
        }
        guard !isMonitoring else { return }
        isMonitoring = true
        pollQueue.async { [self] in monitoringActive = true }
        registerSystemObserversIfNeeded()
        scheduleTimer()
        refreshNow()
    }

    /// Stops polling and closes the SMC reader. Cancels a pending wake re-apply
    /// and drops polls that were queued while monitoring (they do not reopen the
    /// reader). Does not close a write session: call `restoreDefaultControl()`
    /// first if fans should return to automatic.
    public func stopMonitoring() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopMonitoring() }
            return
        }
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        isSMCConnected = false
        pollQueue.async { [self] in
            monitoringActive = false
            closeReaderOnQueue()
        }
    }

    /// Polls once immediately. Also works when not monitoring: the SMC is then
    /// opened for this one poll and closed again (unless a write session is open).
    /// A refresh requested while monitoring that is still queued when
    /// `stopMonitoring()` runs is dropped.
    public func refreshNow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshNow() }
            return
        }
        let context = PollContext(profile: resolvedActiveProfile, policy: safetyPolicy,
                                  sessionOpen: helperClient.isSessionOpen,
                                  requiresMonitoring: isMonitoring)
        pollQueue.async { [self] in pollOnQueue(context) }
    }

    /// Main thread. Timer / wake / un-pause polls: only while monitoring.
    private func pollIfMonitoring() {
        guard isMonitoring else { return }
        refreshNow()
    }

    /// Call with `true` when the Nook is hidden (design doc §5.4). Polling slows
    /// down to `max(5 × pollingInterval, 10 s)` while a write session is open (so
    /// sensor-based modes and the emergency override keep working) or while
    /// `keepAlertsWhilePaused` is `true` (so alerts keep firing); otherwise it stops.
    public func setMonitoringPaused(_ paused: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setMonitoringPaused(paused) }
            return
        }
        guard paused != isMonitoringPaused else { return }
        isMonitoringPaused = paused
        scheduleTimer()
        if !paused { pollIfMonitoring() }
    }

    // MARK: - Control

    /// Sets a constant speed for one fan (see `setFanControlMode`).
    /// Throws `.rpmOutOfRange` if `rpm` is outside the fan's range.
    public func setFanRPM(fanIndex: Int, rpm: Int) async throws {
        try await setFanControlMode(fanIndex: fanIndex, mode: .constant(rpm: rpm))
    }

    /// Changes one fan's mode by editing the active profile: a user profile is
    /// updated in place; if a built-in is active, its modes are copied into the
    /// "Custom" profile (`customProfileID`), which becomes active. Opens the
    /// write session (installing the helper if needed) for manual modes.
    public func setFanControlMode(fanIndex: Int, mode: FanControlMode) async throws {
        try await recordingErrors {
            let fans = try await self.discoveredFans()
            guard let fan = fans.first(where: { $0.id == fanIndex }) else {
                throw FanControlError.keyNotFound("F\(fanIndex)Tg")
            }
            let (base, policy) = await MainActor.run { (self.resolvedActiveProfile, self.safetyPolicy) }
            if case .constant(let rpm) = mode {
                let allowed = policy.enforceHardwareMinimum ? fan.rpmRange : 0...fan.rpmRange.upperBound
                guard allowed.contains(rpm) else {
                    throw FanControlError.rpmOutOfRange(fan: fanIndex, rpm: rpm, allowed: allowed)
                }
            }
            var updated = base
            if base.isBuiltIn {
                updated = FanProfile(id: Self.customProfileID, name: "Custom", modes: base.modes, isBuiltIn: false)
            }
            updated.modes[fanIndex] = mode
            try await self.apply(updated, force: true, allowOpeningSession: true, makeActive: true)
        }
    }

    /// Applies `profile` (writing immediately, bypassing the throttle) and makes
    /// it active. Profiles with manual modes start monitoring if it is stopped
    /// and open the write session first. The profile is stored (user profiles)
    /// and selected *before* the writes; if writing fails, the previous
    /// selection and stored version are restored.
    public func applyProfile(_ profile: FanProfile) async throws {
        try await recordingErrors {
            try await self.apply(profile, force: true, allowOpeningSession: true, makeActive: true)
        }
    }

    /// Adds or replaces a user profile. Built-in profiles are ignored. If it is
    /// the active profile, the next poll applies the change.
    public func saveProfile(_ profile: FanProfile) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.saveProfile(profile) }
            return
        }
        guard !profile.isBuiltIn else { return }
        profileStore.upsert(profile)
    }

    /// Deletes a user profile. If it was active, Automatic becomes active and
    /// the next poll returns manual fans to automatic.
    public func deleteProfile(_ profile: FanProfile) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deleteProfile(profile) }
            return
        }
        profileStore.delete(id: profile.id)
    }

    /// Ensures the helper is registered (`installHelper`), checks its protocol
    /// version (re-registering a stale helper once) and opens the write session.
    public func openSMCSession() async throws {
        try await recordingErrors {
            let status = self.installer.status()
            await MainActor.run { self.helperStatus = status }
            if status != .enabled {
                try await self.installHelper()
            }
            var (version, _) = try await self.helperClient.version()
            if version != FanControlHelperConstants.protocolVersion {
                // A helper from an older/newer app build is still registered.
                self.helperClient.invalidate()
                try? await self.installer.unregister()
                try await self.installHelper()
                (version, _) = try await self.helperClient.version()
                guard version == FanControlHelperConstants.protocolVersion else {
                    throw FanControlError.helperRejected(
                        code: -1,
                        message: "Helper protocol version \(version) does not match the app's \(FanControlHelperConstants.protocolVersion).")
                }
            }
            try await self.helperClient.openSession()
            await self.onPollQueue { self.appliedTargets = [:] }
            await MainActor.run {
                // Termination restore and wake handling must work even if
                // monitoring was never started (idempotent).
                self.registerSystemObserversIfNeeded()
                self.syncSessionFlag()
            }
        }
    }

    /// Closes the write session after pending writes. The helper restores the
    /// original value of every key written during the session. Poll batches
    /// still queued are dropped (apply generation bump).
    public func closeSMCSession() async {
        await onPollQueue { _ = self.applyGate.advance() }
        _ = try? await serializer.run { [helperClient] in
            await helperClient.closeSession()
        }
        await onPollQueue { self.appliedTargets = [:] }
        await MainActor.run { self.syncSessionFlag() }
    }

    /// Registers the helper daemon. If the user still has to approve it, opens
    /// System Settings > General > Login Items & Extensions (macOS 15) / Login
    /// Items (macOS 14) and throws `.helperNotInstalled`
    /// (show `helperApprovalInstructions`).
    public func installHelper() async throws {
        try await recordingErrors {
            let status = try self.installer.register()
            await MainActor.run { self.helperStatus = status }
            switch status {
            case .enabled:
                return
            case .requiresApproval:
                await MainActor.run { HelperInstaller.openSystemSettingsLoginItems() }
                throw FanControlError.helperNotInstalled
            case .notFound:
                throw FanControlError.helperConnectionFailed(
                    "\(FanControlHelperConstants.plistName) is missing from DynamicNotch.app/Contents/Library/LaunchDaemons.")
            case .notRegistered, .unknown:
                throw FanControlError.helperNotInstalled
            }
        }
    }

    /// Clears `lastError` (e.g. when the user dismisses it). The manager never
    /// clears it on its own; a later failure sets it again.
    public func clearLastError() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clearLastError() }
            return
        }
        lastError = nil
    }

    /// Re-reads `SMAppService` status into `helperStatus`.
    public func refreshHelperStatus() {
        let status = installer.status()
        if Thread.isMainThread {
            helperStatus = status
        } else {
            DispatchQueue.main.async { self.helperStatus = status }
        }
    }

    /// Activates the Automatic profile, returns every fan to automatic and closes the session.
    public func restoreDefaultControl() async throws {
        try await recordingErrors {
            await MainActor.run { self.profileStore.activeProfileID = FanProfile.BuiltInID.automatic }
            // Drop poll batches planned from the previous profile.
            await self.onPollQueue { _ = self.applyGate.advance() }
            if self.helperClient.isSessionOpen {
                do {
                    let fans = try await self.discoveredFans()
                    try await self.applyTargets(Self.allAutomatic(fans), force: true)
                } catch {
                    await self.closeSMCSession()
                    throw error
                }
            }
            await self.closeSMCSession()
        }
    }

    /// Every SMC key with type, size, attributes and raw bytes (diagnostics, design doc §5.7).
    ///
    /// **Blocking**: waits (`pollQueue.sync`) for the in-flight poll and then for the
    /// whole dump, which reads every key and can take seconds. Never call it on the
    /// main thread; UIs should use `await exportSMCDump()` (the async overload).
    public func exportSMCDump() -> String {
        pollQueue.sync { dumpOnQueue() }
    }

    /// Same as the synchronous `exportSMCDump()`, but runs on `pollQueue` and
    /// suspends instead of blocking the caller. Safe to await from the main actor.
    public func exportSMCDump() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            pollQueue.async {
                continuation.resume(returning: self.dumpOnQueue())
            }
        }
    }

    /// pollQueue only.
    private func dumpOnQueue() -> String {
        let header = "# FanControlKit \(FanControlKitInfo.version) SMC dump, \(ISO8601DateFormatter().string(from: Date()))\n"
        if let reader { return header + reader.dump() }
        do {
            let client = try SMCClient()
            defer { client.close() }
            return header + client.dump()
        } catch {
            return header + "SMC dump failed: \(error)"
        }
    }

    // MARK: - Applying

    private var resolvedActiveProfile: FanProfile {
        guard let id = profileStore.activeProfileID else { return .automatic() }
        return availableProfiles.first { $0.id == id } ?? .automatic()
    }

    /// Plans `profile` against fresh fans/sensors and writes it.
    ///
    /// - `allowOpeningSession`: `true` only for explicit user actions
    ///   (`applyProfile`, `setFanRPM`, `setFanControlMode`). With `false` (wake
    ///   re-apply) the call returns immediately if no session is open, so it can
    ///   never open the helper session or trigger the install/approval flow.
    /// - A profile with manual modes starts monitoring first if it is stopped
    ///   (sensor-based modes, the emergency override and the throttle baseline
    ///   rely on polling), then opens the session if needed. An automatic profile
    ///   without a session writes nothing.
    /// - `makeActive`: stores (user profiles) and selects `profile` on the main
    ///   thread *before* writing, so polls snapshotted from then on plan it; on a
    ///   failed write the previous selection and stored version are restored.
    /// - The apply generation is bumped on `pollQueue` before planning, so a poll
    ///   batch planned from the previous profile that is still queued in the
    ///   `WriteSerializer` is dropped instead of undoing this apply.
    private func apply(_ profile: FanProfile, force: Bool, allowOpeningSession: Bool,
                       makeActive: Bool) async throws {
        if !allowOpeningSession && !helperClient.isSessionOpen { return }
        let needsSession = profile.modes.values.contains { $0.isManual }
        if needsSession {
            await MainActor.run {
                if !self.isMonitoring { self.startMonitoring() }
            }
            if !helperClient.isSessionOpen {
                guard allowOpeningSession else { return }
                try await openSMCSession()
            }
        }
        let rollback: ProfileSelectionRollback?
        if makeActive {
            rollback = await MainActor.run { self.selectProfile(profile) }
        } else {
            rollback = nil
        }
        guard helperClient.isSessionOpen else { return }
        do {
            let policy = await MainActor.run { self.safetyPolicy }
            let (fans, sensors, emergency) = try await onPollQueue {
                () throws -> ([FanDevice], [SensorReading], Bool) in
                // Polls enqueued before this point were snapshotted with the old
                // selection; their batches now carry a stale generation.
                self.applyGate.advance()
                try self.prepareReaderOnQueue()
                let sensors = self.reader.map { SensorCatalog.readTemperatures(keys: self.sensorKeys, using: $0) } ?? []
                // Same latch as the poll loop, so a user action cannot drop an
                // active emergency override inside the hysteresis band.
                let emergency = self.alertEvaluator.evaluateEmergency(sensors: sensors, policy: policy)
                return (self.polledFans, sensors, emergency)
            }
            let plan = FanControlEngine.plan(profile: profile, fans: fans, sensors: sensors, policy: policy,
                                             isEmergency: emergency)
            try await applyTargets(Self.targets(from: plan), force: force)
            let modes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, profile.mode(for: $0)) })
            await MainActor.run {
                self.fanControlModes = modes
                self.emergencyOverrideActive = emergency
            }
        } catch {
            if let rollback {
                await MainActor.run { self.rollBackSelection(rollback) }
            }
            throw error
        }
    }

    /// Main thread. Stores (user profiles) and selects `profile` in one
    /// `profileStore` assignment; returns what is needed to undo it.
    private func selectProfile(_ profile: FanProfile) -> ProfileSelectionRollback {
        let rollback = ProfileSelectionRollback(
            previousActiveID: profileStore.activeProfileID,
            profileID: profile.id,
            isBuiltIn: profile.isBuiltIn,
            previousStored: profileStore.profiles.first { $0.id == profile.id })
        var store = profileStore
        if !profile.isBuiltIn { store.upsert(profile) }
        store.activeProfileID = profile.id
        profileStore = store
        return rollback
    }

    /// Main thread. Undoes `selectProfile` after a failed apply.
    private func rollBackSelection(_ rollback: ProfileSelectionRollback) {
        var store = profileStore
        if let previous = rollback.previousStored {
            store.upsert(previous)
        } else if !rollback.isBuiltIn {
            store.profiles.removeAll { $0.id == rollback.profileID }
        }
        store.activeProfileID = rollback.previousActiveID
        profileStore = store
    }

    /// Serialized: plans the write list on `pollQueue` (dropping fans that did
    /// not change enough unless `force`), sends it to the helper, then records
    /// the applied state. A failed write leaves the baseline untouched so the
    /// next poll retries. `pollGeneration` is set only for poll-driven batches:
    /// such a batch is dropped (nothing written) if a user apply started after
    /// it was planned (`ApplyGenerationGate.isStale`).
    private func applyTargets(_ desired: [Int: FanTarget], force: Bool,
                              pollGeneration: UInt64? = nil) async throws {
        let helperClient = self.helperClient
        try await serializer.run { [self] in
            let (writes, pending) = try await onPollQueue { () throws -> ([SMCWrite], [Int: FanTarget]) in
                if let pollGeneration, self.applyGate.isStale(pollGeneration) { return ([], [:]) }
                try self.prepareReaderOnQueue()
                guard let strategy = self.strategy else { throw FanControlError.smcUnavailable }
                let pending = self.changedTargetsOnQueue(desired, force: force)
                guard !pending.isEmpty else { return ([], [:]) }
                return (try strategy.writes(for: pending).map { SMCWrite(key: $0.0, bytes: $0.1) }, pending)
            }
            for write in writes {
                try await helperClient.write(key: write.key, bytes: write.bytes)
            }
            if !pending.isEmpty {
                await onPollQueue { self.appliedTargets.merge(pending) { _, new in new } }
            }
        }
    }

    /// pollQueue only. Filters `desired` down to controllable fans whose state
    /// differs from `appliedTargets` by a mode change or more than `writeThresholdRPM`.
    private func changedTargetsOnQueue(_ desired: [Int: FanTarget], force: Bool) -> [Int: FanTarget] {
        let controllable = strategy?.fans ?? [:]
        var result: [Int: FanTarget] = [:]
        for (fan, target) in desired where controllable[fan] != nil {
            if force {
                result[fan] = target
                continue
            }
            switch (target, appliedTargets[fan]) {
            case (.automatic, .some(.manual)):
                result[fan] = target
            case (.automatic, _):
                break // never forced by us (or already automatic): leave it alone
            case (.manual(let rpm), .some(.manual(let old))):
                if abs(rpm - old) > Self.writeThresholdRPM { result[fan] = target }
            case (.manual, _):
                result[fan] = target
            }
        }
        return result
    }

    private static func targets(from plan: [Int: Int?]) -> [Int: FanTarget] {
        var result: [Int: FanTarget] = [:]
        for (fan, rpm) in plan {
            if let rpm { result[fan] = .manual(rpm: rpm) } else { result[fan] = .automatic }
        }
        return result
    }

    private static func allAutomatic(_ fans: [FanDevice]) -> [Int: FanTarget] {
        Dictionary(uniqueKeysWithValues: fans.map { ($0.id, FanTarget.automatic) })
    }

    // MARK: - Polling (pollQueue)

    /// pollQueue only. Opens the SMC and discovers sensors once; fan discovery
    /// is retried on every call while no fan is known (a failed or empty
    /// discovery, e.g. a transient `FNum` read error; on a fanless Mac this
    /// costs one `FNum` read per poll).
    private func prepareReaderOnQueue() throws {
        if let reader {
            if polledFans.isEmpty { discoverFansOnQueue(using: reader) }
            return
        }
        let client: SMCClient
        do {
            client = try SMCClient()
        } catch {
            publishOnMain { $0.isSMCConnected = false }
            throw error
        }
        let sensors = (try? SensorCatalog.discoverTemperatureSensors(using: client)) ?? []
        reader = client
        sensorKeys = sensors.map(\.id)
        alertEvaluator = AlertEvaluator()
        strategy = nil
        discoverFansOnQueue(using: client)
        publishOnMain { manager in
            manager.isSMCConnected = true
            manager.sensorReadings = sensors
        }
    }

    /// pollQueue only. Runs `FanDiscovery.discoverFans`; a failure is published
    /// to `lastError` and leaves `fans` empty (retried by later polls).
    private func discoverFansOnQueue(using client: SMCClient) {
        let fans: [FanDevice]
        do {
            fans = try FanDiscovery.discoverFans(using: client)
        } catch {
            fans = []
            publishErrorOnMain(Self.fanControlError(from: error))
        }
        guard fans != polledFans || strategy == nil else { return }
        polledFans = fans
        strategy = FanWriteStrategy(reader: client, fans: fans)
        publishOnMain { $0.fans = fans }
    }

    /// pollQueue only.
    private func closeReaderOnQueue() {
        reader?.close()
        reader = nil
        strategy = nil
    }

    private func pollOnQueue(_ context: PollContext) {
        // Queued while monitoring, but monitoring has stopped since: drop it
        // rather than reopening the reader that `stopMonitoring()` closed.
        if context.requiresMonitoring && !monitoringActive { return }
        // Explicit refresh while not monitoring: open the SMC for this poll only.
        let oneShot = !monitoringActive && reader == nil && !context.sessionOpen
        do {
            try prepareReaderOnQueue()
        } catch {
            publishErrorOnMain(Self.fanControlError(from: error))
            return
        }
        defer { if oneShot { closeReaderOnQueue() } }
        guard let reader else { return }
        let fans = polledFans
        let current = FanDiscovery.readCurrentRPMs(fans: fans, using: reader)
        let targets = FanDiscovery.readTargetRPMs(fans: fans, using: reader)
        let sensors = SensorCatalog.readTemperatures(keys: sensorKeys, using: reader)
        let highTemp = alertEvaluator.evaluateHighTemperature(sensors: sensors, policy: context.policy)
        // Evaluated every poll (session or not) so the latch's hysteresis state
        // is current when a session opens.
        let emergency = alertEvaluator.evaluateEmergency(sensors: sensors, policy: context.policy)
        let anomalies = alertEvaluator.evaluateFanAnomaly(fans: fans, currentRPMs: current, targetRPMs: targets)

        let modes: [Int: FanControlMode]
        if context.sessionOpen {
            modes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, context.profile.mode(for: $0)) })
            let plan = FanControlEngine.plan(profile: context.profile, fans: fans, sensors: sensors,
                                             policy: context.policy, isEmergency: emergency)
            let desired = Self.targets(from: plan)
            if !pollWriteInFlight, !changedTargetsOnQueue(desired, force: false).isEmpty {
                pollWriteInFlight = true
                let generation = applyGate.current
                Task {
                    do {
                        try await self.applyTargets(desired, force: false, pollGeneration: generation)
                    } catch {
                        self.publishErrorOnMain(Self.fanControlError(from: error))
                    }
                    self.pollQueue.async { self.pollWriteInFlight = false }
                }
            }
        } else {
            modes = FanDiscovery.fanControlModes(fans: fans, using: reader)
        }

        let now = Date()
        publishOnMain { manager in
            manager.fans = fans
            manager.currentRPMs = current
            manager.targetRPMs = targets
            manager.sensorReadings = sensors
            manager.fanControlModes = modes
            manager.highTempAlertActive = highTemp
            manager.emergencyOverrideActive = emergency
            manager.anomalousFanIDs = anomalies
            manager.isSMCConnected = true
            manager.lastUpdate = now
            NotificationCenter.default.post(name: .fanControlDidUpdate, object: manager)
        }
    }

    // MARK: - Timer (main thread)

    private var effectivePollingInterval: TimeInterval {
        min(max(pollingInterval, 0.5), 300)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard isMonitoring else { return }
        let interval: TimeInterval
        if isMonitoringPaused {
            // Slow mode keeps sensor-based modes / the emergency override (session)
            // and the alerts (`keepAlertsWhilePaused`) alive while hidden.
            guard isSMCWriteSessionOpen || keepAlertsWhilePaused else { return }
            interval = max(effectivePollingInterval * 5, 10)
        } else {
            interval = effectivePollingInterval
        }
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollIfMonitoring()
        }
        newTimer.tolerance = interval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Main thread. Mirrors `helperClient.isSessionOpen`; reschedules the timer
    /// when paused (a session keeps slow polling alive).
    private func syncSessionFlag() {
        let open = helperClient.isSessionOpen
        guard open != isSMCWriteSessionOpen else { return }
        isSMCWriteSessionOpen = open
        if isMonitoringPaused { scheduleTimer() }
    }

    // MARK: - Sleep / wake / termination (main thread)

    private func registerSystemObserversIfNeeded() {
        guard systemObservers.isEmpty else { return }
        // Only called from main-thread entry points. `assumeIsolated` keeps this
        // valid whether or not the SDK treats the AppKit notification names as
        // main-actor isolated (NSApplication is @MainActor).
        MainActor.assumeIsolated {
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            let wake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            let terminate = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                self?.restoreOnTermination()
            }
            self.systemObservers = [(workspaceCenter, wake), (NotificationCenter.default, terminate)]
        }
    }

    /// The SMC may reset fans to automatic across sleep. 5 s after wake (design
    /// doc §6 Phase 5), if a session is open: re-apply the active profile when
    /// `reapplyProfileAfterWake` is `true`, otherwise close the session so the
    /// kit's state does not claim manual control the SMC may have dropped. The
    /// flag is read when the delay elapses. Never opens a session.
    private func handleWake() {
        wakeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pollIfMonitoring()
            guard self.helperClient.isSessionOpen else { return }
            guard self.reapplyProfileAfterWake else {
                Task { await self.closeSMCSession() }
                return
            }
            let profile = self.resolvedActiveProfile
            Task {
                try? await self.recordingErrors {
                    try await self.apply(profile, force: true, allowOpeningSession: false, makeActive: false)
                }
            }
        }
        wakeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Returns every fan to automatic and closes the session, waiting at most
    /// 2 s. This path never hops to the main thread (which is blocked here).
    /// If it does not finish, the helper still restores the original values
    /// when the dying process's connection is invalidated.
    private func restoreOnTermination() {
        guard helperClient.isSessionOpen else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let fans = self.fans
        let helperClient = self.helperClient
        Task.detached {
            try? await self.applyTargets(Self.allAutomatic(fans), force: true)
            await helperClient.closeSession()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Utilities

    private func discoveredFans() async throws -> [FanDevice] {
        try await onPollQueue { () throws -> [FanDevice] in
            try self.prepareReaderOnQueue()
            return self.polledFans
        }
    }

    private func persistProfileStore() {
        if let data = try? ProfileStore.encodeJSON(profileStore) {
            defaults.set(data, forKey: Self.profileStoreDefaultsKey)
        }
    }

    private func publishOnMain(_ update: @escaping @Sendable (FanControlManager) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    /// Publishes `error` to `lastError` only if it differs from the current
    /// value (a failing poll would otherwise re-publish it every tick).
    private func publishErrorOnMain(_ error: FanControlError) {
        publishOnMain { manager in
            if manager.lastError != error { manager.lastError = error }
        }
    }

    private func onPollQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            pollQueue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func onPollQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pollQueue.async {
                body()
                continuation.resume()
            }
        }
    }

    /// Stores the error in `lastError` (main thread) and rethrows it.
    private func recordingErrors(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            let fanError = Self.fanControlError(from: error)
            await MainActor.run {
                if self.lastError != fanError { self.lastError = fanError }
            }
            throw error
        }
    }

    private static func fanControlError(from error: Error) -> FanControlError {
        (error as? FanControlError) ?? .helperConnectionFailed(error.localizedDescription)
    }
}

/// Settings snapshot taken on the main thread for one poll.
private struct PollContext: Sendable {
    var profile: FanProfile
    var policy: SafetyPolicy
    var sessionOpen: Bool
    /// `isMonitoring` at snapshot time: such a poll is dropped if monitoring
    /// stopped before it ran.
    var requiresMonitoring: Bool
}

/// What `selectProfile` changed, for `rollBackSelection`.
private struct ProfileSelectionRollback: Sendable {
    var previousActiveID: UUID?
    var profileID: UUID
    var isBuiltIn: Bool
    var previousStored: FanProfile?
}

/// One SMC write (Sendable stand-in for the `(SMCKey, [UInt8])` tuple).
private struct SMCWrite: Sendable {
    var key: SMCKey
    var bytes: [UInt8]
}

/// Runs async operations strictly one after another (FIFO), unlike plain actor
/// methods, which interleave at suspension points.
private actor WriteSerializer {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
#endif
