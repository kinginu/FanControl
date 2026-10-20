#if os(macOS)
import Foundation
import Observation
import FanControlCore

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
/// it): before the engine changes it the first time, the current value is remembered; when
/// the matching rule no longer asks for a value (no match, "Don't Change", or Power Profiles
/// turned off), the remembered value is written back — unless the user changed Low Power
/// Mode in the meantime (the state is no longer what the engine set), then theirs is kept.
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
    /// value are the only Low Power Mode transitions.
    @ObservationIgnored private var lowPowerModeTarget: Bool?
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

        await syncLowPowerMode(target: rule?.lowPowerMode.requestedState)
    }

    private func syncLowPowerMode(target: Bool?) async {
        guard target != lowPowerModeTarget else { return }
        lowPowerModeTarget = target
        let current = lowPowerMode.isLowPowerModeEnabled

        if let target {
            guard current != target else { return }  // already as wanted: nothing to remember
            let isFirstChange = memory == nil
            if isFirstChange {
                memory = LowPowerModeMemory(restoreValue: current ?? !target, valueSetByEngine: target)
            }
            if await setLowPowerMode(target) {
                memory?.valueSetByEngine = target
            } else if isFirstChange {
                memory = nil  // nothing was changed, so there is nothing to give back
            }
            return
        }

        // No rule asks for a value: give the user's value back, if the engine changed it.
        guard let memory else { return }
        self.memory = nil
        if let current, current != memory.valueSetByEngine {
            kitLog.notice("Low Power Mode was changed by the user; not restoring it")
            return
        }
        guard current != memory.restoreValue else { return }
        await setLowPowerMode(memory.restoreValue)
    }

    @discardableResult
    private func setLowPowerMode(_ enabled: Bool) async -> Bool {
        do {
            try await lowPowerMode.setLowPowerMode(enabled)
            lowPowerModeError = nil
            isLowPowerModeEnabled = lowPowerMode.isLowPowerModeEnabled ?? enabled
            return true
        } catch {
            lowPowerModeError = error.localizedDescription
            kitLog.error("Low Power Mode \(enabled ? "on" : "off", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
}

/// Low Power Mode value to give back once no rule asks for one.
struct LowPowerModeMemory: Codable, Hashable, Sendable {
    /// The value before the engine changed it.
    var restoreValue: Bool
    /// What the engine set last (if the state differs, the user changed it: keep theirs).
    var valueSetByEngine: Bool
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
