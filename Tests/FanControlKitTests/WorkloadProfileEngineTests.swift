import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// Transitions of `WorkloadProfileEngine` (feature F3): app rules, sustained load,
/// return-to-previous, hysteresis, manual override lock, emergency hold, disable.
@Suite("Workload profile engine")
struct WorkloadProfileEngineTests {

    // MARK: Fixtures

    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let boost = FanProfile.BuiltInID.boost
    let max = FanProfile.BuiltInID.max
    let quiet = FanProfile.BuiltInID.constantQuiet
    let automatic = FanProfile.BuiltInID.automatic
    static let xcode = "com.apple.dt.Xcode"
    static let fcp = "com.apple.FinalCut"

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func settings(appRules: [WorkloadAppRule] = [], load: Bool = false, metric: WorkloadLoadRule.Metric = .cpu,
                  release: TimeInterval = 10, overrideMinutes: Int = 30) -> WorkloadAutomationSettings {
        WorkloadAutomationSettings(isEnabled: true, appRules: appRules,
                                   loadRule: WorkloadLoadRule(isEnabled: load, metric: metric, profileID: boost),
                                   appReleaseDelay: release, manualOverrideMinutes: overrideMinutes)
    }

    func xcodeRule(_ trigger: WorkloadAppRule.Trigger = .running, profile: UUID? = nil) -> WorkloadAppRule {
        WorkloadAppRule(bundleIdentifier: Self.xcode, displayName: "Xcode", trigger: trigger, profileID: profile ?? boost)
    }

    func snap(running: Set<String> = [], front: String? = nil, cpu: Double? = nil, gpu: Double? = nil,
              active: UUID? = nil, emergency: Bool = false) -> WorkloadSnapshot {
        WorkloadSnapshot(runningBundleIDs: running, frontmostBundleID: front, cpuLoad: cpu, gpuLoad: gpu,
                         activeProfileID: active, emergencyActive: emergency)
    }

    // MARK: App rules

    @Test func disabledEngineNeverDecides() {
        let engine = EngineBox(settings: WorkloadAutomationSettings(appRules: [xcodeRule()]))
        let decision = engine.update(snap(running: [Self.xcode]), at: at(0))
        #expect(decision == WorkloadDecision(profileID: nil, status: .disabled))
    }

    @Test func idleWithoutMatchingApp() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        let decision = engine.update(snap(running: ["com.apple.Safari"]), at: at(0))
        #expect(decision == WorkloadDecision(profileID: nil, status: .idle))
    }

    @Test func runningAppEngagesAndRemembersBaseline() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        let decision = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        #expect(decision.profileID == boost)
        #expect(decision.status == .engaged(profileID: boost, reason: .app(bundleIdentifier: Self.xcode, name: "Xcode")))
        #expect(engine.engagement?.baselineProfileID == quiet)
    }

    @Test func engagedDecisionRepeatsEveryTick() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        // The host re-applies if someone else changed the profile; baseline stays.
        let decision = engine.update(snap(running: [Self.xcode], active: boost), at: at(2))
        #expect(decision.profileID == boost)
        #expect(engine.engagement?.baselineProfileID == quiet)
    }

    @Test func appQuitReturnsToBaselineAfterReleaseDelay() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 10))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        // Within the release delay: still engaged (hysteresis).
        #expect(engine.update(snap(active: boost), at: at(5)).profileID == boost)
        // After it: back to the profile that was active before.
        let back = engine.update(snap(active: boost), at: at(10))
        #expect(back == WorkloadDecision(profileID: quiet, status: .idle))
        // Only once.
        #expect(engine.update(snap(active: quiet), at: at(12)).profileID == nil)
        #expect(engine.engagement == nil)
    }

    @Test func appRelaunchWithinReleaseDelayKeepsEngagement() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 10))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        _ = engine.update(snap(active: boost), at: at(8))
        // Relaunched: the release timer restarts.
        #expect(engine.update(snap(running: [Self.xcode], active: boost), at: at(9)).profileID == boost)
        #expect(engine.update(snap(active: boost), at: at(18)).profileID == boost)
        #expect(engine.update(snap(active: boost), at: at(19)).profileID == quiet)
    }

    @Test func nilBaselineReturnsToAutomatic() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 0))
        _ = engine.update(snap(running: [Self.xcode], active: nil), at: at(0))
        #expect(engine.update(snap(active: boost), at: at(1)).profileID == automatic)
    }

    @Test func frontmostTriggerFollowsFocus() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule(.frontmost)], release: 0))
        // Running but in the background: no match.
        #expect(engine.update(snap(running: [Self.xcode], front: "com.apple.Safari", active: quiet), at: at(0)).profileID == nil)
        #expect(engine.update(snap(running: [Self.xcode], front: Self.xcode, active: quiet), at: at(1)).profileID == boost)
        #expect(engine.update(snap(running: [Self.xcode], front: "com.apple.Safari", active: boost), at: at(2)).profileID == quiet)
    }

    @Test func firstMatchingRuleWinsAndSwitchingKeepsBaseline() {
        let fcpRule = WorkloadAppRule(bundleIdentifier: Self.fcp, displayName: "Final Cut Pro", profileID: max)
        let engine = EngineBox(settings: settings(appRules: [fcpRule, xcodeRule()], release: 0))
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(0)).profileID == boost)
        // Final Cut launches: it is listed first, so it wins; direct switch.
        let both = engine.update(snap(running: [Self.xcode, Self.fcp], active: boost), at: at(1))
        #expect(both.status == .engaged(profileID: max, reason: .app(bundleIdentifier: Self.fcp, name: "Final Cut Pro")))
        #expect(engine.engagement?.baselineProfileID == quiet)
        // Final Cut quits: back to Xcode's profile, not to the baseline.
        #expect(engine.update(snap(running: [Self.xcode], active: max), at: at(2)).profileID == boost)
        #expect(engine.update(snap(active: boost), at: at(3)).profileID == quiet)
    }

    @Test func disabledRuleIsIgnored() {
        var rule = xcodeRule()
        rule.isEnabled = false
        let engine = EngineBox(settings: settings(appRules: [rule]))
        #expect(engine.update(snap(running: [Self.xcode]), at: at(0)).status == .idle)
    }

    @Test func ruleWithUnavailableProfileIsSkipped() {
        let missing = UUID()
        let engine = EngineBox(settings: settings(appRules: [xcodeRule(profile: missing)]))
        var snapshot = snap(running: [Self.xcode])
        snapshot.availableProfileIDs = Set(FanProfile.fixedProfileIDs)
        #expect(engine.update(snapshot, at: at(0)).status == .idle)
    }

    // MARK: Sustained load

    @Test func loadMustStayHighForTheDuration() {
        let engine = EngineBox(settings: settings(load: true))
        #expect(engine.update(snap(cpu: 80, active: quiet), at: at(0)).profileID == nil)
        #expect(engine.loadPhase == .rising(since: at(0)))
        #expect(engine.update(snap(cpu: 85, active: quiet), at: at(19)).profileID == nil)
        let engaged = engine.update(snap(cpu: 90, active: quiet), at: at(20))
        #expect(engaged.status == .engaged(profileID: boost, reason: .load(.cpu)))
        #expect(engine.engagement?.baselineProfileID == quiet)
    }

    @Test func loadDipDuringRiseRestartsTimer() {
        let engine = EngineBox(settings: settings(load: true))
        _ = engine.update(snap(cpu: 80), at: at(0))
        _ = engine.update(snap(cpu: 60), at: at(10))   // at or below 70: back to low
        #expect(engine.loadPhase == .low)
        _ = engine.update(snap(cpu: 80), at: at(12))
        #expect(engine.update(snap(cpu: 80), at: at(30)).profileID == nil)   // only 18 s
        #expect(engine.update(snap(cpu: 80), at: at(32)).profileID == boost)
    }

    @Test func loadBetweenThresholdsHolds() {
        let engine = EngineBox(settings: settings(load: true))
        _ = engine.update(snap(cpu: 80, active: quiet), at: at(0))
        _ = engine.update(snap(cpu: 80, active: quiet), at: at(20))
        // 55 % is below the high threshold but above the low one: stays engaged.
        #expect(engine.update(snap(cpu: 55, active: boost), at: at(200)).profileID == boost)
        #expect(engine.loadPhase == .high)
    }

    @Test func loadReturnsAfterSustainedLow() {
        let engine = EngineBox(settings: settings(load: true))
        _ = engine.update(snap(cpu: 80, active: quiet), at: at(0))
        _ = engine.update(snap(cpu: 80, active: quiet), at: at(20))
        _ = engine.update(snap(cpu: 30, active: boost), at: at(30))
        #expect(engine.loadPhase == .falling(since: at(30)))
        #expect(engine.update(snap(cpu: 30, active: boost), at: at(89)).profileID == boost)
        #expect(engine.update(snap(cpu: 30, active: boost), at: at(90)) == WorkloadDecision(profileID: quiet, status: .idle))
        #expect(engine.loadPhase == .low)
    }

    @Test func loadSpikeDuringFallRestartsLowTimer() {
        let engine = EngineBox(settings: settings(load: true))
        _ = engine.update(snap(cpu: 80), at: at(0))
        _ = engine.update(snap(cpu: 80), at: at(20))
        _ = engine.update(snap(cpu: 30), at: at(30))
        _ = engine.update(snap(cpu: 45), at: at(60))   // back above 40: high again
        #expect(engine.loadPhase == .high)
        _ = engine.update(snap(cpu: 30), at: at(61))
        #expect(engine.update(snap(cpu: 30), at: at(120)).profileID == boost)
        #expect(engine.update(snap(cpu: 30), at: at(121)).profileID == automatic)
    }

    @Test func missingSampleKeepsPhase() {
        let engine = EngineBox(settings: settings(load: true))
        _ = engine.update(snap(cpu: 80), at: at(0))
        _ = engine.update(snap(cpu: nil), at: at(10))
        #expect(engine.loadPhase == .rising(since: at(0)))
        #expect(engine.update(snap(cpu: 80), at: at(20)).profileID == boost)
    }

    @Test func gpuAndEitherMetrics() {
        let gpu = EngineBox(settings: settings(load: true, metric: .gpu))
        _ = gpu.update(snap(cpu: 99, gpu: 10), at: at(0))
        #expect(gpu.loadPhase == .low)
        let either = EngineBox(settings: settings(load: true, metric: .either))
        _ = either.update(snap(cpu: 10, gpu: 90), at: at(0))
        let decision = either.update(snap(cpu: 10, gpu: 90), at: at(20))
        #expect(decision.status == .engaged(profileID: boost, reason: .load(.either)))
    }

    @Test func appRuleOutranksLoadRule() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule(profile: quiet)], load: true, release: 0))
        _ = engine.update(snap(cpu: 90, active: automatic), at: at(0))
        #expect(engine.update(snap(cpu: 90, active: automatic), at: at(20)).profileID == boost)
        // Xcode launches: its rule wins over the still-high load.
        #expect(engine.update(snap(running: [Self.xcode], cpu: 90, active: boost), at: at(21)).profileID == quiet)
        // Xcode quits, load still high: back to the load rule's profile, not the baseline.
        #expect(engine.update(snap(cpu: 90, active: quiet), at: at(22)).profileID == boost)
        #expect(engine.engagement?.baselineProfileID == automatic)
    }

    // MARK: Manual override

    @Test func manualSelectionPausesWithoutReturning() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 0, overrideMinutes: 30))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        engine.noteManualSelection(max, at: at(5))
        #expect(engine.engagement == nil)
        let paused = engine.update(snap(running: [Self.xcode], active: max), at: at(6))
        #expect(paused == WorkloadDecision(profileID: nil, status: .pausedByManualSelection(until: at(5 + 1800))))
        // Xcode quits during the pause: no return to Quiet (the user's choice stands).
        #expect(engine.update(snap(active: max), at: at(60)).profileID == nil)
    }

    @Test func manualLockExpiresAndReengagesWithUserChoiceAsBaseline() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 0, overrideMinutes: 15))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        engine.noteManualSelection(max, at: at(10))
        #expect(engine.update(snap(running: [Self.xcode], active: max), at: at(10 + 899)).profileID == nil)
        let resumed = engine.update(snap(running: [Self.xcode], active: max), at: at(10 + 900))
        #expect(resumed.profileID == boost)
        #expect(engine.engagement?.baselineProfileID == max)
        #expect(engine.update(snap(active: boost), at: at(1000)).profileID == max)
    }

    @Test func untilResumedLockNeedsResume() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], overrideMinutes: 0))
        engine.noteManualSelection(quiet, at: at(0))
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(86_400)).status
                == .pausedByManualSelection(until: nil))
        engine.resume()
        #expect(engine.manualLock == nil)
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(86_401)).profileID == boost)
    }

    @Test func manualSelectionWhileIdleAlsoPauses() {
        let engine = EngineBox(settings: settings(load: true))
        engine.noteManualSelection(quiet, at: at(0))
        _ = engine.update(snap(cpu: 90, active: quiet), at: at(0))
        // Load tracking continues during the pause.
        let paused = engine.update(snap(cpu: 90, active: quiet), at: at(30))
        #expect(paused.profileID == nil)
        #expect(engine.loadPhase == .high)
        engine.resume()
        #expect(engine.update(snap(cpu: 90, active: quiet), at: at(31)).profileID == boost)
    }

    @Test func disableAndReenableClearsManualLock() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], overrideMinutes: 0))
        engine.noteManualSelection(quiet, at: at(0))
        engine.settings.isEnabled = false
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(1)).status == .disabled)
        engine.settings.isEnabled = true
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(2)).profileID == boost)
    }

    @Test func manualSelectionIgnoredWhileDisabled() {
        let engine = EngineBox(settings: WorkloadAutomationSettings())
        engine.noteManualSelection(quiet, at: at(0))
        #expect(engine.manualLock == nil)
    }

    // MARK: Emergency, disable, lower layers

    @Test func emergencyHoldsThenResumes() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 0))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        // Xcode quits during an emergency: no switch while it lasts.
        #expect(engine.update(snap(active: boost, emergency: true), at: at(1))
                == WorkloadDecision(profileID: nil, status: .heldForEmergency))
        #expect(engine.engagement != nil)
        // Emergency over: the pending return happens.
        #expect(engine.update(snap(active: boost), at: at(2)).profileID == quiet)
    }

    @Test func emergencyDoesNotEngage() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        #expect(engine.update(snap(running: [Self.xcode], active: quiet, emergency: true), at: at(0)).profileID == nil)
        #expect(engine.engagement == nil)
    }

    @Test func disablingWhileEngagedReturnsOnce() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        engine.settings.isEnabled = false
        #expect(engine.update(snap(running: [Self.xcode], active: boost), at: at(1))
                == WorkloadDecision(profileID: quiet, status: .disabled))
        #expect(engine.update(snap(running: [Self.xcode], active: quiet), at: at(2)).profileID == nil)
    }

    @Test func removingTheRuleWhileEngagedReturns() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()]))
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        engine.settings.appRules = []
        #expect(engine.appLastMatched.isEmpty)
        #expect(engine.update(snap(running: [Self.xcode], active: boost), at: at(1)).profileID == quiet)
    }

    @Test func lowerLayerSelectionBecomesBaselineWhileEngaged() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], release: 0))
        #expect(engine.noteLowerLayerSelection(quiet))   // not engaged: may apply
        _ = engine.update(snap(running: [Self.xcode], active: quiet), at: at(0))
        #expect(!engine.noteLowerLayerSelection(max))    // engaged: only recorded
        #expect(engine.update(snap(active: boost), at: at(1)).profileID == max)
        engine.noteManualSelection(quiet, at: at(2))
        #expect(!engine.noteLowerLayerSelection(max))    // manual lock outranks it
    }

    @Test func resetForgetsWithoutReturning() {
        let engine = EngineBox(settings: settings(appRules: [xcodeRule()], load: true))
        _ = engine.update(snap(running: [Self.xcode], cpu: 90, active: quiet), at: at(0))
        engine.reset()
        #expect(engine.engagement == nil)
        #expect(engine.loadPhase == .low)
        #expect(engine.status == .idle)
    }

    // MARK: Settings

    @Test func sanitizedClampsThresholds() {
        var s = settings(load: true)
        s.loadRule.highThreshold = 150
        s.loadRule.lowThreshold = 120
        s.loadRule.highDuration = -5
        s.loadRule.lowDuration = .nan
        s.appReleaseDelay = 10_000
        s.manualOverrideMinutes = -1
        let clean = s.sanitized()
        #expect(clean.loadRule.highThreshold == 100)
        #expect(clean.loadRule.lowThreshold == 100)
        #expect(clean.loadRule.highDuration == 0)
        #expect(clean.loadRule.lowDuration == 60)
        #expect(clean.appReleaseDelay == 600)
        #expect(clean.manualOverrideMinutes == 0)
    }

    @Test func settingsRoundTripAndDecodeWithDefaults() throws {
        let s = settings(appRules: [xcodeRule(.frontmost)], load: true, metric: .either)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WorkloadAutomationSettings.self, from: data) == s)
        let partial = try JSONDecoder().decode(WorkloadAutomationSettings.self,
                                               from: Data(#"{"isEnabled":true,"loadRule":{"metric":"bogus"}}"#.utf8))
        #expect(partial.isEnabled)
        #expect(partial.loadRule == WorkloadLoadRule())
        #expect(partial.manualOverrideMinutes == 30)
    }

    // MARK: Sampler math

    @Test func cpuTickDeltaUsage() {
        let a = CPULoadTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPULoadTicks(user: 160, system: 70, idle: 900, nice: 70)
        #expect(CPULoadTicks.usage(from: a, to: b) == 50)
        #expect(CPULoadTicks.usage(from: a, to: a) == nil)
        // 32-bit counters wrap.
        let wrapped = CPULoadTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let after = CPULoadTicks(user: 10, system: 0, idle: 20, nice: 0)
        #expect(CPULoadTicks.usage(from: wrapped, to: after) == 50)
    }

    @Test func gpuUtilizationFromStatistics() {
        let stats: [[String: Any]] = [["Device Utilization %": 12], ["Other": 1], ["Device Utilization %": 140]]
        #expect(SystemLoadSampler.gpuUtilization(fromPerformanceStatistics: stats) == 100)
        #expect(SystemLoadSampler.gpuUtilization(fromPerformanceStatistics: []) == nil)
    }

    @Test func samplerSmoke() {
        let sampler = SystemLoadSampler()
        #expect(sampler.sample().cpu == nil)   // first call has no previous ticks
        if let cpu = sampler.sample().cpu { #expect((0...100).contains(cpu)) }
    }
}

/// Reference wrapper so `#expect(engine.update(...))` can call the mutating engine.
@dynamicMemberLookup
private final class EngineBox {
    var engine: WorkloadProfileEngine

    init(settings: WorkloadAutomationSettings) { engine = WorkloadProfileEngine(settings: settings) }

    subscript<T>(dynamicMember keyPath: KeyPath<WorkloadProfileEngine, T>) -> T { engine[keyPath: keyPath] }

    var settings: WorkloadAutomationSettings {
        get { engine.settings }
        set { engine.settings = newValue }
    }

    func update(_ snapshot: WorkloadSnapshot, at now: Date) -> WorkloadDecision { engine.update(snapshot, at: now) }
    func noteManualSelection(_ id: UUID?, at now: Date) { engine.noteManualSelection(id, at: now) }
    func resume() { engine.resume() }
    @discardableResult func noteLowerLayerSelection(_ id: UUID?) -> Bool { engine.noteLowerLayerSelection(id) }
    func reset() { engine.reset() }
}
