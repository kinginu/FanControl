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
    /// Posted (object: `FanControlManager`) when `conflictingControllers` changes.
    /// `userInfo["names"]` is the new `[String]`.
    static let fanControlConflictingControllersChanged = Notification.Name("FanControlConflictingControllersChanged")
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
/// A thin facade (docs/kit.md "Architecture"): it owns the poll snapshot that
/// `FanControlPoller` publishes, the profile store and the safety / tuning
/// settings, and forwards everything else to its components:
/// - `MonitoringService`: monitoring flag, poll timer, effective interval
///   (power source), Nook pause / live-data holds;
/// - `FanController`: apply / session / restore / rollback / termination;
/// - `HelperCoordinator`: install status, connection handshake, session flag,
///   conflicting controllers;
/// - `WakeCoordinator`: sleep / wake re-apply.
///
/// Threading model (docs/kit.md "Threading model"):
/// - The manager and its components are `@MainActor`: every observable property,
///   the timer, the profile store and the pause / wake bookkeeping live on the
///   main actor. Views call its synchronous methods directly and `await` its async
///   ones; off-main callers `await` both. The constants, `clientTeamID`,
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
///   the automatic profile) on smoothed control temperatures, stabilizes the
///   result (`FanTargetStabilizer`: deadband, dwell, slew limit; bypassed by the
///   emergency override and by explicit applies) and writes only targets that
///   moved by more than `writeThresholdRPM`, or mode changes.
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
    public nonisolated static let customProfileID = FanController.customProfileID
    /// Poll-driven target changes at or below this many RPM are not written.
    public nonisolated static let writeThresholdRPM = 25
    /// Seconds after `NSWorkspace.didWakeNotification` at which the active profile
    /// is re-applied while a session is open (`reapplyProfileAfterWake`).
    public nonisolated static let wakeReapplyDelays: [TimeInterval] = WakeCoordinator.defaultReapplyDelays
    /// While monitoring, `conflictingControllers` is re-checked at most this often
    /// from the poll timer (besides app launch / terminate notifications).
    public nonisolated static let conflictCheckInterval: TimeInterval = HelperCoordinator.conflictCheckInterval
    /// Shown when `helperStatus == .requiresApproval` (`installHelper` throws
    /// `.helperNotInstalled` in that case, which carries no message of its own).
    /// English only; an app with its own localized text may show that instead.
    public nonisolated static let helperApprovalInstructions =
        "Allow the DynamicNotch fan control helper in System Settings > General > Login Items & Extensions, then try again."

    // MARK: - Poll snapshot (read-only to views; set on the main actor by `FanControlPoller`)

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
    /// Smoothed control temperature (°C) per sensor key followed by the active
    /// profile's sensor-based modes (`TemperatureSmoother` with `tuning`): what the fan
    /// curve is evaluated at. Raw values stay in `sensorReadings`. Updated every poll.
    public internal(set) var controlTemperatures: [String: Double] = [:]
    /// Recent raw temperatures of `temperatureHistoryKeys` (`TemperatureHistory`),
    /// appended on every published poll.
    public internal(set) var temperatureHistory = TemperatureHistory()
    /// While a write session is open: the active profile's mode per fan.
    /// Otherwise: the mode detected from the SMC (`FanDiscovery.fanControlModes`).
    public internal(set) var fanControlModes: [Int: FanControlMode] = [:]
    public internal(set) var isSMCConnected: Bool = false
    public internal(set) var lastUpdate: Date?
    public internal(set) var lastError: FanControlError?
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

    // MARK: - Monitoring state (`MonitoringService`)

    public var isMonitoring: Bool { monitoring.isMonitoring }
    /// The host's last `setMonitoringPaused` request (Nook hidden). Whether the
    /// slow / stopped polling is actually in effect is `isPauseInEffect`.
    public var isMonitoringPaused: Bool { monitoring.isMonitoringPaused }
    /// `isMonitoringPaused` and no live-data hold (`setLiveDataHold(_:for:)`):
    /// the poll timer runs slowed (or stopped) only while this is `true`.
    public var isPauseInEffect: Bool { monitoring.isPauseInEffect }
    /// `true` while the Mac runs on battery (`PowerSourceProviding`, IOKit
    /// power-source notifications by default). `false` on AC and on desktops.
    public var isOnBattery: Bool { monitoring.isOnBattery }
    /// The interval the poll timer uses while the Nook pause is not in effect
    /// (`PollingIntervalPolicy.effectiveInterval`): `pollingInterval`, or
    /// `max(pollingInterval, batteryPollingInterval)` while `slowPollingOnBattery`
    /// and `isOnBattery`; clamped to 0.5...300 s. The paused low-frequency poll is
    /// `max(5 × effectivePollingInterval, 10 s)`.
    public var effectivePollingInterval: TimeInterval { monitoring.effectivePollingInterval }
    /// Interval of the scheduled poll timer, `nil` when none is scheduled (tests).
    var scheduledTimerInterval: TimeInterval? { monitoring.scheduledTimerInterval }

    // MARK: - Helper state (`HelperCoordinator`)

    public var helperStatus: HelperInstallStatus { helper.helperStatus }
    public var helperConnectionState: HelperConnectionState { helper.helperConnectionState }
    public var isSMCWriteSessionOpen: Bool { helper.isSMCWriteSessionOpen }
    /// Display names of other fan control apps that are running now (e.g. `["FanFi"]`,
    /// design doc §5.2): both writing at once override each other. Refreshed on
    /// `startMonitoring()`, on app launch / terminate notifications and at most every
    /// `conflictCheckInterval` while polling; `refreshConflictingControllers()` forces it.
    /// Changes post `.fanControlConflictingControllersChanged`.
    public var conflictingControllers: [String] { helper.conflictingControllers }
    /// Full result of the last conflict check, including controllers whose helper
    /// is installed while the app is not running (informational).
    public var conflictingControllerStatuses: [ConflictingControllerStatus] { helper.conflictingControllerStatuses }

    // MARK: - Settings

    /// Seconds between polls (effective value clamped to 0.5...300, slowed on
    /// battery: `effectivePollingInterval`). A change of the effective interval
    /// reschedules the timer while monitoring.
    public var pollingInterval: TimeInterval {
        get { monitoring.pollingInterval }
        set { monitoring.pollingInterval = newValue }
    }
    /// When `true` (default), polling slows to `batteryPollingInterval` (if that is
    /// longer than `pollingInterval`) while the Mac runs on battery (design doc
    /// §5.4 (a)). The app mirrors `FanControlGeneralSettings.slowPollingOnBattery` into this.
    public var slowPollingOnBattery: Bool {
        get { monitoring.slowPollingOnBattery }
        set { monitoring.slowPollingOnBattery = newValue }
    }
    /// Poll interval on battery while `slowPollingOnBattery` is on (default 10 s).
    public var batteryPollingInterval: TimeInterval {
        get { monitoring.batteryPollingInterval }
        set { monitoring.batteryPollingInterval = newValue }
    }
    /// Starts as `FanControlPlatform.defaultSafetyPolicy` (= `SafetyPolicy.default`;
    /// the emergency prefixes exclude `TG`, a battery-area sensor on Apple
    /// Silicon; see `SafetyPolicy.defaultEmergencySensorPrefixes`).
    /// Not persisted by the kit.
    public var safetyPolicy: SafetyPolicy = FanControlPlatform.defaultSafetyPolicy
    /// Anti-hunting parameters (input smoothing, deadband, dwell, slew limit;
    /// docs/kit.md "Control loop"). Read by the next poll. Not persisted by the kit.
    public var tuning: FanControlTuning = .default

    /// Copies user-set thresholds (clamped by `ThresholdBounds`) into
    /// `safetyPolicy`, keeping `emergencySensorPrefixes` and
    /// `enforceHardwareMinimum`. Assigns only on a change; the next poll
    /// evaluates the alert and the emergency latch against the new values
    /// (design doc §5.6). The app calls this when its threshold setting changes.
    public func applySafetyThresholds(_ thresholds: SafetyThresholds) {
        let clamped = ThresholdBounds.clamped(thresholds)
        guard safetyPolicy.thresholds != clamped else { return }
        safetyPolicy.thresholds = clamped
    }
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
    public var reapplyProfileAfterWake: Bool {
        get { wake.reapplyProfileAfterWake }
        set { wake.reapplyProfileAfterWake = newValue }
    }
    /// When `true` (default), `setMonitoringPaused(true)` without a write session
    /// keeps a slow poll (`max(5 × pollingInterval, 10 s)`, the same rate as with
    /// a session) so the high-temperature and fan-anomaly alerts still fire while
    /// the Nook is hidden. When `false`, polling stops while paused unless a
    /// session is open. The app mirrors "any alert enabled" into this.
    public var keepAlertsWhilePaused: Bool {
        get { monitoring.keepAlertsWhilePaused }
        set { monitoring.keepAlertsWhilePaused = newValue }
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

    /// The smoothed control temperature of `key` (`controlTemperatures`), falling back
    /// to its raw reading when the key is not followed by the active profile.
    public func controlTemperature(for key: String) -> Double? {
        controlTemperatures[key] ?? sensorReadings.first { $0.id == key && $0.temperature.isFinite }?.temperature
    }

    /// Keys recorded into `temperatureHistory`: `TemperatureHistory.defaultKeys` plus
    /// every key requested with `setTemperatureHistoryKeys(_:for:)`.
    public var temperatureHistoryKeys: Set<String> {
        historyKeyRequests.values.reduce(into: Set(TemperatureHistory.defaultKeys)) { $0.formUnion($1) }
    }

    /// A view that charts temperatures requests its keys while visible (`[]` releases),
    /// under a name unique to the view. Keys no longer requested (and not default) are
    /// dropped from `temperatureHistory`.
    public func setTemperatureHistoryKeys(_ keys: Set<String>, for holder: String) {
        historyKeyRequests[holder] = keys.isEmpty ? nil : keys
        temperatureHistory.retainOnly(temperatureHistoryKeys)
    }

    /// Poller publication (main actor).
    func recordTemperatureHistory(_ sensors: [SensorReading], at date: Date) {
        temperatureHistory.record(sensors, keys: temperatureHistoryKeys, at: date)
    }

    /// Hottest CPU/GPU sensor (per `safetyPolicy.emergencySensorPrefixes`),
    /// falling back to the hottest sensor overall, skipping keys excluded from
    /// ranking (`SensorCatalog.isExcludedFromRanking(_:)`, e.g. `Tf*`).
    public var hottestSensor: SensorReading? {
        FanControlEngine.hottestEmergencySensor(sensorReadings, policy: safetyPolicy)
            ?? sensorReadings
                .filter { $0.temperature.isFinite && !$0.isExcludedFromRanking }
                .max { $0.temperature < $1.temperature }
    }

    // MARK: - Components and private state

    /// Poll loop driver: monitoring flag, timer, effective interval, pause / holds.
    @ObservationIgnored let monitoring: MonitoringService
    /// Apply / session / restore / rollback / termination.
    @ObservationIgnored let controller: FanController
    /// Install status, handshake, session flag, conflicting controllers.
    @ObservationIgnored let helper: HelperCoordinator
    /// Sleep / wake re-apply.
    @ObservationIgnored let wake: WakeCoordinator
    // F1: charge limit (CHWA); not part of the fan session (docs/kit.md "Charge limit").
    /// "Limit charging to 80 %" (`ChargeLimitController`, itself `@Observable`).
    @ObservationIgnored public let chargeLimit: ChargeLimitController
    /// `setTemperatureHistoryKeys` requests per holder.
    @ObservationIgnored private var historyKeyRequests: [String: Set<String>] = [:]
    @ObservationIgnored private nonisolated let helperClient: HelperClient
    /// Owns the poll queue and all poll state (SMC reader, fans, alert latch,
    /// sample filter, write strategy, throttle baseline, apply generation).
    @ObservationIgnored private nonisolated let poller: FanControlPoller
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Init

    /// Cheap: no SMC or XPC I/O (only the profile store is read from UserDefaults
    /// and the power source from IOKit).
    /// On a non-Apple-Silicon Mac this logs an error; every later SMC open then
    /// fails with `FanControlError.unsupportedPlatform` (Intel dropped 2026-10-20).
    ///
    /// - `powerSource`: `nil` (default) uses `PowerSourceMonitor` (IOKit).
    /// - `conflictDetector`: finds other fan control apps (`conflictingControllers`).
    public init(defaults: UserDefaults = .standard,
                helperClient: HelperClient = HelperClient(),
                installer: HelperInstaller = HelperInstaller(),
                powerSource: (any PowerSourceProviding)? = nil,
                conflictDetector: ConflictingControllerDetector = ConflictingControllerDetector()) {
        self.defaults = defaults
        self.helperClient = helperClient
        let poller = FanControlPoller(helperClient: helperClient)
        self.poller = poller
        let helper = HelperCoordinator(client: helperClient, installer: installer, conflictDetector: conflictDetector)
        self.helper = helper
        let monitoring = MonitoringService(poller: poller, powerSource: powerSource ?? PowerSourceMonitor())
        self.monitoring = monitoring
        self.wake = WakeCoordinator()
        self.controller = FanController(poller: poller, helper: helper)
        self.chargeLimit = ChargeLimitController(helper: helper)  // F1
        if let data = defaults.data(forKey: Self.profileStoreDefaultsKey),
           let store = try? ProfileStore.decodeJSON(data) {
            self.profileStore = store
        } else {
            self.profileStore = ProfileStore()
        }
        if !FanControlPlatform.isSupported {
            kitLog.error("Fan control disabled: \(FanControlPlatform.unsupportedPlatformDetail, privacy: .public)")
        }
        // Wiring (all hooks run on the main actor).
        let recorder = ErrorRecorder { [weak self] error in self?.record(error) }
        helper.recordErrors = recorder
        controller.recordErrors = recorder
        controller.host = self
        wake.host = self
        helper.onSessionFlagChange = { [weak monitoring] in monitoring?.sessionStateDidChange() }
        helper.onConflictingControllersChange = { [weak self] names in
            guard let self else { return }
            NotificationCenter.default.post(name: .fanControlConflictingControllersChanged, object: self,
                                            userInfo: ["names": names])
        }
        monitoring.isSessionOpen = { [weak helper] in helper?.isSMCWriteSessionOpen ?? false }
        monitoring.beforePoll = { [weak helper] in helper?.refreshConflictingControllersIfDue() }
        monitoring.poll = { [weak self] in self?.refreshNow() }
        // First job on the poll queue: every later poll can publish.
        poller.enqueue { [weak self] poller in
            if let self { poller.attach(self) }
        }
    }

    // MARK: - Lifecycle

    /// Opens the SMC, discovers fans and sensors once, then polls every `pollingInterval`.
    public func startMonitoring() {
        guard monitoring.markStarted() else { return }
        registerSystemObserversIfNeeded()
        refreshConflictingControllers()
        monitoring.scheduleTimer()
        refreshNow()
    }

    /// Stops polling and closes the SMC reader. Cancels a pending wake re-apply
    /// and drops polls that were queued while monitoring (they do not reopen the
    /// reader). Does not close a write session: call `restoreDefaultControl()`
    /// first if fans should return to automatic.
    public func stopMonitoring() {
        guard monitoring.stop() else { return }
        wake.cancelPendingWork()
        isSMCConnected = false
    }

    /// Polls once immediately. Also works when not monitoring: the SMC is then
    /// opened for this one poll and closed again (unless a write session is open).
    /// A refresh requested while monitoring that is still queued when
    /// `stopMonitoring()` runs is dropped.
    public func refreshNow() {
        let context = PollContext(profile: resolvedActiveProfile, policy: safetyPolicy, tuning: tuning,
                                  sessionOpen: helperClient.isSessionOpen,
                                  requiresMonitoring: isMonitoring)
        poller.enqueue { $0.poll(context) }
    }

    /// Re-runs the conflict check (`conflictingControllers`,
    /// `conflictingControllerStatuses`). Cheap: `NSRunningApplication` and `stat`.
    public func refreshConflictingControllers() {
        helper.refreshConflictingControllers()
    }

    /// Call with `true` when the Nook is hidden and `false` when it is shown
    /// (design doc §5.4; the host drives it from its Nook visibility, PATCHES.md (b)).
    /// While the pause is in effect (`isPauseInEffect`: paused and no live-data
    /// hold) polling slows down to `max(5 × pollingInterval, 10 s)` while a write
    /// session is open (so sensor-based modes and the emergency override keep
    /// working) or while `keepAlertsWhilePaused` is `true` (so alerts keep
    /// firing); otherwise it stops.
    public func setMonitoringPaused(_ paused: Bool) {
        monitoring.setPaused(paused)
    }

    /// A view that shows live data regardless of the Nook (the settings pane)
    /// holds it while visible: `true` on appear, `false` on disappear, with a
    /// name unique to the view. While any hold exists the Nook pause is not in
    /// effect (normal polling) and `isMonitoringPaused` keeps the host's request,
    /// so releasing the last hold returns to the paused rate without the view
    /// having to remember or restore the previous pause state.
    public func setLiveDataHold(_ held: Bool, for holder: String) {
        monitoring.setLiveDataHold(held, for: holder)
    }

    // MARK: - Control (`FanController`)

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
        try await controller.setFanControlMode(fanIndex: fanIndex, mode: mode)
    }

    /// Makes fan `fanIndex` follow `sensorKey` on `curve` (multi-point; see `FanCurve`),
    /// editing the active profile like `setFanControlMode` (built-in → "Custom").
    /// The curve's RPMs are clamped to the fan's range when evaluated (no range error).
    public func setFanCurve(fanIndex: Int, sensorKey: String, curve: FanCurve) async throws {
        try await controller.setFanCurve(fanIndex: fanIndex, sensorKey: sensorKey, curve: curve)
    }

    /// The profile `setFanControlMode` applies (`FanController.profile(changing:fanIndex:to:fans:)`).
    nonisolated static func profile(changing base: FanProfile, fanIndex: Int, to mode: FanControlMode,
                                    fans: [FanDevice]) -> FanProfile {
        FanController.profile(changing: base, fanIndex: fanIndex, to: mode, fans: fans)
    }

    /// Applies `profile` (writing immediately, bypassing the throttle) and makes
    /// it active. Profiles with manual modes start monitoring if it is stopped
    /// and open the write session first. The profile is stored (user profiles)
    /// and selected *before* the writes; if writing fails, the previous
    /// selection and stored version are restored.
    public func applyProfile(_ profile: FanProfile) async throws {
        try await controller.applyProfile(profile)
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
        try await controller.openSession()
    }

    /// Closes the write session after pending writes. The helper restores the
    /// original value of every key written during the session. Poll batches
    /// still queued are dropped (apply generation bump).
    public func closeSMCSession() async {
        await controller.closeSession()
    }

    /// Activates the Automatic profile, returns every fan to automatic and closes the session.
    ///
    /// If no session is open but the SMC reports a fan in manual mode (e.g. the
    /// helper crashed or was killed mid-session, so it could not restore; or
    /// another tool forced the fan), this explicit user action opens a session
    /// just to write automatic and closes it again.
    public func restoreDefaultControl() async throws {
        try await controller.restoreDefaultControl()
    }

    // MARK: - Helper (`HelperCoordinator`)

    /// Registers the helper daemon (no-op for a manual installation, see
    /// `HelperInstaller.register()`). If the user still has to approve it, opens
    /// System Settings > General > Login Items & Extensions and throws
    /// `.helperNotInstalled` (show `helperApprovalInstructions`).
    public func installHelper() async throws {
        try await helper.install()
    }

    /// User action ("Check Again"): forgets a sticky helper rejection and the
    /// connection backoff (`HelperClient.resetRejection()`), re-reads `helperStatus`
    /// and, if the helper is installed, probes it once with the read-only
    /// `version()` call so `helperConnectionState` shows whether it accepts this app
    /// now. The only place besides install / apply / restore that connects to the
    /// helper. A manual installation pinned to another build is reported again
    /// without connecting. Throws (and records) the probe's error.
    public func retryHelperConnection() async throws {
        try await helper.retryConnection()
    }

    /// Re-reads the install status (manual installation or `SMAppService`) into
    /// `helperStatus`. File / `SMAppService` reads only; never connects to the helper.
    public func refreshHelperStatus() {
        helper.refreshStatus()
    }

    // MARK: - Errors and diagnostics

    /// Clears `lastError` (e.g. when the user dismisses it). The manager never
    /// clears it on its own; a later failure sets it again.
    public func clearLastError() {
        lastError = nil
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

    // MARK: - Internal

    var resolvedActiveProfile: FanProfile {
        guard let id = profileStore.activeProfileID else { return .automatic() }
        return availableProfiles.first { $0.id == id } ?? .automatic()
    }

    /// Sleep / wake (`WakeCoordinator`), termination (`FanController`) and
    /// app launch / terminate (`HelperCoordinator`) observers. Idempotent.
    func registerSystemObserversIfNeeded() {
        wake.registerObserversIfNeeded()
        controller.registerObserversIfNeeded()
        helper.registerObserversIfNeeded()
    }

    /// `ErrorRecorder` target: stores the error in `lastError` (only on a change).
    private func record(_ error: FanControlError) {
        if lastError != error { lastError = error }
    }

    private func persistProfileStore() {
        if let data = try? ProfileStore.encodeJSON(profileStore) {
            defaults.set(data, forKey: Self.profileStoreDefaultsKey)
        }
    }
}

// MARK: - Component hosts

extension FanControlManager: FanControllerHost {
    func fanControllerDidApply(modes: [Int: FanControlMode], emergencyOverride: Bool) {
        fanControlModes = modes
        emergencyOverrideActive = emergencyOverride
    }
}

extension FanControlManager: WakeCoordinatorHost {
    var isSessionOpen: Bool { helperClient.isSessionOpen }

    func pollIfMonitoring() {
        monitoring.pollIfMonitoring()
    }

    func setSystemSleeping(_ sleeping: Bool) {
        poller.enqueue { poller in
            poller.systemSleeping = sleeping
            poller.systemSleepStartedAt = sleeping ? Date() : nil
        }
    }

    func closeSessionAfterWake() {
        controller.closeSessionInBackground()
    }

    func reapplyActiveProfileAfterWake(recordingErrors: Bool) {
        controller.reapplyActiveProfile(recordingErrors: recordingErrors)
    }
}

/// Unified logging for the app-side kit. The subsystem is the configured client bundle id
/// (`FanControlIdentifiers.clientBundleIdentifier`, DynamicNotch: "com.example.dynamicnotch.DynamicNotch"),
/// the same subsystem the helper logs under.
/// `/usr/bin/log stream --predicate 'subsystem == "<client bundle id>" AND category == "fancontrol-kit"'`
let kitLog = Logger(subsystem: FanControlHelperConstants.appBundleIdentifier, category: "fancontrol-kit")
#endif
