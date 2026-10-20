#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

/// Shared steps of the end-to-end suites (`HelperEndToEndTests`, `HelperEndToEndRejectionTests`).
enum E2E {

    /// Mirrors `FanControlPoller.applyTargets` + `rollBackFailedWrites`: writes in
    /// order; on failure rolls the pending manual fans back to automatic best-effort
    /// and rethrows.
    static func applyAndRollBack(_ targets: [Int: FanTarget], helper: FakeHelper,
                                 client: HelperClient) async throws {
        let strategy = FanWriteStrategy(reader: helper.smc, fanIndices: [0, 1])
        let writes = try strategy.writes(for: targets)
        do {
            for (key, bytes) in writes { try await client.write(key: key, bytes: bytes) }
        } catch {
            if client.isSessionOpen {
                for (key, bytes) in (try? strategy.rollbackWrites(afterFailureOf: targets)) ?? [] {
                    do { try await client.write(key: key, bytes: bytes) } catch { break }
                }
            }
            throw error
        }
    }

    /// Expects `body` to fail with `FanControlError.helperRejected` carrying `code`.
    static func expectHelperRejection(_ code: FanControlHelperErrorCode, _ comment: Comment? = nil,
                                      sourceLocation: SourceLocation = #_sourceLocation,
                                      _ body: () async throws -> Void) async {
        let error = await #expect(throws: FanControlError.self, comment, sourceLocation: sourceLocation) {
            try await body()
        }
        guard case .helperRejected(let actual, let message)? = error else {
            if let error {
                Issue.record("expected helper code \(code), got \(error)", sourceLocation: sourceLocation)
            }
            return
        }
        #expect(actual == code.rawValue, "helper replied \(actual) (\(message))", sourceLocation: sourceLocation)
    }

    /// The error of a `version()` call, or `nil` if it succeeded.
    static func failure(of body: () async throws -> (Int, String)) async -> (any Error)? {
        do { _ = try await body(); return nil } catch { return error }
    }

    static func isConnectionFailed(_ error: (any Error)?) -> Bool {
        if case FanControlError.helperConnectionFailed? = error { return true }
        return false
    }

    static func isRejected(_ error: (any Error)?) -> Bool {
        if case FanControlError.helperConnectionRejected? = error { return true }
        return false
    }

    /// `.error` or `.disconnected`: what a client shows after a transient failure.
    static func isErrorOrDisconnected(_ state: HelperConnectionState) -> Bool {
        if case .error = state { return true }
        return state == .disconnected
    }

    /// Waits out the gate's first transient backoff. `HelperClient` reads the
    /// monotonic `systemUptime` with no injectable clock, so this is a real wait,
    /// derived from the policy (not a magic number) plus a scheduling margin.
    static func waitOutFirstBackoff() async throws {
        let backoff = HelperConnectionGate.Policy.default.initialBackoff
        try await Task.sleep(for: .seconds(backoff) + .milliseconds(150))
    }
}
#endif
