#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

// F2: `HelperClient.setLowPowerMode` → real NSXPCConnection → `FakeHelper` → the real
// `LowPowerModeRequestHandler` → a fake pmset. Never runs the real pmset.

/// Fake `/usr/bin/pmset` for `FakeHelper` (`-g custom` prints the per-source settings,
/// `-a|-b|-c lowpowermode 0|1` sets them; `delay` makes every call slow).
final class FakePmsetRunner: CommandRunning {
    struct State {
        var battery = false
        var ac = false
        var calls: [[String]] = []
        var setStatus: Int32 = 0
        var delay: TimeInterval = 0
    }

    private let state = Mutex(State())

    var lowPowerMode: Bool { state.withLock { $0.battery && $0.ac } }
    var settings: (battery: Bool, ac: Bool) { state.withLock { ($0.battery, $0.ac) } }
    var calls: [[String]] { state.withLock { $0.calls } }
    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let delay = state.withLock { $0.delay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return state.withLock { s in
            s.calls.append([executable] + arguments)
            if arguments == LowPowerModeCommand.readCustomArguments {
                return CommandResult(status: 0, standardOutput: """
                    Battery Power:
                     lowpowermode         \(s.battery ? 1 : 0)
                    AC Power:
                     lowpowermode         \(s.ac ? 1 : 0)
                    """)
            }
            guard s.setStatus == 0 else { return CommandResult(status: s.setStatus, standardError: "pmset: failed") }
            let value = arguments.last == "1"
            if arguments.first != "-c" { s.battery = value }
            if arguments.first != "-b" { s.ac = value }
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

    @Test func restoresPerSourceSettings() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.setLowPowerMode(true)
        try await client.setLowPowerMode(battery: true, ac: false)   // "Only on Battery"
        #expect(helper.pmset.settings == (true, false))
        #expect(helper.pmset.calls.last == ["/usr/bin/pmset", "-g", "custom"])
        #expect(helper.pmset.calls.contains(["/usr/bin/pmset", "-c", "lowpowermode", "0"]))
    }

    /// A slow pmset on the separate Low Power Mode client times out there only: the fan
    /// session's connection stays open and keeps answering.
    @Test func slowRequestOnAnIndependentClientKeepsTheSession() async throws {
        let helper = FakeHelper()
        let main = helper.makeClient()
        try await main.openSession()
        let owner = helper.owner
        #expect(owner != nil)

        helper.pmset.update { $0.delay = 0.6 }
        let side = main.makeIndependentClient(callTimeout: 0.2)
        await #expect(throws: FanControlError.self) { try await side.setLowPowerMode(true) }
        side.invalidate()

        #expect(main.isSessionOpen)
        let (version, _) = try await main.version()   // not queued behind pmset
        #expect(version == FanControlHelperConstants.protocolVersion)
        #expect(helper.owner == owner)
        #expect(helper.released.isEmpty)
        try await Task.sleep(for: .milliseconds(1500))   // let the slow request finish
        #expect(helper.owner == owner)
    }

    /// `FanControlManager.setLowPowerMode` uses its own connection, not the session's.
    @MainActor
    @Test func managerSendsTheRequestOnASeparateConnection() async throws {
        let helper = FakeHelper()
        let defaults = ScratchDefaults()
        let manager = FanControlManager(defaults: defaults.defaults, helperClient: helper.makeClient(),
                                        installer: Isolated.installer(), powerSource: MockPowerSource(onBattery: false),
                                        conflictDetector: Isolated.conflictDetector())
        try await manager.helper.client.openSession()
        let owner = helper.owner
        let acceptedBefore = helper.acceptedConnections
        try await manager.setLowPowerMode(battery: true, ac: true)
        #expect(helper.pmset.lowPowerMode)
        #expect(helper.acceptedConnections == acceptedBefore + 1)
        #expect(manager.helper.client.isSessionOpen)
        #expect(helper.owner == owner)
    }

    @Test func helperReportsTheNewProtocolVersion() async throws {
        let helper = FakeHelper()
        let (version, _) = try await helper.makeClient().version()
        #expect(version >= FanControlHelperConstants.lowPowerModeProtocolVersion)
    }
}
#endif
