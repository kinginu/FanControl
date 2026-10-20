import Foundation
import FanControlCore

// Workload-linked profile switching (feature F3): pure rules + state machine.
//
// The host feeds `WorkloadProfileEngine.update(_:at:)` with a snapshot of the
// running / frontmost apps, the CPU / GPU load and the active profile, and applies
// the profile the decision names. No timers, no AppKit, no I/O: time is passed in,
// so every transition is unit-tested (WorkloadProfileEngineTests).

/// Precedence of everything that can choose the active fan profile (docs/kit.md
/// "Workload automation"), highest first:
///
/// 1. **Manual** — the user picks a profile by hand (`noteManualSelection`). The
///    choice is never replaced: automation pauses (`manualOverrideMinutes`, or until
///    resumed / re-enabled) and does not return to a "previous" profile afterwards.
/// 2. **Emergency** — while the emergency override is active the engine holds (no
///    switch either way). The override itself is a safety floor in the poll loop
///    that forces every fan to max under *any* profile, the manual one included.
/// 3. **Workload** — this engine: app rules (list order), then the sustained-load rule.
/// 4. **Power** (feature F2) — a lower layer only *proposes*: while a workload rule is
///    engaged its choice becomes the profile to return to (`noteLowerLayerSelection`).
/// 5. **Default** — the profile that was active when automation engaged
///    (return-to-previous), else whatever the user last chose.
public enum WorkloadProfilePrecedence {}

// MARK: - Settings

/// One app rule: while the app is running (or frontmost), `profileID` is wanted.
public struct WorkloadAppRule: Codable, Hashable, Sendable, Identifiable {

    public enum Trigger: String, Codable, CaseIterable, Sendable {
        /// The app has a running process.
        case running
        /// The app is the frontmost (active) app.
        case frontmost
    }

    public var id: UUID
    public var bundleIdentifier: String
    /// Name shown in the UI and in the indicator ("Auto: Boost (Xcode)").
    public var displayName: String
    public var trigger: Trigger
    public var profileID: UUID
    public var isEnabled: Bool

    public init(id: UUID = UUID(), bundleIdentifier: String, displayName: String,
                trigger: Trigger = .running, profileID: UUID = FanProfile.BuiltInID.boost,
                isEnabled: Bool = true) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.trigger = trigger
        self.profileID = profileID
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey { case id, bundleIdentifier, displayName, trigger, profileID, isEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? bundleIdentifier
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? .running
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID) ?? FanProfile.BuiltInID.boost
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// The sustained-load rule: above `highThreshold` % for `highDuration` s engages
/// `profileID`; it releases after `lowDuration` s below `lowThreshold` %. Between the
/// two thresholds the current state holds (hysteresis).
public struct WorkloadLoadRule: Codable, Hashable, Sendable {

    public enum Metric: String, Codable, CaseIterable, Sendable {
        case cpu
        case gpu
        /// The higher of the CPU and GPU load.
        case either
    }

    public var isEnabled: Bool
    public var metric: Metric
    public var profileID: UUID
    /// Percent (0–100).
    public var highThreshold: Double
    /// Seconds the load must stay above `highThreshold`.
    public var highDuration: TimeInterval
    /// Percent (0–100), at most `highThreshold`.
    public var lowThreshold: Double
    /// Seconds the load must stay below `lowThreshold`.
    public var lowDuration: TimeInterval

    public init(isEnabled: Bool = false, metric: Metric = .cpu, profileID: UUID = FanProfile.BuiltInID.boost,
                highThreshold: Double = 70, highDuration: TimeInterval = 20,
                lowThreshold: Double = 40, lowDuration: TimeInterval = 60) {
        self.isEnabled = isEnabled
        self.metric = metric
        self.profileID = profileID
        self.highThreshold = highThreshold
        self.highDuration = highDuration
        self.lowThreshold = lowThreshold
        self.lowDuration = lowDuration
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, metric, profileID, highThreshold, highDuration, lowThreshold, lowDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkloadLoadRule()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        metric = (try? c.decodeIfPresent(Metric.self, forKey: .metric)) ?? d.metric
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID) ?? d.profileID
        highThreshold = try c.decodeIfPresent(Double.self, forKey: .highThreshold) ?? d.highThreshold
        highDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .highDuration) ?? d.highDuration
        lowThreshold = try c.decodeIfPresent(Double.self, forKey: .lowThreshold) ?? d.lowThreshold
        lowDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .lowDuration) ?? d.lowDuration
    }
}

/// Everything the user configures for workload automation (persisted by the host as JSON).
public struct WorkloadAutomationSettings: Codable, Hashable, Sendable {

    /// Choices offered for `manualOverrideMinutes` (0 = until resumed).
    public static let manualOverrideChoices: [Int] = [15, 30, 60, 120, 0]

    public var isEnabled: Bool
    /// Checked in order; the first matching rule wins. App rules outrank the load rule.
    public var appRules: [WorkloadAppRule]
    public var loadRule: WorkloadLoadRule
    /// Seconds an app rule stays matched after its app quits or loses focus (hysteresis).
    public var appReleaseDelay: TimeInterval
    /// How long a manual profile choice pauses automation, in minutes; 0 = until resumed
    /// (or automation is turned off and on again).
    public var manualOverrideMinutes: Int

    public init(isEnabled: Bool = false, appRules: [WorkloadAppRule] = [],
                loadRule: WorkloadLoadRule = WorkloadLoadRule(), appReleaseDelay: TimeInterval = 10,
                manualOverrideMinutes: Int = 30) {
        self.isEnabled = isEnabled
        self.appRules = appRules
        self.loadRule = loadRule
        self.appReleaseDelay = appReleaseDelay
        self.manualOverrideMinutes = manualOverrideMinutes
    }

    /// Values clamped to sane ranges: thresholds 0–100 with low ≤ high, durations 0–3600 s,
    /// release delay 0–600 s, override 0–1440 min. Non-finite values fall back to the defaults.
    public func sanitized() -> WorkloadAutomationSettings {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? Swift.min(Swift.max(value, range.lowerBound), range.upperBound) : fallback
        }
        let d = WorkloadLoadRule()
        var result = self
        result.loadRule.highThreshold = clamp(loadRule.highThreshold, 1...100, d.highThreshold)
        result.loadRule.lowThreshold = Swift.min(clamp(loadRule.lowThreshold, 0...100, d.lowThreshold),
                                                 result.loadRule.highThreshold)
        result.loadRule.highDuration = clamp(loadRule.highDuration, 0...3600, d.highDuration)
        result.loadRule.lowDuration = clamp(loadRule.lowDuration, 0...3600, d.lowDuration)
        result.appReleaseDelay = clamp(appReleaseDelay, 0...600, 10)
        result.manualOverrideMinutes = Swift.min(Swift.max(manualOverrideMinutes, 0), 1440)
        return result
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, appRules, loadRule, appReleaseDelay, manualOverrideMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkloadAutomationSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        appRules = (try? c.decodeIfPresent([WorkloadAppRule].self, forKey: .appRules)) ?? d.appRules
        loadRule = (try? c.decodeIfPresent(WorkloadLoadRule.self, forKey: .loadRule)) ?? d.loadRule
        appReleaseDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .appReleaseDelay) ?? d.appReleaseDelay
        manualOverrideMinutes = try c.decodeIfPresent(Int.self, forKey: .manualOverrideMinutes) ?? d.manualOverrideMinutes
    }
}

// MARK: - Inputs and outputs

/// What the host observed at one instant.
public struct WorkloadSnapshot: Equatable, Sendable {
    public var runningBundleIDs: Set<String>
    public var frontmostBundleID: String?
    /// Percent (0–100); `nil` when no sample is available yet.
    public var cpuLoad: Double?
    /// Percent (0–100); `nil` when the GPU load cannot be read.
    public var gpuLoad: Double?
    /// The active profile (`nil` = nothing selected, i.e. Automatic).
    public var activeProfileID: UUID?
    /// `FanControlManager.emergencyOverrideActive`.
    public var emergencyActive: Bool
    /// Profiles that can be applied; rules naming another id are ignored. `nil` = no check.
    public var availableProfileIDs: Set<UUID>?

    public init(runningBundleIDs: Set<String> = [], frontmostBundleID: String? = nil,
                cpuLoad: Double? = nil, gpuLoad: Double? = nil, activeProfileID: UUID? = nil,
                emergencyActive: Bool = false, availableProfileIDs: Set<UUID>? = nil) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.cpuLoad = cpuLoad
        self.gpuLoad = gpuLoad
        self.activeProfileID = activeProfileID
        self.emergencyActive = emergencyActive
        self.availableProfileIDs = availableProfileIDs
    }
}

/// Why a workload profile is engaged.
public enum WorkloadReason: Hashable, Sendable {
    case app(bundleIdentifier: String, name: String)
    case load(WorkloadLoadRule.Metric)
}

/// What automation is doing, for the settings tab and the widget indicator.
public enum WorkloadStatus: Hashable, Sendable {
    /// Automation is turned off.
    case disabled
    /// Enabled; no rule is active.
    case idle
    /// A rule is active and wants `profileID`.
    case engaged(profileID: UUID, reason: WorkloadReason)
    /// A manual profile choice paused automation until `until` (`nil` = until resumed).
    case pausedByManualSelection(until: Date?)
    /// The emergency override is active; no switching until it ends.
    case heldForEmergency
}

/// The engine's output for one `update`.
public struct WorkloadDecision: Equatable, Sendable {
    /// The profile automation wants active now; the host applies it when it is not
    /// already active. `nil` = leave the selection alone.
    public var profileID: UUID?
    public var status: WorkloadStatus

    public init(profileID: UUID?, status: WorkloadStatus) {
        self.profileID = profileID
        self.status = status
    }
}

// MARK: - Engine

/// Rules + state machine for workload-linked profile switching. Value type; the
/// host keeps one and calls `update(_:at:)` on every tick and on app notifications.
///
/// - **Engage**: the first active rule (enabled app rules in list order, then the
///   load rule) names the wanted profile. On the first engagement the active
///   profile is remembered as the *baseline*.
/// - **Switch**: while engaged, a different winning rule switches directly
///   (the baseline is kept).
/// - **Return**: when no rule is active any more, the decision names the baseline
///   once and the engine disengages (return-to-previous).
/// - **Hysteresis**: app rules stay matched `appReleaseDelay` s after the app quits /
///   loses focus; the load rule needs `highDuration` s above `highThreshold` and
///   `lowDuration` s below `lowThreshold`, and holds in between.
/// - **Manual override**: `noteManualSelection` disengages (no return; the user's
///   choice is the new baseline) and pauses decisions for `manualOverrideMinutes`
///   (0 = until `resume()` or disable / enable). Rule state keeps tracking meanwhile.
/// - **Emergency**: decisions are held (`profileID == nil`) while it lasts.
/// - **Disable**: an engaged engine returns to the baseline once, then stays quiet;
///   the manual lock is cleared.
///
/// See `WorkloadProfilePrecedence` for how this ranks against other selectors.
public struct WorkloadProfileEngine: Sendable {

    /// Phase of the sustained-load rule.
    public enum LoadPhase: Equatable, Sendable {
        /// At or below the high threshold (not engaged).
        case low
        /// Above the high threshold since the date, not yet for `highDuration`.
        case rising(since: Date)
        /// Engaged (load not below the low threshold).
        case high
        /// Engaged, below the low threshold since the date, not yet for `lowDuration`.
        case falling(since: Date)

        public var isEngaged: Bool {
            switch self {
            case .high, .falling: return true
            case .low, .rising: return false
            }
        }
    }

    /// The engaged rule and the profile to return to.
    public struct Engagement: Equatable, Sendable {
        public var profileID: UUID
        public var reason: WorkloadReason
        /// Active profile when automation engaged (`nil` = Automatic).
        public var baselineProfileID: UUID?
    }

    /// A manual choice pausing automation.
    public struct ManualLock: Equatable, Sendable {
        public var since: Date
        /// `nil` = until resumed.
        public var until: Date?
    }

    public var settings: WorkloadAutomationSettings {
        didSet {
            settings = settings.sanitized()
            if !settings.loadRule.isEnabled { loadPhase = .low }
            let ruleIDs = Set(settings.appRules.map(\.id))
            appLastMatched = appLastMatched.filter { ruleIDs.contains($0.key) }
        }
    }
    public private(set) var loadPhase: LoadPhase = .low
    /// Last time each app rule's condition held (drives `appReleaseDelay`).
    public private(set) var appLastMatched: [UUID: Date] = [:]
    public private(set) var engagement: Engagement?
    public private(set) var manualLock: ManualLock?
    public private(set) var status: WorkloadStatus

    public init(settings: WorkloadAutomationSettings = WorkloadAutomationSettings()) {
        let sanitized = settings.sanitized()
        self.settings = sanitized
        status = sanitized.isEnabled ? .idle : .disabled
    }

    /// Evaluates the rules at `now` and returns what to apply.
    public mutating func update(_ snapshot: WorkloadSnapshot, at now: Date) -> WorkloadDecision {
        advanceLoadPhase(load: effectiveLoad(snapshot), at: now)
        let winner = winningRule(snapshot, at: now)

        guard settings.isEnabled else {
            manualLock = nil
            status = .disabled
            return WorkloadDecision(profileID: disengage(), status: status)
        }
        if let lock = manualLock, let until = lock.until, now >= until {
            manualLock = nil
        }
        if let lock = manualLock {
            status = .pausedByManualSelection(until: lock.until)
            return WorkloadDecision(profileID: nil, status: status)
        }
        if snapshot.emergencyActive {
            status = .heldForEmergency
            return WorkloadDecision(profileID: nil, status: status)
        }
        if let winner {
            if engagement == nil {
                engagement = Engagement(profileID: winner.profileID, reason: winner.reason,
                                        baselineProfileID: snapshot.activeProfileID)
            } else {
                engagement?.profileID = winner.profileID
                engagement?.reason = winner.reason
            }
            status = .engaged(profileID: winner.profileID, reason: winner.reason)
            return WorkloadDecision(profileID: winner.profileID, status: status)
        }
        status = .idle
        return WorkloadDecision(profileID: disengage(), status: status)
    }

    /// The user chose `profileID` by hand: disengage without returning and pause
    /// automation (`manualOverrideMinutes`). Ignored while automation is off.
    public mutating func noteManualSelection(_ profileID: UUID?, at now: Date) {
        guard settings.isEnabled else { return }
        engagement = nil
        let minutes = settings.manualOverrideMinutes
        manualLock = ManualLock(since: now, until: minutes > 0 ? now.addingTimeInterval(TimeInterval(minutes) * 60) : nil)
        status = .pausedByManualSelection(until: manualLock?.until)
    }

    /// Ends a manual pause now; the next `update` re-evaluates the rules (and, if one
    /// is active, engages with the current profile as the baseline).
    public mutating func resume() {
        manualLock = nil
        if case .pausedByManualSelection = status { status = settings.isEnabled ? .idle : .disabled }
    }

    /// A lower-precedence selector (power, F2) chose `profileID`. While engaged it
    /// becomes the profile to return to; otherwise there is nothing to record.
    /// - Returns: `true` if the lower layer may apply its choice now (not engaged and
    ///   not paused by a manual choice).
    @discardableResult
    public mutating func noteLowerLayerSelection(_ profileID: UUID?) -> Bool {
        if engagement != nil {
            engagement?.baselineProfileID = profileID
            return false
        }
        return manualLock == nil
    }

    /// Forgets all state (engagement, lock, rule timers) without returning anywhere,
    /// e.g. when fan control itself is turned off.
    public mutating func reset() {
        engagement = nil
        manualLock = nil
        loadPhase = .low
        appLastMatched = [:]
        status = settings.isEnabled ? .idle : .disabled
    }

    // MARK: Private

    private mutating func disengage() -> UUID? {
        guard let engagement else { return nil }
        self.engagement = nil
        return engagement.baselineProfileID ?? FanProfile.BuiltInID.automatic
    }

    private func effectiveLoad(_ snapshot: WorkloadSnapshot) -> Double? {
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        switch settings.loadRule.metric {
        case .cpu: return valid(snapshot.cpuLoad)
        case .gpu: return valid(snapshot.gpuLoad)
        case .either:
            let values = [valid(snapshot.cpuLoad), valid(snapshot.gpuLoad)].compactMap { $0 }
            return values.max()
        }
    }

    /// No sample (`nil`) leaves the phase and its timers unchanged.
    private mutating func advanceLoadPhase(load: Double?, at now: Date) {
        let rule = settings.loadRule
        guard rule.isEnabled else { loadPhase = .low; return }
        guard let load else { return }
        switch loadPhase {
        case .low:
            if load > rule.highThreshold {
                loadPhase = rule.highDuration <= 0 ? .high : .rising(since: now)
            }
        case .rising(let since):
            if load <= rule.highThreshold {
                loadPhase = .low
            } else if now.timeIntervalSince(since) >= rule.highDuration {
                loadPhase = .high
            }
        case .high:
            if load < rule.lowThreshold {
                loadPhase = rule.lowDuration <= 0 ? .low : .falling(since: now)
            }
        case .falling(let since):
            if load >= rule.lowThreshold {
                loadPhase = .high
            } else if now.timeIntervalSince(since) >= rule.lowDuration {
                loadPhase = .low
            }
        }
    }

    private mutating func winningRule(_ snapshot: WorkloadSnapshot, at now: Date)
        -> (profileID: UUID, reason: WorkloadReason)? {
        func usable(_ id: UUID) -> Bool { snapshot.availableProfileIDs?.contains(id) ?? true }
        var winner: (profileID: UUID, reason: WorkloadReason)?
        for rule in settings.appRules where rule.isEnabled {
            let matches: Bool
            switch rule.trigger {
            case .running: matches = snapshot.runningBundleIDs.contains(rule.bundleIdentifier)
            case .frontmost: matches = snapshot.frontmostBundleID == rule.bundleIdentifier
            }
            if matches { appLastMatched[rule.id] = now }
            let active = matches || appLastMatched[rule.id].map {
                now.timeIntervalSince($0) < settings.appReleaseDelay
            } ?? false
            if !active { appLastMatched[rule.id] = nil }
            // Keep updating every rule's timer, even after a winner is found.
            if winner == nil, active, usable(rule.profileID) {
                winner = (rule.profileID, .app(bundleIdentifier: rule.bundleIdentifier, name: rule.displayName))
            }
        }
        if winner == nil, loadPhase.isEngaged, usable(settings.loadRule.profileID) {
            winner = (settings.loadRule.profileID, .load(settings.loadRule.metric))
        }
        return winner
    }
}
