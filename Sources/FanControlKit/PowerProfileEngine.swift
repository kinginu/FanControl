#if os(macOS)
import Foundation
import Observation
import FanControlCore
import FanControlXPC

// F2: Power profiles (DynamicNotchApp/docs/power-profiles.md). Evaluates the user's rules
// against the live `PowerContext` (first match wins) and
// - claims the rule's fan profile on the `.power` layer of `FanProfileArbiter`
//   (manual > emergency > workload > power > default);
// - sets Low Power Mode through the helper when the rule asks for on / off, and puts it
//   back to the user's own value once no rule asks for it any more.

/// Evaluates power-profile rules and drives the fan profile and Low Power Mode.
///
/// Acts on **transitions** only: while the matching rule and its targets stay the same,
/// nothing is written again, so a manual fan pick or a manual Low Power Mode toggle is not
/// fought on every tick.
///
/// Low Power Mode bookkeeping (`LowPowerModeMemory`, persisted so a relaunch does not lose
/// it): before the engine changes it the first time, the user's settings are remembered
/// **per power source** (`pmset -g custom`: battery and AC, so "Only on Battery" survives);
/// the engine itself sets every source (`-a`). When the matching rule no longer asks for a
/// value (no match, "Don't Change", or Power Profiles turned off), the remembered values are
/// written back (`-b` / `-c`, or `-a` when equal) — unless the user changed Low Power Mode
/// in the meantime (the settings are no longer what the engine set), then theirs are kept.
/// The memory is dropped only once the restore succeeded (or is moot), so a failed restore
/// is retried, also after a relaunch: the first evaluation after launch always syncs. A
/// failed change is retried too while its rule keeps matching, at most every
/// `lowPowerModeRetryInterval`.
@MainActor
@Observable
public final class PowerProfileEngine {

    /// UserDefaults key of the JSON `PowerProfileConfiguration`.
    public nonisolated static let defaultsKey = "fanControl.powerProfiles"
    /// UserDefaults key of the JSON `LowPowerModeMemory`.
    public nonisolated static let lowPowerModeMemoryKey = "fanControl.powerProfiles.lowPowerModeMemory"

    public static let shared = PowerProfileEngine(
        defaults: .standard,
        contextProvider: SystemPowerContextProvider(),
        lowPowerMode: HelperLowPowerModeController(manager: .shared),
        arbiter: .shared)

    /// Persisted on every change; re-evaluated while running.
    public var configuration: PowerProfileConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            persistConfiguration()
            if isRunning { requestEvaluation() }
        }
    }

    public private(set) var isRunning = false
    /// Context of the last evaluation.
    public private(set) var context: PowerContext?
    /// The rule that matched in the last evaluation (`nil` = none, or Power Profiles off).
    public private(set) var matchedRule: PowerProfileRule?
    /// Low Power Mode read back in the last evaluation (`nil` = unknown).
    public private(set) var isLowPowerModeEnabled: Bool?
    /// English message of the last failed Low Power Mode change (cleared by a success).
    public private(set) var lowPowerModeError: String?
    public private(set) var lastEvaluation: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let contextProvider: any PowerContextProviding
    @ObservationIgnored private let lowPowerMode: any LowPowerModeControlling
    @ObservationIgnored public let arbiter: FanProfileArbiter
    @ObservationIgnored private let calendar: Calendar
    /// The Low Power Mode value the current rule asks for (`nil` = none). Changes of this
    /// value are the Low Power Mode transitions.
    @ObservationIgnored private var lowPowerModeTarget: Bool?
    /// `true` once the work for `lowPowerModeTarget` is done (written, already as wanted,
    /// restored, or moot). `false` at launch (persisted memory may need a restore) and after
    /// a failed write, so the next evaluation tries again.
    @ObservationIgnored private var lowPowerModeSettled = false
    /// No retry of an unsettled target before this time (context clock).
    @ObservationIgnored private var lowPowerModeRetryAfter: Date?
    @ObservationIgnored private var hasEvaluated = false
    @ObservationIgnored private var memory: LowPowerModeMemory? {
        didSet { persistMemory() }
    }
    /// The last scheduled evaluation (evaluations are chained, never concurrent).
    @ObservationIgnored private var pendingEvaluation: Task<Void, Never>?

    public init(defaults: UserDefaults,
                contextProvider: any PowerContextProviding,
                lowPowerMode: any LowPowerModeControlling,
                arbiter: FanProfileArbiter,
                calendar: Calendar = .current) {
        self.defaults = defaults
        self.contextProvider = contextProvider
        self.lowPowerMode = lowPowerMode
        self.arbiter = arbiter
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? PowerProfileConfiguration.decodeJSON(data) {
            configuration = stored
        } else {
            configuration = PowerProfileConfiguration()
        }
        if let data = defaults.data(forKey: Self.lowPowerModeMemoryKey) {
            memory = try? JSONDecoder().decode(LowPowerModeMemory.self, from: data)
        }
    }

    // MARK: Lifecycle

    /// Starts observing the context (power source, lid, wake, tick) and the active fan
    /// profile, and evaluates once. Idempotent. Cheap when Power Profiles are off.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        arbiter.startObservingHost()
        contextProvider.startObserving { [weak self] in self?.requestEvaluation() }
        requestEvaluation()
    }

    /// Stops observing, withdraws the fan claim and restores Low Power Mode (as if no rule matched).
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        contextProvider.stopObserving()
        await evaluate()
    }

    /// Re-evaluates soon (after any evaluation in progress).
    public func requestEvaluation() {
        scheduleEvaluation()
    }

    /// Evaluates the rules now and returns when done. Evaluations never overlap: each one
    /// runs after the previous request's.
    public func evaluate() async {
        await scheduleEvaluation().value
    }

    @discardableResult
    private func scheduleEvaluation() -> Task<Void, Never> {
        let previous = pendingEvaluation
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let context = self.contextProvider.currentContext()
            let rule = self.isRunning ? self.configuration.firstMatch(in: context, calendar: self.calendar) : nil
            await self.apply(rule: rule, context: context)
        }
        pendingEvaluation = task
        return task
    }

    /// Ends a manual fan-profile override (status line "Resume").
    public func resumeAutomation() async {
        await arbiter.resumeAutomation()
    }

    // MARK: Applying

    private func apply(rule: PowerProfileRule?, context: PowerContext) async {
        self.context = context
        lastEvaluation = context.date
        let previous = matchedRule
        matchedRule = rule
        isLowPowerModeEnabled = lowPowerMode.isLowPowerModeEnabled
        if !hasEvaluated || previous?.id != rule?.id {
            hasEvaluated = true
            kitLog.notice("Power profile rule: \(rule?.name ?? "none", privacy: .public)")
        }

        let claim = rule.flatMap { rule in
            rule.fanProfileID.map { ProfileClaim(profileID: $0, reason: rule.name) }
        }
        await arbiter.setClaim(claim, for: .power)

        await syncLowPowerMode(target: rule?.lowPowerMode.requestedState, now: context.date)
    }

    /// Minimum time between retries of a failed Low Power Mode change or restore.
    nonisolated static let lowPowerModeRetryInterval: TimeInterval = 60

    private func syncLowPowerMode(target: Bool?, now: Date) async {
        if target == lowPowerModeTarget {
            guard !lowPowerModeSettled else { return }
            if let retryAfter = lowPowerModeRetryAfter, now < retryAfter { return }
        }
        lowPowerModeTarget = target
        let settled = if let target {
            await changeLowPowerMode(to: target)
        } else {
            await restoreLowPowerMode()
        }
        // The target may have moved on while awaiting the helper; only record this one.
        guard lowPowerModeTarget == target else { return }
        lowPowerModeSettled = settled
        lowPowerModeRetryAfter = settled ? nil : now.addingTimeInterval(Self.lowPowerModeRetryInterval)
    }

    /// A rule asks for `target`. Returns `false` if the write failed (retry later).
    private func changeLowPowerMode(to target: Bool) async -> Bool {
        let current = lowPowerMode.isLowPowerModeEnabled
        guard current != target else { return true }  // already as wanted: nothing to remember
        let isFirstChange = memory == nil
        if isFirstChange {
            let settings = await lowPowerMode.readLowPowerModeSettings()
            memory = LowPowerModeMemory(restoreValue: current ?? !target,
                                        restoreBattery: settings?.battery, restoreAC: settings?.ac,
                                        valueSetByEngine: target)
        }
        if await setLowPowerMode(battery: target, ac: target) {
            memory?.valueSetByEngine = target
            return true
        }
        if isFirstChange { memory = nil }  // nothing was changed, so there is nothing to give back
        return false
    }

    /// No rule asks for a value: give the user's settings back, if the engine changed them.
    /// Returns `false` if the restore write failed (the memory is kept: retry later).
    private func restoreLowPowerMode() async -> Bool {
        guard let memory else { return true }
        let current = lowPowerMode.isLowPowerModeEnabled
        let settings = await lowPowerMode.readLowPowerModeSettings()
        let set = memory.valueSetByEngine
        let changedByUser = if let settings {
            !settings.matches(battery: set, ac: set)
        } else {
            current.map { $0 != set } ?? false
        }
        if changedByUser {
            kitLog.notice("Low Power Mode was changed by the user; not restoring it")
            self.memory = nil
            return true
        }
        let (battery, ac) = memory.restorePair
        let alreadyRestored = if let settings {
            settings.matches(battery: battery, ac: ac)
        } else {
            battery == ac && current == battery
        }
        guard !alreadyRestored else {
            self.memory = nil
            return true
        }
        guard await setLowPowerMode(battery: battery, ac: ac) else { return false }
        self.memory = nil
        return true
    }

    private func setLowPowerMode(battery: Bool, ac: Bool) async -> Bool {
        do {
            try await lowPowerMode.setLowPowerMode(battery: battery, ac: ac)
            lowPowerModeError = nil
            isLowPowerModeEnabled = lowPowerMode.isLowPowerModeEnabled ?? (battery == ac ? battery : nil)
            return true
        } catch {
            lowPowerModeError = error.localizedDescription
            let wanted = LowPowerModeCommand.describe(battery: battery, ac: ac)
            kitLog.error("Low Power Mode \(wanted, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Status

    /// What the engine is doing, for status lines (`nil` while Power Profiles are off).
    public var status: PowerProfileStatus? {
        guard configuration.isEnabled, isRunning else { return nil }
        let decision = arbiter.decision
        return PowerProfileStatus(
            ruleName: matchedRule?.name,
            fanProfileID: matchedRule?.fanProfileID,
            lowPowerMode: matchedRule?.lowPowerMode ?? .unchanged,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            isManualOverride: arbiter.arbitration.isManualOverrideActive,
            winningLayer: decision?.layer,
            error: arbiter.lastError ?? lowPowerModeError)
    }

    // MARK: Persistence

    private func persistConfiguration() {
        guard let data = try? PowerProfileConfiguration.encodeJSON(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func persistMemory() {
        if let memory, let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: Self.lowPowerModeMemoryKey)
        } else {
            defaults.removeObject(forKey: Self.lowPowerModeMemoryKey)
        }
    }

    /// Test hook: the remembered Low Power Mode value to restore (`nil` = nothing to restore).
    var lowPowerModeRestoreValue: Bool? { memory?.restoreValue }
    /// Test hook: the remembered per-source values `[battery, AC]` to restore.
    var lowPowerModeRestorePair: [Bool]? { memory.map { [$0.restorePair.battery, $0.restorePair.ac] } }
}

/// Low Power Mode settings to give back once no rule asks for a value.
struct LowPowerModeMemory: Codable, Hashable, Sendable {
    /// The in-use value before the engine changed it (fallback when the per-source values
    /// could not be read; also what a memory persisted by an older build holds).
    var restoreValue: Bool
    /// The battery / AC values before the engine changed them (`pmset -g custom`); `nil` =
    /// unknown (no battery, unreadable, or persisted by an older build).
    var restoreBattery: Bool?
    var restoreAC: Bool?
    /// What the engine set last, for every source (if the settings differ, the user changed
    /// them: keep theirs).
    var valueSetByEngine: Bool

    /// The (battery, AC) values to write back. A source without a remembered value takes the
    /// other one's (a Mac without a battery), else `restoreValue`.
    var restorePair: (battery: Bool, ac: Bool) {
        (restoreBattery ?? restoreAC ?? restoreValue, restoreAC ?? restoreBattery ?? restoreValue)
    }
}

/// Snapshot for the Fan widget's status line and the settings pane.
public struct PowerProfileStatus: Hashable, Sendable {
    /// The matching rule, `nil` when none matches.
    public var ruleName: String?
    public var fanProfileID: UUID?
    public var lowPowerMode: LowPowerModeAction
    public var isLowPowerModeEnabled: Bool?
    /// The user picked a fan profile by hand; it wins until the next transition or "Resume".
    public var isManualOverride: Bool
    /// The layer whose profile is in effect (`.workload` when F3 outranks power).
    public var winningLayer: ProfileLayer?
    public var error: String?
}
#endif
