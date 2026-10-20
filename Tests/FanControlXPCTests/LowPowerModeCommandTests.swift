import Foundation
import Synchronization
import Testing
@testable import FanControlXPC

// F2: the helper's Low Power Mode request (`LowPowerModeCommand`, `LowPowerModeRequestHandler`)
// against a fake pmset. No real pmset write is ever made by these tests.

/// `pmset -g` as printed by Mac14,9 / macOS 26 (2026-10-20), with the in-use and the
/// per-source values substituted.
func pmsetOutput(inUse: Int, battery: Int = 0, ac: Int = 0) -> String {
    """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     sleep                1 (sleep prevented by caffeinate)
     hibernatemode        3
     displaysleep         10
     tcpkeepalive         1
     lowpowermode         \(inUse)
     womp                 1
    Battery Power:
     Sleep On Power Button 1
     lowpowermode         \(battery)
     standby              1
    AC Power:
     Sleep On Power Button 1
     lowpowermode         \(ac)
     standby              1
    """
}

/// `pmset -g custom` as printed by Mac14,9 / macOS 26.5.2 (2026-10-21), with the per-source
/// values substituted; `battery: nil` drops the "Battery Power:" section (a desktop Mac).
func pmsetCustomOutput(battery: Int?, ac: Int) -> String {
    let batterySection = battery.map { value in
        """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         \(value)
         standby              1
         displaysleep         5

        """
    } ?? ""
    return batterySection + """
        AC Power:
         Sleep On Power Button 1
         lowpowermode         \(ac)
         standby              1
         displaysleep         10
        """
}

/// Fake `/usr/bin/pmset`: `-g custom` prints the per-source settings, `-a|-b|-c lowpowermode
/// 0|1` changes them.
final class FakePmset: CommandRunning {
    struct State {
        var battery = false
        var ac = false
        var hasBattery = true
        var calls: [[String]] = []
        var setStatus: Int32 = 0
        /// pmset "succeeds" but the value does not change (read-back mismatch).
        var ignoresSet = false
        var readStatus: Int32 = 0
        var readOutput: String?
    }

    let state = Mutex(State())

    var calls: [[String]] { state.withLock { $0.calls } }
    /// Both sources on (what `-a lowpowermode 1` leaves).
    var lowPowerMode: Bool { state.withLock { $0.battery && $0.ac } }
    var settings: (battery: Bool, ac: Bool) { state.withLock { ($0.battery, $0.ac) } }
    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        state.withLock { s in
            s.calls.append([executable] + arguments)
            if arguments == ["-g", "custom"] {
                guard s.readStatus == 0 else { return CommandResult(status: s.readStatus) }
                return CommandResult(status: 0, standardOutput: s.readOutput
                                     ?? pmsetCustomOutput(battery: s.hasBattery ? (s.battery ? 1 : 0) : nil, ac: s.ac ? 1 : 0))
            }
            if arguments.count == 3, ["-a", "-b", "-c"].contains(arguments[0]), arguments[1] == "lowpowermode" {
                guard s.setStatus == 0 else {
                    return CommandResult(status: s.setStatus, standardError: "pmset: must be run as root\nmore")
                }
                guard !s.ignoresSet else { return CommandResult(status: 0) }
                let value = arguments[2] == "1"
                if arguments[0] != "-c" { s.battery = value }
                if arguments[0] != "-b" { s.ac = value }
                return CommandResult(status: 0)
            }
            return CommandResult(status: 64, standardError: "unexpected")
        }
    }
}

final class FakeClock: Sendable {
    let now = Mutex<TimeInterval>(1000)
    func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
    var closure: @Sendable () -> TimeInterval { { [self] in now.withLock { $0 } } }
}

@Suite("Low Power Mode command (F2)")
struct LowPowerModeCommandTests {

    @Test func setArgumentsAreFixed() {
        #expect(LowPowerModeCommand.pmsetPath == "/usr/bin/pmset")
        #expect(LowPowerModeCommand.setArguments(enabled: true) == ["-a", "lowpowermode", "1"])
        #expect(LowPowerModeCommand.setArguments(enabled: false) == ["-a", "lowpowermode", "0"])
        #expect(LowPowerModeCommand.setArguments(.battery, enabled: true) == ["-b", "lowpowermode", "1"])
        #expect(LowPowerModeCommand.setArguments(.ac, enabled: false) == ["-c", "lowpowermode", "0"])
        #expect(LowPowerModeCommand.readArguments == ["-g"])
        #expect(LowPowerModeCommand.readCustomArguments == ["-g", "custom"])
    }

    @Test func allowlistAcceptsOnlyTheFixedInvocations() {
        let pmset = LowPowerModeCommand.pmsetPath
        #expect(LowPowerModeCommand.allowedInvocations.count == 7)
        for flag in ["-a", "-b", "-c"] {
            #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: [flag, "lowpowermode", "1"]))
            #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: [flag, "lowpowermode", "0"]))
        }
        #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-g", "custom"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-g"]))  // the helper reads per source
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-u", "lowpowermode", "1"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-b", "sleep", "0"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-a", "sleep", "0"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-a", "lowpowermode", "2"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-a", "lowpowermode", "1", "-b"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: "pmset", arguments: ["-g"]))
        #expect(!LowPowerModeCommand.isAllowed(executable: "/bin/sh", arguments: ["-c", "pmset -g"]))
    }

    @Test func parsesTheInUseSection() {
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: pmsetOutput(inUse: 0)) == false)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: pmsetOutput(inUse: 1)) == true)
        // The in-use value wins over the per-source sections.
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: pmsetOutput(inUse: 0, battery: 1, ac: 1)) == false)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: pmsetOutput(inUse: 1, battery: 0, ac: 0)) == true)
    }

    @Test func parsesFallbacks() {
        // No "Currently in use" header: any lowpowermode line.
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: " lowpowermode 1\n") == true)
        // powermode (High Power Mode Macs): 1 = low power.
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: "Currently in use:\n powermode 1\n") == true)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: "Currently in use:\n powermode 2\n") == false)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: "Currently in use:\n sleep 1\n") == nil)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: " lowpowermode yes\n") == nil)
        #expect(LowPowerModeCommand.parseLowPowerMode(pmsetOutput: "") == nil)
    }

    @Test func parsesThePerSourceSections() {
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: pmsetCustomOutput(battery: 1, ac: 0))
                == LowPowerModeSettings(battery: true, ac: false))
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: pmsetCustomOutput(battery: 0, ac: 1))
                == LowPowerModeSettings(battery: false, ac: true))
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: pmsetCustomOutput(battery: nil, ac: 1))
                == LowPowerModeSettings(battery: nil, ac: true))
        // `pmset -g` output also has the sections (after "Currently in use").
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: pmsetOutput(inUse: 0, battery: 1, ac: 0))
                == LowPowerModeSettings(battery: true, ac: false))
        // powermode (High Power Mode Macs): 1 = low power.
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: "Battery Power:\n powermode 1\nAC Power:\n powermode 2\n")
                == LowPowerModeSettings(battery: true, ac: false))
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: "AC Power:\n sleep 1\n") == nil)
        #expect(LowPowerModeCommand.parseSettings(pmsetCustomOutput: "") == nil)
    }

    @Test func writesUseAllSourcesWhenEqualAndPerSourceOtherwise() {
        let both = LowPowerModeSettings(battery: false, ac: false)
        #expect(LowPowerModeCommand.writes(battery: true, ac: true, current: both) == [["-a", "lowpowermode", "1"]])
        #expect(LowPowerModeCommand.writes(battery: true, ac: false, current: both) == [["-b", "lowpowermode", "1"]])
        #expect(LowPowerModeCommand.writes(battery: true, ac: false, current: nil)
                == [["-b", "lowpowermode", "1"], ["-c", "lowpowermode", "0"]])
        #expect(LowPowerModeCommand.writes(battery: false, ac: true, current: LowPowerModeSettings(battery: true, ac: true))
                == [["-b", "lowpowermode", "0"]])
        // No battery section: only the AC value is written.
        #expect(LowPowerModeCommand.writes(battery: true, ac: false, current: LowPowerModeSettings(battery: nil, ac: true))
                == [["-c", "lowpowermode", "0"]])
        for writes in [LowPowerModeCommand.writes(battery: true, ac: false, current: nil)] {
            for arguments in writes {
                #expect(LowPowerModeCommand.isAllowed(executable: LowPowerModeCommand.pmsetPath, arguments: arguments))
            }
        }
    }

    @Test func worstCaseStaysInsideTheClientTimeout() {
        // Even with one request queued ahead (the handler serializes requests).
        #expect(LowPowerModeRequestHandler.worstCaseDuration == 12)
        #expect(2 * LowPowerModeRequestHandler.worstCaseDuration < LowPowerModeCommand.clientCallTimeout)
    }

    @Test func handlerRestoresPerSourceSettings() {
        let pmset = FakePmset()
        pmset.update { $0.battery = true; $0.ac = true }
        let handler = LowPowerModeRequestHandler(runner: pmset)
        let result = handler.handle(battery: true, ac: false, requester: "pid 7")
        #expect(result.code == .ok)
        #expect(result.message == "Low Power Mode on on battery power, off on AC power.")
        #expect(pmset.settings == (true, false))
        #expect(pmset.calls == [["/usr/bin/pmset", "-g", "custom"],
                                ["/usr/bin/pmset", "-c", "lowpowermode", "0"],
                                ["/usr/bin/pmset", "-g", "custom"]])
    }

    @Test func handlerSetsAndReadsBack() {
        let pmset = FakePmset()
        let logs = Mutex<[String]>([])
        let handler = LowPowerModeRequestHandler(runner: pmset, log: { _, line in logs.withLock { $0.append(line) } })
        let result = handler.handle(enabled: true, requester: "pid 42")
        #expect(result.code == .ok)
        #expect(pmset.lowPowerMode)
        #expect(pmset.calls == [["/usr/bin/pmset", "-g", "custom"],
                                ["/usr/bin/pmset", "-a", "lowpowermode", "1"],
                                ["/usr/bin/pmset", "-g", "custom"]])
        let lines = logs.withLock { $0 }
        #expect(lines.first == "pid 42 requests Low Power Mode on")
        #expect(lines.last == "Low Power Mode is now on (read back)")
    }

    @Test func handlerSkipsTheWriteWhenAlreadySet() {
        let pmset = FakePmset()
        let handler = LowPowerModeRequestHandler(runner: pmset)
        let result = handler.handle(enabled: false, requester: "test")
        #expect(result.code == .ok)
        #expect(result.message.contains("already off"))
        #expect(pmset.calls == [["/usr/bin/pmset", "-g", "custom"]])
    }

    @Test func handlerReportsPmsetFailure() {
        let pmset = FakePmset()
        pmset.update { $0.setStatus = 1 }
        let handler = LowPowerModeRequestHandler(runner: pmset)
        let result = handler.handle(enabled: true, requester: "test")
        #expect(result.code == .commandFailed)
        #expect(result.message == "pmset failed (status 1): pmset: must be run as root")
        #expect(!pmset.lowPowerMode)
    }

    @Test func handlerReportsReadBackMismatch() {
        let pmset = FakePmset()
        pmset.update { $0.ignoresSet = true }
        let result = LowPowerModeRequestHandler(runner: pmset).handle(enabled: true, requester: "test")
        #expect(result.code == .commandFailed)
        #expect(result.message.contains("did not change"))
    }

    @Test func handlerAcceptsAnUnreadableState() {
        let pmset = FakePmset()
        pmset.update { $0.readOutput = "System-wide power settings:\n" }   // no per-source sections
        let result = LowPowerModeRequestHandler(runner: pmset).handle(enabled: true, requester: "test")
        #expect(result.code == .ok)
        #expect(result.message.contains("not confirmed"))
        #expect(pmset.lowPowerMode)
    }

    @Test func handlerRateLimitsWrites() {
        let pmset = FakePmset()
        let clock = FakeClock()
        let handler = LowPowerModeRequestHandler(runner: pmset, clock: clock.closure, maxWrites: 3, rateWindow: 60)
        for index in 0..<3 {
            #expect(handler.handle(enabled: index % 2 == 0, requester: "test").code == .ok)
        }
        // Fourth change within the window: refused without running the write.
        let writesBefore = pmset.calls.filter { $0.count == 4 }.count
        #expect(handler.handle(enabled: false, requester: "test").code == .rateLimited)
        #expect(pmset.calls.filter { $0.count == 4 }.count == writesBefore)
        // A no-op request (already in that state) is still answered.
        #expect(handler.handle(enabled: true, requester: "test").code == .ok)
        clock.advance(61)
        #expect(handler.handle(enabled: false, requester: "test").code == .ok)
        #expect(!pmset.lowPowerMode)
    }

    @Test func trimmedKeepsTheFirstLine() {
        #expect(LowPowerModeRequestHandler.trimmed("  a  \nb") == "a")
        #expect(LowPowerModeRequestHandler.trimmed(String(repeating: "x", count: 500)).count == 200)
        #expect(LowPowerModeRequestHandler.trimmed("") == "")
    }

    @Test func newErrorCodesAreDistinct() {
        #expect(FanControlHelperErrorCode.commandFailed.rawValue == 8)
        #expect(FanControlHelperErrorCode.rateLimited.rawValue == 9)
        #expect(FanControlHelperConstants.lowPowerModeProtocolVersion <= FanControlHelperConstants.protocolVersion)
    }
}
