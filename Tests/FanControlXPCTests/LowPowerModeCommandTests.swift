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

/// Fake `/usr/bin/pmset`: `-g` prints the state, `-a lowpowermode 0|1` changes it.
final class FakePmset: CommandRunning {
    struct State {
        var lowPowerMode = false
        var calls: [[String]] = []
        var setStatus: Int32 = 0
        /// pmset "succeeds" but the value does not change (read-back mismatch).
        var ignoresSet = false
        var readStatus: Int32 = 0
        var readOutput: String?
    }

    let state = Mutex(State())

    var calls: [[String]] { state.withLock { $0.calls } }
    var lowPowerMode: Bool { state.withLock { $0.lowPowerMode } }
    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        state.withLock { s in
            s.calls.append([executable] + arguments)
            if arguments == ["-g"] {
                guard s.readStatus == 0 else { return CommandResult(status: s.readStatus) }
                return CommandResult(status: 0, standardOutput: s.readOutput ?? pmsetOutput(inUse: s.lowPowerMode ? 1 : 0))
            }
            if arguments.count == 3, arguments[0] == "-a", arguments[1] == "lowpowermode" {
                guard s.setStatus == 0 else {
                    return CommandResult(status: s.setStatus, standardError: "pmset: must be run as root\nmore")
                }
                if !s.ignoresSet { s.lowPowerMode = arguments[2] == "1" }
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
        #expect(LowPowerModeCommand.readArguments == ["-g"])
    }

    @Test func allowlistAcceptsOnlyTheThreeInvocations() {
        let pmset = LowPowerModeCommand.pmsetPath
        #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-a", "lowpowermode", "1"]))
        #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-a", "lowpowermode", "0"]))
        #expect(LowPowerModeCommand.isAllowed(executable: pmset, arguments: ["-g"]))
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

    @Test func handlerSetsAndReadsBack() {
        let pmset = FakePmset()
        let logs = Mutex<[String]>([])
        let handler = LowPowerModeRequestHandler(runner: pmset, log: { _, line in logs.withLock { $0.append(line) } })
        let result = handler.handle(enabled: true, requester: "pid 42")
        #expect(result.code == .ok)
        #expect(pmset.lowPowerMode)
        #expect(pmset.calls == [["/usr/bin/pmset", "-g"],
                                ["/usr/bin/pmset", "-a", "lowpowermode", "1"],
                                ["/usr/bin/pmset", "-g"]])
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
        #expect(pmset.calls == [["/usr/bin/pmset", "-g"]])
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
        pmset.update { $0.readOutput = "System-wide power settings:\n" }
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
