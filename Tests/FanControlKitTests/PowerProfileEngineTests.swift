#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

// F2: `PowerProfileEngine` + `FanProfileArbiter` with an injected context, a fake Low Power
// Mode and a fake fan host. No SMC, no helper, no pmset.

private typealias ID = FanProfile.BuiltInID

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func time(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour, minute: minute))!
}

@MainActor
private final class FakePowerContext: PowerContextProviding {
    var context = PowerContext(powerSource: .ac, isLidClosed: false, date: time(12))
    private(set) var onChange: (@MainActor () -> Void)?
    var isObserving: Bool { onChange != nil }

    func currentContext() -> PowerContext { context }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }
}

private struct FakeFailure: LocalizedError {
    var errorDescription: String? { "helper not installed" }
}

/// Low Power Mode per power source (like `pmset -b` / `-c`); `state` is the in-use value.
@MainActor
private final class FakeLowPowerMode: LowPowerModeControlling {
    var battery = false
    var ac = false
    var onBattery = false
    var settingsReadable = true
    /// Every `-a`-style set (both values equal) as one Bool; per-source writes in `pairs`.
    private(set) var sets: [Bool] = []
    private(set) var pairs: [(battery: Bool, ac: Bool)] = []
    var fails = false

    /// The in-use value; setting it sets both sources (the user's "Always" / "Never").
    var state: Bool? {
        get { onBattery ? battery : ac }
        set {
            battery = newValue ?? false
            ac = newValue ?? false
        }
    }

    var isLowPowerModeEnabled: Bool? { state }

    func readLowPowerModeSettings() async -> LowPowerModeSettings? {
        settingsReadable ? LowPowerModeSettings(battery: battery, ac: ac) : nil
    }

    func setLowPowerMode(battery: Bool, ac: Bool) async throws {
        if battery == ac { sets.append(battery) }
        pairs.append((battery, ac))
        if fails { throw FakeFailure() }
        self.battery = battery
        self.ac = ac
    }
}

@MainActor
private final class FakeFanHost: FanProfileHosting {
    var active: UUID = ID.automatic
    private(set) var applied: [UUID] = []
    var failing: Set<UUID> = []
    private let store = ProfileStore()

    var activeFanProfileID: UUID { active }
    func fanProfile(id: UUID) -> FanProfile? { store.profile(id: id) }
    func applyFanProfile(id: UUID) async throws {
        applied.append(id)
        if failing.contains(id) { throw FakeFailure() }
        active = id
    }
}

@MainActor
private struct Rig {
    let context = FakePowerContext()
    let lowPower = FakeLowPowerMode()
    let host = FakeFanHost()
    let arbiter: FanProfileArbiter
    let engine: PowerProfileEngine
    let defaults: UserDefaults

    init(_ name: String, rules: [PowerProfileRule] = [], enabled: Bool = true, fresh: Bool = true) {
        let suite = "PowerProfileEngineTests.\(name)"
        defaults = UserDefaults(suiteName: suite)!
        if fresh { defaults.removePersistentDomain(forName: suite) }
        arbiter = FanProfileArbiter(host: host)
        engine = PowerProfileEngine(defaults: defaults, contextProvider: context, lowPowerMode: lowPower,
                                    arbiter: arbiter, calendar: calendar)
        if fresh || !rules.isEmpty {
            engine.configuration = PowerProfileConfiguration(isEnabled: enabled, rules: rules)
        }
    }

    /// Changes the context and evaluates.
    func set(_ source: PowerSourceKind? = nil, lid: Bool?? = nil, at date: Date? = nil) async {
        if let source {
            context.context.powerSource = source
            lowPower.onBattery = source == .battery
        }
        if let lid { context.context.isLidClosed = lid }
        if let date { context.context.date = date }
        await engine.evaluate()
    }

    /// The user picks a profile in the widget.
    func userSelects(_ id: UUID) {
        host.active = id
        arbiter.activeProfileDidChange()
    }
}

private let batteryRule = PowerProfileRule(name: "On Battery", powerSource: .battery,
                                           fanProfileID: ID.constantQuiet, lowPowerMode: .on)
private let clamshellRule = PowerProfileRule(name: "Clamshell", powerSource: .ac, lid: .closed,
                                             fanProfileID: ID.boost, lowPowerMode: .off)
private let nightRule = PowerProfileRule(name: "Night", timeWindow: PowerTimeWindow(from: (22, 0), to: (7, 0)),
                                         fanProfileID: ID.constantQuiet)

@MainActor
@Suite("Power profile engine (F2)", .serialized)
struct PowerProfileEngineTests {

    @Test func disabledConfigurationDoesNothing() async {
        let rig = Rig("disabled", rules: [batteryRule], enabled: false)
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.engine.matchedRule == nil)
        #expect(rig.host.applied.isEmpty)
        #expect(rig.lowPower.sets.isEmpty)
        #expect(rig.engine.status == nil)
        #expect(rig.context.isObserving)
    }

    @Test func notStartedDoesNothing() async {
        let rig = Rig("notStarted", rules: [batteryRule])
        await rig.set(.battery)
        #expect(rig.engine.matchedRule == nil)
        #expect(rig.host.applied.isEmpty)
    }

    @Test func matchingRuleSwitchesFanProfile() async {
        let rig = Rig("battery", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.engine.matchedRule?.name == "On Battery")
        #expect(rig.host.applied == [ID.constantQuiet])
        #expect(rig.arbiter.decision?.layer == .power)
        #expect(rig.arbiter.decision?.reason == "On Battery")
    }

    @Test func firstMatchWins() async {
        let quietOnAC = PowerProfileRule(name: "AC", powerSource: .ac, fanProfileID: ID.constantHigh)
        let rig = Rig("firstMatch", rules: [clamshellRule, quietOnAC])
        rig.engine.start()
        await rig.set(.ac, lid: true)
        #expect(rig.engine.matchedRule?.name == "Clamshell")
        #expect(rig.host.active == ID.boost)
        await rig.set(lid: false)
        #expect(rig.engine.matchedRule?.name == "AC")
        #expect(rig.host.applied == [ID.boost, ID.constantHigh])
    }

    @Test func leavingTheRuleReturnsToTheBaseline() async {
        let rig = Rig("baseline", rules: [batteryRule])
        rig.host.active = ID.custom1  // the user's profile before automation
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.host.active == ID.constantQuiet)
        await rig.set(.ac)
        #expect(rig.engine.matchedRule == nil)
        #expect(rig.host.active == ID.custom1)
        #expect(rig.arbiter.decision?.layer == .baseline)
    }

    @Test func nothingIsRewrittenWhileTheRuleHolds() async {
        let rig = Rig("noRewrite", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        await rig.engine.evaluate()
        await rig.set(at: time(13))
        #expect(rig.host.applied == [ID.constantQuiet])
        #expect(rig.lowPower.sets == [true])
    }

    @Test func timeWindowTransitions() async {
        let rig = Rig("night", rules: [nightRule])
        rig.engine.start()
        await rig.set(at: time(21, 59))
        #expect(rig.engine.matchedRule == nil)
        await rig.set(at: time(22, 0))
        #expect(rig.host.active == ID.constantQuiet)
        await rig.set(at: time(7, 0))
        #expect(rig.host.active == ID.automatic)
        #expect(rig.host.applied == [ID.constantQuiet, ID.automatic])
    }

    @Test func lowPowerModeIsSetAndGivenBack() async {
        let rig = Rig("lpmRestore", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.lowPower.sets == [true])
        #expect(rig.engine.lowPowerModeRestoreValue == false)
        #expect(rig.engine.isLowPowerModeEnabled == true)
        await rig.set(.ac)
        #expect(rig.lowPower.sets == [true, false])
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
    }

    @Test func lowPowerModeAlreadyOnIsNeitherWrittenNorRestored() async {
        let rig = Rig("lpmAlready", rules: [batteryRule])
        rig.lowPower.state = true
        rig.engine.start()
        await rig.set(.battery)
        await rig.set(.ac)
        #expect(rig.lowPower.sets.isEmpty)
        #expect(rig.lowPower.state == true)
    }

    @Test func aManualLowPowerModeChangeIsKept() async {
        let rig = Rig("lpmUser", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        rig.lowPower.state = false  // the user turned it off in Control Center
        await rig.engine.evaluate()
        #expect(rig.lowPower.sets == [true])  // not fought while the rule holds
        await rig.set(.ac)
        #expect(rig.lowPower.sets == [true])  // and not "restored" over the user's choice
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
    }

    @Test func lowPowerModeAcrossTwoRulesRestoresTheOriginal() async {
        let lpmOffOnAC = PowerProfileRule(name: "AC", powerSource: .ac, lowPowerMode: .off)
        let lpmOnBattery = PowerProfileRule(name: "Battery", powerSource: .battery, lowPowerMode: .on)
        let rig = Rig("lpmTwoRules", rules: [lpmOffOnAC, lpmOnBattery])
        rig.lowPower.state = true  // the user's own setting
        rig.engine.start()
        await rig.set(.ac)
        await rig.set(.battery)
        #expect(rig.lowPower.sets == [false, true])
        #expect(rig.engine.lowPowerModeRestoreValue == true)
        rig.engine.configuration.rules = []
        await rig.engine.evaluate()
        #expect(rig.lowPower.sets == [false, true])  // already back at the user's value
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
    }

    @Test func lowPowerModeFailureIsReportedWithoutMemory() async {
        let rig = Rig("lpmFail", rules: [batteryRule])
        rig.lowPower.fails = true
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.engine.lowPowerModeError == "helper not installed")
        #expect(rig.engine.status?.error == "helper not installed")
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
        await rig.engine.evaluate()
        #expect(rig.lowPower.sets == [true])  // no hot retry loop while the rule holds
        await rig.set(.ac)
        #expect(rig.lowPower.sets == [true])  // nothing to give back
    }

    @Test func failedChangeIsRetriedWhileTheRuleHolds() async {
        let rig = Rig("lpmRetry", rules: [batteryRule])
        rig.lowPower.fails = true
        rig.engine.start()
        await rig.set(.battery, at: time(12))
        #expect(rig.lowPower.sets == [true])
        rig.lowPower.fails = false   // the helper is back (install.sh re-run)
        await rig.set(at: time(12, 0) + 30)
        #expect(rig.lowPower.sets == [true])  // within the retry interval
        await rig.set(at: time(12, 1) + 1)
        #expect(rig.lowPower.sets == [true, true])
        #expect(rig.lowPower.state == true)
        #expect(rig.engine.lowPowerModeError == nil)
        #expect(rig.engine.lowPowerModeRestoreValue == false)
        await rig.set(at: time(12, 5))
        #expect(rig.lowPower.sets == [true, true])  // settled: not rewritten
    }

    @Test func failedRestoreKeepsTheMemoryAndRetries() async {
        let rig = Rig("lpmRestoreFail", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery, at: time(12))
        rig.lowPower.fails = true
        await rig.set(.ac, at: time(12, 1))
        #expect(rig.lowPower.sets == [true, false])
        #expect(rig.engine.lowPowerModeRestoreValue == false)  // kept (and persisted)
        #expect(rig.defaults.data(forKey: PowerProfileEngine.lowPowerModeMemoryKey) != nil)
        rig.lowPower.fails = false
        await rig.set(at: time(12, 3))
        #expect(rig.lowPower.sets == [true, false, false])
        #expect(rig.lowPower.state == false)
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
        #expect(rig.defaults.data(forKey: PowerProfileEngine.lowPowerModeMemoryKey) == nil)
    }

    @Test func persistedMemoryIsRestoredAfterARelaunchWithoutAMatchingRule() async {
        do {
            let rig = Rig("relaunchRestore", rules: [batteryRule])
            rig.engine.start()
            await rig.set(.battery)
            #expect(rig.lowPower.sets == [true])
        }
        let relaunched = Rig("relaunchRestore", fresh: false)
        relaunched.lowPower.state = true   // still on from before the relaunch
        relaunched.context.context.powerSource = .ac   // plugged in while the app was not running
        relaunched.engine.start()
        await relaunched.engine.evaluate()
        #expect(relaunched.lowPower.sets == [false])
        #expect(relaunched.engine.lowPowerModeRestoreValue == nil)
    }

    @Test func perSourceSettingsAreRememberedAndRestored() async {
        // The user's "Only on Battery" (battery 1, AC 0), on AC; a rule turns LPM on for every source.
        let lpmOnAC = PowerProfileRule(name: "Clamshell", powerSource: .ac, lid: .closed, lowPowerMode: .on)
        let rig = Rig("lpmPerSource", rules: [lpmOnAC])
        rig.lowPower.battery = true
        rig.lowPower.ac = false
        rig.engine.start()
        await rig.set(.ac, lid: true)
        #expect(rig.lowPower.sets == [true])
        #expect(rig.engine.lowPowerModeRestorePair == [true, false])
        await rig.set(.battery, lid: false)   // unplugged: the rule ends
        #expect(rig.lowPower.pairs.last.map { [$0.battery, $0.ac] } == [true, false])
        #expect(rig.lowPower.battery == true)
        #expect(rig.lowPower.ac == false)
        #expect(rig.engine.lowPowerModeRestorePair == nil)
    }

    @Test func aPerSourceChangeByTheUserIsKept() async {
        let rig = Rig("lpmPerSourceUser", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.lowPower.sets == [true])
        rig.lowPower.ac = false   // the user picked "Only on Battery" meanwhile (in-use still on)
        await rig.set(.ac)
        #expect(rig.lowPower.pairs.count == 1)  // not "restored" over it
        #expect(rig.lowPower.battery == true)
        #expect(rig.engine.lowPowerModeRestoreValue == nil)
    }

    @Test func unreadablePerSourceSettingsFallBackToTheInUseValue() async {
        let rig = Rig("lpmNoCustom", rules: [batteryRule])
        rig.lowPower.settingsReadable = false
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.engine.lowPowerModeRestorePair == [false, false])
        await rig.set(.ac)
        #expect(rig.lowPower.sets == [true, false])
    }

    @Test func memoryPersistedByAnOlderBuildStillDecodes() throws {
        let old = Data(#"{"restoreValue":true,"valueSetByEngine":false}"#.utf8)
        let memory = try JSONDecoder().decode(LowPowerModeMemory.self, from: old)
        #expect(memory.restoreBattery == nil && memory.restoreAC == nil)
        #expect(memory.restorePair == (true, true))
    }

    @Test func manualPickWinsUntilTheNextTransition() async {
        let rig = Rig("manual", rules: [batteryRule, clamshellRule])
        rig.engine.start()
        await rig.set(.battery)
        rig.userSelects(ID.max)
        #expect(rig.engine.status?.isManualOverride == true)
        await rig.set(at: time(13))
        #expect(rig.host.active == ID.max)  // not switched back on a tick
        await rig.set(.ac, lid: true)       // new context → automation again
        #expect(rig.host.active == ID.boost)
        #expect(rig.engine.status?.isManualOverride == false)
        #expect(rig.host.applied == [ID.constantQuiet, ID.boost])
    }

    @Test func resumeAutomationReappliesTheRule() async {
        let rig = Rig("resume", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        rig.userSelects(ID.max)
        await rig.engine.resumeAutomation()
        #expect(rig.host.active == ID.constantQuiet)
        #expect(rig.engine.status?.winningLayer == .power)
    }

    @Test func manualPickBecomesTheBaseline() async {
        let rig = Rig("manualBaseline", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        rig.userSelects(ID.custom2)
        await rig.set(.ac)
        #expect(rig.host.active == ID.custom2)
        #expect(rig.host.applied == [ID.constantQuiet])
    }

    @Test func stopWithdrawsTheClaimAndGivesLowPowerModeBack() async {
        let rig = Rig("stop", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        await rig.engine.stop()
        #expect(!rig.context.isObserving)
        #expect(rig.host.active == ID.automatic)
        #expect(rig.lowPower.sets == [true, false])
        #expect(rig.engine.status == nil)
    }

    @Test func turningPowerProfilesOffRestores() async {
        let rig = Rig("turnOff", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        rig.engine.configuration.isEnabled = false
        await rig.engine.evaluate()
        #expect(rig.host.active == ID.automatic)
        #expect(rig.lowPower.state == false)
    }

    @Test func ruleWithoutFanProfileLeavesFansAlone() async {
        let lpmOnly = PowerProfileRule(name: "LPM", powerSource: .battery, lowPowerMode: .on)
        let rig = Rig("lpmOnly", rules: [lpmOnly])
        rig.host.active = ID.custom1
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.host.applied.isEmpty)
        #expect(rig.host.active == ID.custom1)
        #expect(rig.lowPower.sets == [true])
    }

    @Test func applyGateBlocksFanSwitching() async {
        let rig = Rig("gate", rules: [batteryRule])
        rig.arbiter.isApplyAllowed = { false }
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.host.applied.isEmpty)
        #expect(rig.arbiter.decision?.profileID == ID.constantQuiet)
    }

    @Test func failedSwitchIsNotRetriedUntilTheDecisionChanges() async {
        let rig = Rig("failedApply", rules: [batteryRule])
        rig.host.failing = [ID.constantQuiet]
        rig.engine.start()
        await rig.set(.battery)
        await rig.set(at: time(13))
        #expect(rig.host.applied == [ID.constantQuiet])
        #expect(rig.arbiter.lastError == "helper not installed")
        rig.host.failing = []
        await rig.arbiter.retry()
        #expect(rig.host.active == ID.constantQuiet)
        #expect(rig.arbiter.lastError == nil)
    }

    @Test func contextChangesTriggerEvaluation() async {
        let rig = Rig("observe", rules: [batteryRule])
        rig.engine.start()
        await rig.engine.evaluate()
        rig.context.context.powerSource = .battery
        rig.context.onChange?()
        await rig.engine.evaluate()  // runs after the evaluation the change scheduled
        #expect(rig.host.active == ID.constantQuiet)
    }

    @Test func configurationPersists() async {
        do {
            let rig = Rig("persist", rules: [batteryRule, nightRule])
            #expect(rig.defaults.data(forKey: PowerProfileEngine.defaultsKey) != nil)
        }
        let reloaded = Rig("persist", fresh: false)
        #expect(reloaded.engine.configuration == PowerProfileConfiguration(isEnabled: true, rules: [batteryRule, nightRule]))
    }

    @Test func lowPowerModeMemorySurvivesARelaunch() async {
        do {
            let rig = Rig("relaunch", rules: [batteryRule])
            rig.engine.start()
            await rig.set(.battery)
            #expect(rig.lowPower.sets == [true])
        }
        let relaunched = Rig("relaunch", fresh: false)
        relaunched.lowPower.state = true   // still on from before the relaunch
        relaunched.context.context.powerSource = .battery
        relaunched.engine.start()
        await relaunched.engine.evaluate()
        #expect(relaunched.lowPower.sets.isEmpty)
        await relaunched.set(.ac)
        #expect(relaunched.lowPower.sets == [false])  // the pre-relaunch original
    }

    @Test func workloadClaimOutranksPower() async {
        let rig = Rig("workload", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.battery)
        await rig.arbiter.setClaim(ProfileClaim(profileID: ID.max, reason: "Xcode"), for: .workload)
        #expect(rig.host.active == ID.max)
        #expect(rig.engine.status?.winningLayer == .workload)
        await rig.arbiter.setClaim(nil, for: .workload)
        #expect(rig.host.active == ID.constantQuiet)
    }

    @Test func automaticAppliesAreDistinguishableFromManualPicks() async {
        let rig = Rig("f3Hooks", rules: [batteryRule])
        var automatic: [UUID] = []
        var manual: [UUID] = []
        let center = NotificationCenter.default
        let a = center.addObserver(forName: FanProfileArbiter.automaticApplyNotification, object: rig.arbiter,
                                   queue: nil) { note in
            if let id = note.userInfo?["profileID"] as? UUID { MainActor.assumeIsolated { automatic.append(id) } }
        }
        let m = center.addObserver(forName: FanProfileArbiter.manualSelectionNotification, object: rig.arbiter,
                                   queue: nil) { note in
            if let id = note.userInfo?["profileID"] as? UUID { MainActor.assumeIsolated { manual.append(id) } }
        }
        defer { center.removeObserver(a); center.removeObserver(m) }
        rig.engine.start()
        await rig.set(.battery)
        #expect(rig.arbiter.lastAutomaticApplyID == ID.constantQuiet)
        #expect(automatic == [ID.constantQuiet])
        #expect(manual.isEmpty)
        rig.userSelects(ID.max)
        #expect(rig.arbiter.lastAutomaticApplyID == nil)
        #expect(manual == [ID.max])
    }

    @Test func statusDescribesTheMatch() async {
        let rig = Rig("status", rules: [batteryRule])
        rig.engine.start()
        await rig.set(.ac)
        #expect(rig.engine.status == PowerProfileStatus(ruleName: nil, fanProfileID: nil, lowPowerMode: .unchanged,
                                                        isLowPowerModeEnabled: false, isManualOverride: false,
                                                        winningLayer: nil, error: nil))
        await rig.set(.battery)
        #expect(rig.engine.status?.ruleName == "On Battery")
        #expect(rig.engine.status?.fanProfileID == ID.constantQuiet)
        #expect(rig.engine.status?.lowPowerMode == .on)
        #expect(rig.engine.status?.isLowPowerModeEnabled == true)
    }
}
#endif
