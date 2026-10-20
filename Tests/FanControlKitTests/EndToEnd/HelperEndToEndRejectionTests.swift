#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

/// End-to-end connection failures over a real `NSXPCConnection` to the in-process
/// `FakeHelper`: code-signing requirement mismatches in either direction (sticky
/// rejection) and refused connections (transient backoff).
///
/// Not serialized: every test has its own listener, so the two that wait out the
/// real 2 s backoff (`HelperClient` has no injectable clock) overlap.
@Suite("Helper end-to-end: rejection and backoff", .tags(.endToEnd, .helper, .install))
struct HelperEndToEndRejectionTests {

    /// The app's requirement on the helper fails (`NSXPCConnectionCodeSigningRequirementFailure`):
    /// sticky `.rejected(.helperSignatureMismatch)`, later calls do not connect.
    @Test func helperSignatureMismatchIsStickyRejection() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient {
            $0.setCodeSigningRequirement("identifier \"com.example.not-the-helper\" and anchor apple generic")
        }
        let first = await E2E.failure { try await client.version() }
        #expect(E2E.isRejected(first), "\(String(describing: first))")
        #expect(client.connectionState == .rejected(reason: .helperSignatureMismatch))
        #expect(client.rejection == .helperSignatureMismatch)
        // Observed: the peer still receives (and here answers) the first message; the
        // client-side check discards the reply. Nothing reaches it afterwards.
        #expect(helper.receivedMessages <= 1)
        let received = helper.receivedMessages

        let accepted = helper.acceptedConnections
        let error = await E2E.failure { try await client.openSession(); return (0, "") }
        #expect(E2E.isRejected(error), "\(String(describing: error))")
        #expect(helper.acceptedConnections == accepted, "refused without connecting")
        #expect(helper.receivedMessages == received)
        #expect(client.connectionState == .rejected(reason: .helperSignatureMismatch))

        client.resetRejection()
        #expect(client.connectionState == .disconnected)
        #expect(client.rejection == nil)
    }

    /// The helper's requirement on the client fails: the helper accepts the
    /// connection, then drops it on the first message (seen by the client as an
    /// interruption before any reply). Two such drops in a row are a rejection.
    @Test(.tags(.slow))
    func helperDroppingTheClientBecomesRejection() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .dropOnFirstMessage))
        let client = helper.makeClient()
        let first = await E2E.failure { try await client.version() }
        #expect(helper.receivedMessages == 1)
        #expect(E2E.isConnectionFailed(first), "first drop: transient, backs off (\(String(describing: first)))")
        #expect(client.rejection == nil)
        try await E2E.waitOutFirstBackoff()
        let second = await E2E.failure { try await client.version() }
        #expect(E2E.isRejected(second), "second drop: rejection (\(String(describing: second)))")
        #expect(client.connectionState == .rejected(reason: .droppedByHelper))
    }

    /// The helper's system-enforced client requirement (as `HelperListenerDelegate`
    /// sets it) rejects this process.
    @Test(.tags(.slow))
    func helperClientRequirementRejectsTheApp() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .clientRequirement(
            "identifier \"com.example.not-the-app\" and anchor apple generic")))
        let client = helper.makeClient()
        let first = await E2E.failure { try await client.version() }
        #expect(E2E.isConnectionFailed(first), "\(String(describing: first))")
        try await E2E.waitOutFirstBackoff()
        let second = await E2E.failure { try await client.version() }
        #expect(E2E.isRejected(second), "\(String(describing: second))")
        #expect(helper.receivedMessages == 0, "the system rejected the messages")
        #expect(client.connectionState == .rejected(reason: .droppedByHelper))
    }

    /// A listener that refuses the connection outright invalidates it
    /// (`NSXPCConnectionInvalid`): a transient failure with backoff, not a rejection
    /// (the real helper never refuses; this is what a missing service looks like).
    @Test func listenerRefusingTheConnectionIsTransient() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .refuse))
        let client = helper.makeClient()
        let first = await E2E.failure { try await client.version() }
        #expect(E2E.isConnectionFailed(first), "\(String(describing: first))")
        #expect(helper.receivedMessages == 0)
        #expect(client.rejection == nil)
        if case .error = client.connectionState {} else { Issue.record("expected .error, got \(client.connectionState)") }
        let accepted = helper.acceptedConnections
        let second = await E2E.failure { try await client.version() }
        #expect(E2E.isConnectionFailed(second), "backing off: fails fast (\(String(describing: second)))")
        #expect(helper.acceptedConnections == accepted, "no new connection while backing off")
    }
}
#endif
