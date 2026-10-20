import Foundation
import Testing
@testable import FanControlCore

// F2: power-profile rules (`PowerProfileRules.swift`) and the profile precedence
// (`ProfileArbitration.swift`).

/// Fixed Gregorian calendar in UTC so the tests do not depend on the machine's zone.
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-19 is a Monday (weekday 2).
private func date(day: Int = 19, _ hour: Int, _ minute: Int = 0) -> Date {
    utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func context(_ source: PowerSourceKind = .ac, lid: Bool? = false, at time: Date = date(12)) -> PowerContext {
    PowerContext(powerSource: source, isLidClosed: lid, date: time)
}

@Suite("Power profile rules (F2)")
struct PowerProfileRulesTests {
    typealias ID = FanProfile.BuiltInID

    @Test func sameDayWindowIsHalfOpen() {
        let window = PowerTimeWindow(from: (9, 0), to: (17, 0))
        #expect(!window.contains(date(8, 59), calendar: utcCalendar))
        #expect(window.contains(date(9, 0), calendar: utcCalendar))
        #expect(window.contains(date(16, 59), calendar: utcCalendar))
        #expect(!window.contains(date(17, 0), calendar: utcCalendar))
    }

    @Test func windowWrappingMidnight() {
        let window = PowerTimeWindow(from: (22, 0), to: (7, 0))
        #expect(window.wrapsMidnight)
        #expect(window.contains(date(23, 30), calendar: utcCalendar))
        #expect(window.contains(date(0, 0), calendar: utcCalendar))
        #expect(window.contains(date(6, 59), calendar: utcCalendar))
        #expect(!window.contains(date(7, 0), calendar: utcCalendar))
        #expect(!window.contains(date(21, 59), calendar: utcCalendar))
    }

    @Test func equalStartAndEndIsAllDay() {
        let window = PowerTimeWindow(startMinute: 300, endMinute: 300)
        #expect(window.isAllDay)
        for hour in [0, 5, 12, 23] { #expect(window.contains(date(hour), calendar: utcCalendar)) }
    }

    @Test func weekdaysUseTheDayTheWindowStarted() {
        // Friday night (22:00 Fri – 07:00 Sat), weekday 6 = Friday.
        let window = PowerTimeWindow(from: (22, 0), to: (7, 0), weekdays: [6])
        #expect(window.contains(date(day: 23, 23), calendar: utcCalendar))   // Fri 23:00
        #expect(window.contains(date(day: 24, 3), calendar: utcCalendar))    // Sat 03:00 (Fri's window)
        #expect(!window.contains(date(day: 24, 23), calendar: utcCalendar))  // Sat 23:00
        #expect(!window.contains(date(day: 23, 3), calendar: utcCalendar))   // Fri 03:00 (Thu's window)
        #expect(PowerTimeWindow.previousWeekday(1) == 7)
        #expect(PowerTimeWindow.previousWeekday(2) == 1)
    }

    @Test func windowValuesAreClamped() {
        var window = PowerTimeWindow(startMinute: -5, endMinute: 5000, weekdays: [0, 1, 8])
        #expect(window.startMinute == 0)
        #expect(window.endMinute == PowerTimeWindow.minutesPerDay - 1)
        #expect(window.weekdays == [1])
        window.startMinute = 99_999
        #expect(window.startMinute == PowerTimeWindow.minutesPerDay - 1)
    }

    @Test func conditionsMatch() {
        #expect(PowerSourceCondition.any.matches(.battery))
        #expect(PowerSourceCondition.ac.matches(.ac) && !PowerSourceCondition.ac.matches(.battery))
        #expect(PowerSourceCondition.battery.matches(.battery) && !PowerSourceCondition.battery.matches(.ac))
        #expect(LidCondition.closed.matches(isLidClosed: true))
        #expect(!LidCondition.closed.matches(isLidClosed: false))
        #expect(!LidCondition.closed.matches(isLidClosed: nil))
        #expect(LidCondition.open.matches(isLidClosed: false))
        #expect(LidCondition.open.matches(isLidClosed: nil))  // no lid = not in clamshell mode
        #expect(!LidCondition.open.matches(isLidClosed: true))
    }

    @Test func firstEnabledMatchWins() {
        let battery = PowerProfileRule(name: "Battery", powerSource: .battery, fanProfileID: ID.automatic)
        let clamshell = PowerProfileRule(name: "Clamshell", lid: .closed, fanProfileID: ID.boost)
        let anyAC = PowerProfileRule(name: "AC", powerSource: .ac, fanProfileID: ID.constantQuiet)
        let config = PowerProfileConfiguration(isEnabled: true, rules: [battery, clamshell, anyAC])
        #expect(config.firstMatch(in: context(.battery, lid: true), calendar: utcCalendar)?.name == "Battery")
        #expect(config.firstMatch(in: context(.ac, lid: true), calendar: utcCalendar)?.name == "Clamshell")
        #expect(config.firstMatch(in: context(.ac, lid: false), calendar: utcCalendar)?.name == "AC")

        var disabled = config
        disabled.rules[0].isEnabled = false
        #expect(disabled.firstMatch(in: context(.battery, lid: true), calendar: utcCalendar)?.name == "Clamshell")
        disabled.isEnabled = false
        #expect(disabled.firstMatch(in: context(.ac), calendar: utcCalendar) == nil)
    }

    @Test func timeWindowIsAConditionToo() {
        let night = PowerProfileRule(name: "Night", timeWindow: PowerTimeWindow(from: (22, 0), to: (7, 0)),
                                     fanProfileID: ID.constantQuiet)
        let config = PowerProfileConfiguration(isEnabled: true, rules: [night])
        #expect(config.firstMatch(in: context(at: date(23)), calendar: utcCalendar)?.name == "Night")
        #expect(config.firstMatch(in: context(at: date(12)), calendar: utcCalendar) == nil)
    }

    @Test func catchAllMakesLaterRulesUnreachable() {
        let a = PowerProfileRule(name: "A", powerSource: .battery)
        let all = PowerProfileRule(name: "All")
        let b = PowerProfileRule(name: "B", lid: .closed)
        #expect(all.isCatchAll && !a.isCatchAll)
        #expect(all.hasNoAction)
        #expect(PowerProfileConfiguration(rules: [a, all, b]).unreachableRuleIDs == [b.id])
        var disabledCatchAll = all
        disabledCatchAll.isEnabled = false
        #expect(PowerProfileConfiguration(rules: [a, disabledCatchAll, b]).unreachableRuleIDs.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let config = PowerProfileConfiguration(isEnabled: true, rules: PowerProfileRule.templates())
        let data = try PowerProfileConfiguration.encodeJSON(config)
        #expect(try PowerProfileConfiguration.decodeJSON(data) == config)
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\":1"))
    }

    @Test func decodingIsTolerant() throws {
        let json = """
        {"isEnabled": true, "rules": [
          {"name": "Future", "powerSource": "solar", "lid": "closed", "lowPowerMode": "auto"},
          {"name": "Minimal"}
        ]}
        """
        let config = try PowerProfileConfiguration.decodeJSON(Data(json.utf8))
        #expect(config.isEnabled)
        #expect(config.rules.count == 2)
        #expect(config.rules[0].powerSource == .any)   // unknown case → default
        #expect(config.rules[0].lid == .closed)
        #expect(config.rules[0].lowPowerMode == .unchanged)
        #expect(config.rules[1].isEnabled && config.rules[1].timeWindow == nil && config.rules[1].fanProfileID == nil)
        #expect(try PowerProfileConfiguration.decodeJSON(Data("{}".utf8)) == PowerProfileConfiguration())
    }

    @Test func templatesUseFixedProfiles() {
        let templates = PowerProfileRule.templates()
        #expect(templates.count == 3)
        for template in templates {
            #expect(template.fanProfileID.map(FanProfile.fixedProfileIDs.contains) == true)
        }
        #expect(LowPowerModeAction.on.requestedState == true)
        #expect(LowPowerModeAction.off.requestedState == false)
        #expect(LowPowerModeAction.unchanged.requestedState == nil)
    }
}

@Suite("Profile arbitration (F2)")
struct ProfileArbitrationTests {
    typealias ID = FanProfile.BuiltInID

    @Test func precedenceOrder() {
        #expect(ProfileLayer.manual > .emergency)
        #expect(ProfileLayer.emergency > .workload)
        #expect(ProfileLayer.workload > .power)
        #expect(ProfileLayer.power > .baseline)
    }

    @Test func highestAutomaticClaimWins() {
        var arbitration = ProfileArbitration(baselineProfileID: ID.automatic)
        #expect(arbitration.decision?.layer == .baseline)
        arbitration.setClaim(ProfileClaim(profileID: ID.constantQuiet, reason: "Battery"), for: .power)
        #expect(arbitration.decision?.profileID == ID.constantQuiet)
        arbitration.setClaim(ProfileClaim(profileID: ID.boost, reason: "Xcode"), for: .workload)
        #expect(arbitration.decision?.layer == .workload)
        arbitration.setClaim(ProfileClaim(profileID: ID.max, reason: "Hot"), for: .emergency)
        #expect(arbitration.decision?.profileID == ID.max)
        arbitration.setClaim(nil, for: .emergency)
        arbitration.setClaim(nil, for: .workload)
        #expect(arbitration.decision?.layer == .power)
        arbitration.setClaim(nil, for: .power)
        #expect(arbitration.decision == ProfileDecision(layer: .baseline, profileID: ID.automatic, reason: "Your profile"))
    }

    @Test func manualAndBaselineCannotBeClaimed() {
        var arbitration = ProfileArbitration()
        let claim = ProfileClaim(profileID: ID.max, reason: "x")
        let manual = arbitration.setClaim(claim, for: .manual)
        let baseline = arbitration.setClaim(claim, for: .baseline)
        #expect(!manual && !baseline)
        #expect(arbitration.decision == nil)
        // Re-setting the same claim is not a change.
        let first = arbitration.setClaim(claim, for: .power)
        let second = arbitration.setClaim(claim, for: .power)
        #expect(first && !second)
    }

    @Test func manualWinsUntilTheAutomaticWinnerChanges() {
        var arbitration = ProfileArbitration(baselineProfileID: ID.automatic)
        arbitration.setClaim(ProfileClaim(profileID: ID.constantQuiet, reason: "Battery"), for: .power)
        arbitration.noteManualSelection(ID.max)
        #expect(arbitration.decision?.layer == .manual)
        #expect(arbitration.baselineProfileID == ID.max)
        // Same winner profile with a new reason: still manual.
        arbitration.setClaim(ProfileClaim(profileID: ID.constantQuiet, reason: "Battery 2"), for: .power)
        #expect(arbitration.isManualOverrideActive)
        // A higher claim with another profile is a transition: the override ends.
        arbitration.setClaim(ProfileClaim(profileID: ID.boost, reason: "Hot"), for: .emergency)
        #expect(!arbitration.isManualOverrideActive)
        #expect(arbitration.decision?.layer == .emergency)
        // With no claims left, the manual pick is the baseline.
        arbitration.setClaim(nil, for: .emergency)
        arbitration.setClaim(nil, for: .power)
        #expect(arbitration.decision?.profileID == ID.max)
    }

    @Test func manualWithoutAutomaticEndAndResume() {
        var arbitration = ProfileArbitration(manualEndsOnTransition: false)
        arbitration.setClaim(ProfileClaim(profileID: ID.constantQuiet, reason: "A"), for: .power)
        arbitration.noteManualSelection(ID.max)
        arbitration.setClaim(ProfileClaim(profileID: ID.boost, reason: "B"), for: .power)
        #expect(arbitration.decision?.layer == .manual)
        arbitration.resumeAutomation()
        #expect(arbitration.decision?.profileID == ID.boost)
    }

    @Test func pickingWhatAutomationWantsIsNoOverride() {
        var arbitration = ProfileArbitration()
        arbitration.setClaim(ProfileClaim(profileID: ID.boost, reason: "A"), for: .power)
        arbitration.noteManualSelection(ID.boost)
        #expect(!arbitration.isManualOverrideActive)
        #expect(arbitration.baselineProfileID == ID.boost)
    }
}
