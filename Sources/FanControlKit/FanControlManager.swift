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
import os
import FanControlCore
import FanControlSMC
import FanControlXPC

/// App-side fan control state and actions (design doc §3.1), following the
/// DynamicNotch manager pattern (`@Observable` + `static let shared`).
///
/// Threading model (docs/kit.md "Threading model"):
/// - The manager is `@MainActor`: every observable property, the timer, the
///   profile store and the pause / wake bookkeeping live on the main actor.
///   Views call its synchronous methods directly and `await` its async ones;
///   off-main callers `await` both. The constants, `clientTeamID`,
///   `sensorAggregateDefinitions` and `exportSMCDump()` are `nonisolated`.
/// - SMC reads (`SMCClient`), discovery, alert evaluation and write planning run
///   on a private serial dispatch queue: the executor of `FanControlPoller`, an
///   actor that owns all poll state (compiler-checked).
/// - Writes to the helper are serialized through `WriteSerializer`, so a write
///   list (mode first, then target) is never interleaved with another one.
///
/// Safety rules:
/// - The helper session is only ever opened by an explicit user action
///   (`setFanRPM`, `setFanControlMode`, `applyProfile` with manual modes,
///   `openSMCSession`). Polling, wake handling and the emergency override
///   never open it on their own (`apply(..., allowOpeningSession: false)`).
/// - A user apply bumps the apply generation (`ApplyGenerationGate`, owned by
///   the poller) before writing; poll-driven batches planned earlier are
///   dropped by the write queue, so a poll cannot undo the apply.
/// - While a session is open, every poll recomputes `FanControlEngine.plan`
///   (including the `SafetyPolicy` emergency override, which also applies to
///   the automatic profile) and writes only targets that moved by more than
///   `writeThresholdRPM`, or mode changes.
/// - On termination all fans are returned to automatic (bounded wait), and the
///   helper additionally restores original SMC values when our connection drops.
@MainActor
@Observable
public final class FanControlManager {

    /// The app-wide instance (created on first use on the main actor).
    public static let shared = FanControlManager()

    // MARK: - Constants

    /// UserDefaults key holding `ProfileStore` as JSON (`ProfileStore.encodeJSON`).
    /// The real app may swap this for a sindresorhus `Defaults` key with the same name.
    public nonisolated static let profileStoreDefaultsKey = "fanControl.profileStore"
    /// Id of the user profile created when a single fan is changed while a
    /// built-in profile is active.
    public nonisolated static let customProfileID = UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!
    /// Poll-driven target changes at or below this many RPM are not written.
    public nonisolated static let writeThresholdRPM = 25
    /// Seconds after `NSWorkspace.didWakeNotification` at which the active profile
    /// is re-applied while a session is open (`reapplyProfileAfterWake`).
    public nonisolated static let wakeReapplyDelays: [TimeInterval] = [0, 2, 5]
    /// Shown when `helperStatus == .requiresApproval` (`installHelper` throws
    /// `.helperNotInstalled` in that case, which carries no message of its own).
    /// English only; an app with its own localized text may show that instead.
    public nonisolated static let helperApprovalInstructions =
        "Allow the DynamicNotch fan control helper in System Settings > General > Login Items & Extensions, then try again."

    // MARK: - State (read-only to views; set on the main actor by the manager and `FanControlPoller`)

    public internal(set) var fans: [FanDevice] = []
    public internal(set) var currentRPMs: [Int: Int] = [:]
    public internal(set) var targetRPMs: [Int: Int] = [:]
    /// Filtered by `TemperatureSampleFilter` (implausible near-zero CPU/GPU
    /// samples replaced), followed by the aggregate sensors
    /// (`SensorAggregator`, ids `"agg:…"`, `sensorType == .greatest`) computed
    /// from the filtered values; the same array is fed to `FanControlEngine.plan`,
    /// so a profile may bind to an aggregate id such as `"agg:cpu"`.
    public internal(set) var sensorReadings: [SensorReading] = []
    /// Keys whose value in `sensorReadings` was substituted by the
    /// `TemperatureSampleFilter` in the latest poll (e.g. to dim them in the UI).
    public internal(set) var substitutedSensorKeys: Set<String> = []
    /// While a write session is open: the active profile's mode per fan.
    /// Otherwise: the mode detected from the SMC (`FanDiscovery.fanControlModes`).
    public internal(set) var fanControlModes: [Int: FanControlMode] = [:]
    public internal(set) var isSMCConnected: Bool = false
    public internal(set) var isMonitoring: Bool = false
    /// The host's last `setMonitoringPaused` request (Nook hidden). Whether the
    /// slow / stopped polling is actually in effect is `isPauseInEffect`.
    public internal(set) var isMonitoringPaused: Bool = false
    /// `isMonitoringPaused` and no live-data hold (`setLiveDataHold(_:for:)`):
    /// the poll timer runs slowed (or stopped) only while this is `true`.
    public internal(set) var isPauseInEffect: Bool = false
    public internal(set) var lastUpdate: Date?
    public internal(set) var lastError: FanControlError?
    public internal(set) var helperStatus: HelperInstallStatus = .notRegistered
    public internal(set) var helperConnectionState: HelperConnectionState = .disconnected
    public internal(set) var isSMCWriteSessionOpen: Bool = false
    public internal(set) var highTempAlertActive: Bool = false {
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
    public internal(set) var emergencyOverrideActive: Bool = false
    public internal(set) var anomalousFanIDs: Set<Int> = [] {
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
    /// Starts as `FanControlPlatform.defaultSafetyPolicy` (= `SafetyPolicy.default`;
    /// the emergency prefixes exclude `TG`, a battery-area sensor on Apple
    /// Silicon; see `SafetyPolicy.defaultEmergencySensorPrefixes`).
    /// Not persisted by the kit.
    public var safetyPolicy: SafetyPolicy = FanControlPlatform.defaultSafetyPolicy
    /// When `true` (default) and a write session is still open when the Mac
    /// wakes, the active profile is re-applied **immediately** on
    /// `NSWorkspace.didWakeNotification` and again `wakeReapplyDelays` later
    /// (0 s, 2 s, 5 s; idempotent, bypassing the throttle). The app mirrors its
    /// own setting (e.g. `FanControlGeneralSettings.reapplyProfileAfterWake`) into this.
    ///
    /// When `false` and a session is open at wake, the session is **closed
    /// immediately** instead: the SMC resets `F<n>Tg` to 0 across sleep while
    /// keeping `F<n>Md` = 1 (first-write test 4), so manual control as it was
    /// before sleep is not in effect any more. The helper hands the fans back to
    /// the SMC on close; the user re-applies a profile to take control again.
    ///
    /// Either way the helper itself also hands forced fans back before sleep and
    /// re-applies the session's last targets after wake (`docs/helper.md` §5),
    /// so the fans are not left stopped if this notification is late.
    public var reapplyProfileAfterWake: Bool = true
    /// When `true` (default), `setMonitoringPaused(true)` without a write session
    /// keeps a slow poll (`max(5 × pollingInterval, 10 s)`, the same rate as with
    /// a session) so the high-temperature and fan-anomaly alerts still fire while
    /// the Nook is hidden. When `false`, polling stops while paused unless a
    /// session is open. The app mirrors "any alert enabled" into this.
    public var keepAlertsWhilePaused: Bool = true {
        didSet {
            if keepAlertsWhilePaused != oldValue, isMonitoring, isPauseInEffect { scheduleTimer() }
        }
    }
    /// Team ID the helper's code signature must carry
    /// (`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)`, checked by
    /// `NSXPCConnection.setCodeSigningRequirement` on every new helper connection).
    /// Defaults to `FanControlHelperConstants.teamIdentifierPlaceholder`; set it at
    /// launch (before the first helper call) unless that constant was replaced.
    /// Ignored in manual-install mode (ad-hoc signed app or `install.sh` installation),
    /// where the helper's cdhash is pinned instead (`HelperClient`).
    public nonisolated var clientTeamID: String {
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

    /// The aggregate sensors appended to `sensorReadings`
    /// (`FanControlPlatform.sensorAggregateDefinitions`). Fixed for the process.
    public nonisolated var sensorAggregateDefinitions: [SensorAggregateDefinition] { poller.aggregateDefinitions }

    /// Hottest CPU/GPU sensor (per `safetyPolicy.emergencySensorPrefixes`),
    /// falling back to the hottest sensor overall, skipping keys excluded from
    /// ranking (`SensorCatalog.isExcludedFromRanking(_:)`, e.g. `Tf*`).
    public var hottestSensor: SensorReading? {
        FanControlEngine.hottestEmergencySensor(sensorReadings, policy: safetyPolicy)
            ?? sensorReadings
                .filter { $0.temperature.isFinite && !$0.isExcludedFromRanking }
                .max { $0.temperature < $1.temperature }
    }

    // MARK: - Private (main actor)

    /// Nook pause request + live-data holds (`isPauseInEffect`).
    @ObservationIgnored private var pauseState = MonitoringPauseState()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Pending wake re-apply attempts (`wakeReapplyDelays`).
    @ObservationIgnored private var wakeWorkItems: [DispatchWorkItem] = []

    // MARK: - Private (Sendable, any isolation)

    @ObservationIgnored private nonisolated let helperClient: HelperClient
    @ObservationIgnored private nonisolated let installer: HelperInstaller
    /// Owns the poll queue and all poll state (SMC reader, fans, alert latch,
    /// sample filter, write strategy, throttle baseline, apply generation).
    @ObservationIgnored private nonisolated let poller: FanControlPoller
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Init

    /// Cheap: no SMC or XPC I/O (only the profile store is read from UserDefaults).
    /// On a non-Apple-Silicon Mac this logs an error; every later SMC open then
    /// fails with `FanControlError.unsupportedPlatform` (Intel dropped 2026-10-20).
    public init(defaults: UserDefaults = .standard,
                helperClient: HelperClient = HelperClient(),
                installer: HelperInstaller = HelperInstaller()) {
        self.defaults = defaults
        self.helperClient = helperClient
        self.installer = installer
        let poller = FanControlPoller(helperClient: helperClient)
        self.poller = poller
        if let data = defaults.data(forKey: Self.profileStoreDefaultsKey),
           let store = try? ProfileStore.decodeJSON(data) {
            self.profileStore = store
        } else {
            self.profileStore = ProfileStore()
        }
        if !FanControlPlatform.isSupported {
            kitLog.error("Fan control disabled: \(FanControlPlatform.unsupportedPlatformDetail, privacy: .public)")
        }
        helperClient.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperConnectionState = state
                self.syncSessionFlag()
            }
        }
        // First job on the poll queue: every later poll can publish.
        poller.enqueue { [weak self] poller in
            if let self { poller.attach(self) }
        }
    }

    // MARK: - Lifecycle

    /// Opens the SMC, discovers fans and sensors once, then polls every `pollingInterval`.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        poller.enqueue { $0.monitoringActive = true }
        registerSystemObserversIfNeeded()
        scheduleTimer()
        refreshNow()
    }

    /// Stops polling and closes the SMC reader. Cancels a pending wake re-apply
    /// and drops polls that were queued while monitoring (they do not reopen the
    /// reader). Does not close a write session: call `restoreDefaultControl()`
    /// first if fans should return to automatic.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        cancelWakeWork()
        isSMCConnected = false
        poller.enqueue { poller in
            poller.monitoringActive = false
            poller.closeReader()
        }
    }

    /// Polls once immediately. Also works when not monitoring: the SMC is then
    /// opened for this one poll and closed again (unless a write session is open).
    /// A refresh requested while monitoring that is still queued when
    /// `stopMonitoring()` runs is dropped.
    public func refreshNow() {
        let context = PollContext(profile: resolvedActiveProfile, policy: safetyPolicy,
                                  sessionOpen: helperClient.isSessionOpen,
                                  requiresMonitoring: isMonitoring)
        poller.enqueue { $0.poll(context) }
    }

    /// Timer / wake / un-pause polls: only while monitoring.
    private func pollIfMonitoring() {
        guard isMonitoring else { return }
        refreshNow()
    }

    /// Call with `true` when the Nook is hidden and `false` when it is shown
    /// (design doc §5.4; the host drives it from its Nook visibility, PATCHES.md (b)).
    /// While the pause is in effect (`isPauseInEffect`: paused and no live-data
    /// hold) polling slows down to `max(5 × pollingInterval, 10 s)` while a write
    /// session is open (so sensor-based modes and the emergency override keep
    /// working) or while `keepAlertsWhilePaused` is `true` (so alerts keep
    /// firing); otherwise it stops.
    public func setMonitoringPaused(_ paused: Bool) {
        guard paused != isMonitoringPaused else { return }
        isMonitoringPaused = paused
        pauseState.requested = paused
        syncPauseInEffect()
    }

    /// A view that shows live data regardless of the Nook (the settings pane)
    /// holds it while visible: `true` on appear, `false` on disappear, with a
    /// name unique to the view. While any hold exists the Nook pause is not in
    /// effect (normal polling) and `isMonitoringPaused` keeps the host's request,
    /// so releasing the last hold returns to the paused rate without the view
    /// having to remember or restore the previous pause state.
    public func setLiveDataHold(_ held: Bool, for holder: String) {
        pauseState.setHold(held, for: holder)
        syncPauseInEffect()
    }

    /// Reschedules the timer when `isPauseInEffect` changes; polls at once when
    /// the pause ends.
    private func syncPauseInEffect() {
        let inEffect = pauseState.isInEffect
        guard inEffect != isPauseInEffect else { return }
        isPauseInEffect = inEffect
        scheduleTimer()
        if !inEffect { pollIfMonitoring() }
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
            let fans = try await self.poller.run { try $0.discoveredFans() }
            guard let fan = fans.first(where: { $0.id == fanIndex }) else {
                throw FanControlError.keyNotFound("F\(fanIndex)Tg")
            }
            let base = self.resolvedActiveProfile
            let policy = self.safetyPolicy
            if case .constant(let rpm) = mode {
                let allowed = policy.enforceHardwareMinimum ? fan.rpmRange : 0...fan.rpmRange.upperBound
                guard allowed.contains(rpm) else {
                    throw FanControlError.rpmOutOfRange(fan: fanIndex, rpm: rpm, allowed: allowed)
                }
            }
            let updated = Self.profile(changing: base, fanIndex: fanIndex, to: mode, fans: fans)
            try await self.apply(updated, force: true, allowOpeningSession: true, makeActive: true)
        }
    }

    /// The profile `setFanControlMode` applies: `base` with fan `fanIndex` set to
    /// `mode`. The other fans keep their *effective* mode: `base` is resolved for
    /// `fans` first, so a preset's `defaultMode` (Constant High, Boost, …) is
    /// materialised into per-fan modes instead of being dropped (untouched fans
    /// would otherwise fall back to automatic), and `apply` sees every manual fan
    /// in `modes`. A built-in base becomes the "Custom" profile (`customProfileID`,
    /// carrying the preset's `defaultMode` for fans not discovered yet); a user
    /// profile keeps its id, name and `defaultMode`.
    nonisolated static func profile(changing base: FanProfile, fanIndex: Int, to mode: FanControlMode,
                                    fans: [FanDevice]) -> FanProfile {
        let resolved = base.resolved(for: fans)
        var updated = resolved
        if base.isBuiltIn {
            updated = FanProfile(id: customProfileID, name: "Custom", modes: resolved.modes, isBuiltIn: false,
                                 defaultMode: base.defaultMode)
        }
        updated.modes[fanIndex] = mode
        return updated
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
        guard !profile.isBuiltIn else { return }
        profileStore.upsert(profile)
    }

    /// Deletes a user profile. If it was active, Automatic becomes active and
    /// the next poll returns manual fans to automatic.
    public func deleteProfile(_ profile: FanProfile) {
        profileStore.delete(id: profile.id)
    }

    /// Ensures the helper is registered (`installHelper`), checks its protocol
    /// version (re-registering a stale helper once) and opens the write session.
    public func openSMCSession() async throws {
        try await recordingErrors {
            let status = self.installer.status()
            self.helperStatus = status
            // A manual installation pinned to another build is not "installed" for this
            // app, but there is nothing to register either: `version()` below is
            // refused by `HelperClient` without connecting (`.clientNotPinned`).
            if status != .enabled && !status.isManualInstallation {
                try await self.installHelper()
            }
            var (version, _) = try await self.helperClient.version()
            if version != FanControlHelperConstants.protocolVersion, status.isManualInstallation {
                // Only root can replace a manually installed helper.
                throw FanControlError.helperRejected(
                    code: -1,
                    message: "The manually installed helper speaks protocol \(version), the app needs \(FanControlHelperConstants.protocolVersion). Re-run sudo \(FanControlHelperConstants.manualInstallScriptName) with this app.")
            }
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
            await self.poller.run { poller in
                poller.appliedTargets = [:]
                poller.unsettledFans = []
            }
            // Termination restore and wake handling must work even if
            // monitoring was never started (idempotent).
            self.registerSystemObserversIfNeeded()
            self.syncSessionFlag()
        }
    }

    /// Closes the write session after pending writes. The helper restores the
    /// original value of every key written during the session. Poll batches
    /// still queued are dropped (apply generation bump).
    public func closeSMCSession() async {
        await poller.run { _ = $0.applyGate.advance() }
        _ = try? await poller.serializer.run { [helperClient] in
            await helperClient.closeSession()
        }
        await poller.run { poller in
            poller.appliedTargets = [:]
            poller.unsettledFans = []
        }
        syncSessionFlag()
    }

    /// Registers the helper daemon (no-op for a manual installation, see
    /// `HelperInstaller.register()`). If the user still has to approve it, opens
    /// System Settings > General > Login Items & Extensions and throws
    /// `.helperNotInstalled` (show `helperApprovalInstructions`).
    public func installHelper() async throws {
        try await recordingErrors {
            // `SMAppService.register()` talks to launchd / BTM: keep it off the main actor.
            let status = try await Self.register(self.installer)
            self.helperStatus = status
            switch status {
            case .enabled, .installedManually:
                return
            case .installedManuallyMismatch(let pinned, let app):
                // Only root can re-pin: the user must re-run install.sh.
                throw FanControlError.helperConnectionRejected(
                    HelperRejectionReason.clientNotPinned(pinnedCDHash: pinned, appCDHash: app).description)
            case .requiresApproval:
                HelperInstaller.openSystemSettingsLoginItems()
                throw FanControlError.helperNotInstalled
            case .notFound:
                throw FanControlError.helperConnectionFailed(
                    "\(FanControlHelperConstants.plistName) is missing from DynamicNotch.app/Contents/Library/LaunchDaemons.")
            case .notRegistered, .unknown:
                throw FanControlError.helperNotInstalled
            }
        }
    }

    /// Runs `installer.register()` on the global concurrent executor.
    private nonisolated static func register(_ installer: HelperInstaller) async throws -> HelperInstallStatus {
        try installer.register()
    }

    /// Clears `lastError` (e.g. when the user dismisses it). The manager never
    /// clears it on its own; a later failure sets it again.
    public func clearLastError() {
        lastError = nil
    }

    /// User action ("Check Again"): forgets a sticky helper rejection and the
    /// connection backoff (`HelperClient.resetRejection()`), re-reads `helperStatus`
    /// and, if the helper is installed, probes it once with the read-only
    /// `version()` call so `helperConnectionState` shows whether it accepts this app
    /// now. The only place besides install / apply / restore that connects to the
    /// helper. A manual installation pinned to another build is reported again
    /// without connecting. Throws (and records) the probe's error.
    public func retryHelperConnection() async throws {
        try await recordingErrors {
            self.helperClient.resetRejection()
            let status = self.installer.status()
            self.helperStatus = status
            guard status == .enabled || status.isManualInstallation else { return }
            _ = try await self.helperClient.version()
        }
    }

    /// Re-reads the install status (manual installation or `SMAppService`) into
    /// `helperStatus`. File / `SMAppService` reads only; never connects to the helper.
    public func refreshHelperStatus() {
        helperStatus = installer.status()
    }

    /// Activates the Automatic profile, returns every fan to automatic and closes the session.
    ///
    /// If no session is open but the SMC reports a fan in manual mode (e.g. the
    /// helper crashed or was killed mid-session, so it could not restore; or
    /// another tool forced the fan), this explicit user action opens a session
    /// just to write automatic and closes it again.
    public func restoreDefaultControl() async throws {
        try await recordingErrors {
            self.profileStore.activeProfileID = FanProfile.BuiltInID.automatic
            // Drop poll batches planned from the previous profile.
            await self.poller.run { _ = $0.applyGate.advance() }
            if !self.helperClient.isSessionOpen {
                let orphaned = try await self.poller.run { poller throws -> Bool in
                    try poller.prepareReader()
                    guard let reader = poller.reader else { return false }
                    return FanDiscovery.fanControlModes(fans: poller.polledFans, using: reader)
                        .values.contains { $0.isManual }
                }
                if orphaned { try await self.openSMCSession() }
            }
            if self.helperClient.isSessionOpen {
                do {
                    let fans = try await self.poller.run { try $0.discoveredFans() }
                    try await self.poller.applyTargets(FanControlPoller.allAutomatic(fans), force: true)
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
    /// **Blocking**: waits (`queue.sync` on the poll queue) for the in-flight poll and
    /// then for the whole dump, which reads every key and can take seconds. Never call
    /// it on the main thread (or on the poll queue); UIs should use
    /// `await exportSMCDump()` (the async overload).
    public nonisolated func exportSMCDump() -> String {
        let poller = self.poller
        return poller.queue.sync {
            // `queue` is the poller's executor.
            poller.assumeIsolated { $0.dump() }
        }
    }

    /// Same as the synchronous `exportSMCDump()`, but runs on the poll queue and
    /// suspends instead of blocking the caller. Safe to await from the main actor.
    public nonisolated func exportSMCDump() async -> String {
        await poller.dump()
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
    ///   actor *before* writing, so polls snapshotted from then on plan it; on a
    ///   failed write the previous selection and stored version are restored.
    /// - The apply generation is bumped on the poll queue before planning, so a poll
    ///   batch planned from the previous profile that is still queued in the
    ///   `WriteSerializer` is dropped instead of undoing this apply.
    private func apply(_ profile: FanProfile, force: Bool, allowOpeningSession: Bool,
                       makeActive: Bool) async throws {
        if !allowOpeningSession && !helperClient.isSessionOpen { return }
        let needsSession = profile.modes.values.contains { $0.isManual }
        if needsSession {
            if !isMonitoring { startMonitoring() }
            if !helperClient.isSessionOpen {
                guard allowOpeningSession else { return }
                try await openSMCSession()
            }
        }
        let rollback = makeActive ? selectProfile(profile) : nil
        guard helperClient.isSessionOpen else { return }
        do {
            let policy = safetyPolicy
            let (fans, sensors, emergency) = try await poller.run {
                poller throws -> ([FanDevice], [SensorReading], Bool) in
                // Polls enqueued before this point were snapshotted with the old
                // selection; their batches now carry a stale generation.
                poller.applyGate.advance()
                try poller.prepareReader()
                let sensors = poller.reader.map { poller.readFilteredTemperatures(using: $0) } ?? []
                // Same latch as the poll loop, so a user action cannot drop an
                // active emergency override inside the hysteresis band.
                let emergency = poller.alertEvaluator.evaluateEmergency(sensors: sensors, policy: policy)
                return (poller.polledFans, sensors, emergency)
            }
            let plan = FanControlEngine.plan(profile: profile, fans: fans, sensors: sensors, policy: policy,
                                             isEmergency: emergency)
            try await poller.applyTargets(FanControlPoller.targets(from: plan), force: force)
            fanControlModes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, profile.mode(for: $0)) })
            emergencyOverrideActive = emergency
        } catch {
            if let rollback { rollBackSelection(rollback) }
            throw error
        }
    }

    /// Stores (user profiles) and selects `profile` in one `profileStore`
    /// assignment; returns what is needed to undo it.
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

    /// Undoes `selectProfile` after a failed apply.
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

    // MARK: - Timer

    private var effectivePollingInterval: TimeInterval {
        min(max(pollingInterval, 0.5), 300)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard isMonitoring else { return }
        let interval: TimeInterval
        if isPauseInEffect {
            // Slow mode keeps sensor-based modes / the emergency override (session)
            // and the alerts (`keepAlertsWhilePaused`) alive while hidden.
            guard isSMCWriteSessionOpen || keepAlertsWhilePaused else { return }
            interval = max(effectivePollingInterval * 5, 10)
        } else {
            interval = effectivePollingInterval
        }
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.pollIfMonitoring() }
        }
        newTimer.tolerance = interval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Mirrors `helperClient.isSessionOpen`; reschedules the timer when paused
    /// (a session keeps slow polling alive).
    private func syncSessionFlag() {
        let open = helperClient.isSessionOpen
        guard open != isSMCWriteSessionOpen else { return }
        isSMCWriteSessionOpen = open
        if isPauseInEffect { scheduleTimer() }
    }

    // MARK: - Sleep / wake / termination

    private func registerSystemObserversIfNeeded() {
        guard systemObservers.isEmpty else { return }
        // All three observers are delivered on the main queue (`queue: .main`).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        let sleep = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        let terminate = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOnTermination() }
        }
        systemObservers = [(workspaceCenter, wake), (workspaceCenter, sleep),
                           (NotificationCenter.default, terminate)]
    }

    /// Nothing destructive: the helper hands the forced fans back to the SMC
    /// itself (`docs/helper.md` §5). Cancels pending wake attempts and stops
    /// poll-driven writes until wake.
    private func handleWillSleep() {
        cancelWakeWork()
        poller.enqueue { poller in
            poller.systemSleeping = true
            poller.systemSleepStartedAt = Date()
        }
        if helperClient.isSessionOpen {
            kitLog.notice("System will sleep; poll writes suspended (the helper hands the fans back to the SMC)")
        }
    }

    /// Across sleep the SMC resets `F<n>Tg` to 0 but keeps `F<n>Md` = 1
    /// (first-write test 4), so with a session open:
    /// - `reapplyProfileAfterWake == true`: the active profile is re-applied right
    ///   away and again at `wakeReapplyDelays` (bypassing the throttle, never opening
    ///   a session; errors are recorded only for the last attempt, since the SMC may
    ///   reject writes right at wake);
    /// - `false`: the session is closed immediately (the helper restores).
    /// The flag is read when each attempt runs. Polls resume (and flag unsettled
    /// fans) at once.
    private func handleWake() {
        cancelWakeWork()
        poller.enqueue { poller in
            poller.systemSleeping = false
            poller.systemSleepStartedAt = nil
        }
        pollIfMonitoring()
        guard helperClient.isSessionOpen else { return }
        guard reapplyProfileAfterWake else {
            kitLog.notice("Woke with a session open and reapplyProfileAfterWake off: closing the session")
            Task { await self.closeSMCSession() }
            return
        }
        kitLog.notice("Woke with a session open: re-applying the active profile at \(Self.wakeReapplyDelays.map { "\($0)s" }.joined(separator: ", "), privacy: .public)")
        let delays = Self.wakeReapplyDelays
        for (index, delay) in delays.enumerated() {
            let isLast = index == delays.count - 1
            let item = DispatchWorkItem { [weak self] in
                // Executed on the main queue (`asyncAfter` below).
                MainActor.assumeIsolated { self?.reapplyAfterWake(polling: delay > 0, isLast: isLast) }
            }
            wakeWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// One wake re-apply attempt (`handleWake`).
    private func reapplyAfterWake(polling: Bool, isLast: Bool) {
        if polling { pollIfMonitoring() }
        guard helperClient.isSessionOpen else { return }
        guard reapplyProfileAfterWake else {
            Task { await self.closeSMCSession() }
            return
        }
        let profile = resolvedActiveProfile
        Task {
            if isLast {
                try? await self.recordingErrors {
                    try await self.apply(profile, force: true, allowOpeningSession: false, makeActive: false)
                }
            } else {
                try? await self.apply(profile, force: true, allowOpeningSession: false, makeActive: false)
            }
        }
    }

    private func cancelWakeWork() {
        wakeWorkItems.forEach { $0.cancel() }
        wakeWorkItems = []
    }

    /// Returns every fan to automatic and closes the session, waiting at most
    /// 2 s. The detached task never hops to the main actor (whose thread is
    /// blocked here): it only uses the poller and the helper client.
    /// If it does not finish, the helper still restores the original values
    /// when the dying process's connection is invalidated.
    private func restoreOnTermination() {
        guard helperClient.isSessionOpen else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let fans = self.fans
        let helperClient = self.helperClient
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

    // MARK: - Utilities

    private func persistProfileStore() {
        if let data = try? ProfileStore.encodeJSON(profileStore) {
            defaults.set(data, forKey: Self.profileStoreDefaultsKey)
        }
    }

    /// Stores the error in `lastError` and rethrows it.
    private func recordingErrors(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            let fanError = FanControlPoller.fanControlError(from: error)
            if lastError != fanError { lastError = fanError }
            throw error
        }
    }
}

/// Unified logging for the app-side kit.
/// `log stream --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-kit"'`
let kitLog = Logger(subsystem: "com.example.dynamicnotch.DynamicNotch", category: "fancontrol-kit")

/// What `selectProfile` changed, for `rollBackSelection`.
private struct ProfileSelectionRollback: Sendable {
    var previousActiveID: UUID?
    var profileID: UUID
    var isBuiltIn: Bool
    var previousStored: FanProfile?
}
#endif
