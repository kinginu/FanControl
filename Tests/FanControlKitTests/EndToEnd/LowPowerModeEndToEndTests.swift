#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

// F2: `HelperClient.setLowPowerMode` → real NSXPCConnection → `FakeHelper` → the real
// `LowPowerModeRequestHandler` → a fake pmset. Never runs the real pmset.

/// Fake `/usr/bin/pmset` for `FakeHelper` (`-g` prints the state, `-a lowpowermode 0|1` sets it).
final class FakePmsetRunner: CommandRunning {
    struct State {
        var lowPowerMode = false
        var calls: [[String]] = []
        var setStatus: Int32 = 0
    }

    private let state = Mutex(State())

    var lowPowerMode: Bool { state.withLock { $0.lowPowerMode } }
    var calls: [[String]] { state.withLock { $0.calls } }
    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        state.withLock { s in
            s.calls.append([executable] + arguments)
            if arguments == LowPowerModeCommand.readArguments {
                return CommandResult(status: 0, standardOutput: "Currently in use:\n lowpowermode         \(s.lowPowerMode ? 1 : 0)\n")
            }
            guard s.setStatus == 0 else { return CommandResult(status: s.setStatus, standardError: "pmset: failed") }
            s.lowPowerMode = arguments.last == "1"
            return CommandResult(status: 0)
        }
    }
}

@Suite("Low Power Mode end-to-end (F2)", .serialized)
struct LowPowerModeEndToEndTests {

    @Test func setsLowPowerModeWithoutASession() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.setLowPowerMode(true)
        #expect(helper.pmset.lowPowerMode)
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)
        #expect(helper.pmset.calls.contains(["/usr/bin/pmset", "-a", "lowpowermode", "1"]))
        try await client.setLowPowerMode(false)
        #expect(!helper.pmset.lowPowerMode)
    }

    @Test func pmsetFailureIsAHelperRejection() async {
        let helper = FakeHelper()
        helper.pmset.update { $0.setStatus = 1 }
        let client = helper.makeClient()
        do {
            try await client.setLowPowerMode(true)
            Issue.record("expected a rejection")
        } catch FanControlError.helperRejected(let code, let message) {
            #expect(code == FanControlHelperErrorCode.commandFailed.rawValue)
            #expect(message.contains("pmset failed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        // A refused request is an answer, not a transport failure.
        #expect(client.connectionState == .connected)
    }

    @Test func helperReportsTheNewProtocolVersion() async throws {
        let helper = FakeHelper()
        let (version, _) = try await helper.makeClient().version()
        #expect(version >= FanControlHelperConstants.lowPowerModeProtocolVersion)
    }
}
#endif
