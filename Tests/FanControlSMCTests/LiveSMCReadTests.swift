#if os(macOS)
import Foundation
import Testing
import FanControlCore
@testable import FanControlSMC

/// Read-only checks against this Mac's real AppleSMC. Never writes. Opt-in so the default suite
/// stays hardware-free:
///
///     FANCONTROL_LIVE_SMC_TESTS=1 swift test --filter LiveSMCReadTests
///
/// Also skipped where the service is absent (e.g. virtual machines).
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["FANCONTROL_LIVE_SMC_TESTS"] == "1",
             "set FANCONTROL_LIVE_SMC_TESTS=1 to read the real SMC"),
    .enabled(if: SMCConnection.isAvailable(), "AppleSMC is not available")
)
struct LiveSMCReadTests {
    @Test func enumeratesAndReadsKeys() throws {
        let client = try SMCClient()
        defer { client.close() }
        let count = try client.keyCount()
        #expect(count > 0)
        #expect(try client.key(at: 0) == "#KEY")
        #expect(try client.keyInfo(.keyCount).dataType == .ui32)
        #expect(throws: FanControlError.self) { try client.key(at: -1) }
        #expect(throws: FanControlError.keyNotFound("zzzz")) { try client.keyInfo("zzzz") }
    }

    @Test func closedClientThrowsSMCUnavailable() throws {
        let client = try SMCClient()
        client.close()
        client.close()
        #expect(throws: FanControlError.smcUnavailable) { try client.keyCount() }
    }

    /// Opening and closing many user clients must not exhaust IOKit resources.
    @Test func repeatedOpenCloseDoesNotLeak() throws {
        for _ in 0..<64 {
            let client = try SMCClient()
            _ = try client.keyCount()
            client.close()
        }
        for _ in 0..<64 {
            _ = try SMCClient().keyCount() // released by deinit
        }
    }
}
#endif
