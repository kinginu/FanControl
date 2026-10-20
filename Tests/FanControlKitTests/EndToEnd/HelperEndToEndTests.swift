#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

/// End-to-end tests of the app ↔ helper contract over a real `NSXPCConnection`
/// (anonymous listener, in-process `FakeHelper`, `FakeSMC`): `HelperClient` +
/// `FanWriteStrategy` on the app side, `HelperWritePolicy` / `PowerTransitionPolicy`
/// on the helper side. No root, no launchd, no SMC hardware.
///
/// `FanControlManager` / `FanControlPoller` are not driven (their reader is the IOKit
/// `SMCClient`); `applyAndRollBack` reproduces `FanControlPoller.applyTargets` +
/// `rollBackFailedWrites` with the same strategy calls.
@Suite("Helper end-to-end (in-process XPC)", .serialized)
struct HelperEndToEndTests {

    // MARK: Helpers

    /// Mirrors `FanControlPoller.applyTargets` (writes in order; on failure, rolls the
    /// pending manual fans back to automatic best-effort and rethrows).
    private func applyAndRollBack(_ targets: [Int: FanTarget], strategy: FanWriteStrategy,
                                  client: HelperClient) async throws {
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

    private func helperCode(_ error: any Error) -> Int? {
        if case FanControlError.helperRejected(let code, _) = error { return code }
        return nil
    }

    private func strategy(_ helper: FakeHelper) -> FanWriteStrategy {
        FanWriteStrategy(reader: helper.smc, fanIndices: [0, 1])
    }

    // MARK: Session + writes

    @Test func versionHandshakeAndOpenSession() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        #expect(client.connectionState == .disconnected)

        let (version, _) = try await client.version()
        #expect(version == FanControlHelperConstants.protocolVersion)
        #expect(client.connectionState == .connected)

        try await client.openSession()
        #expect(client.isSessionOpen)
        #expect(helper.owner?.pid == getpid())
        // Idempotent for the same connection.
        try await client.openSession()
        #expect(helper.acceptedConnections == 1)
        await client.closeSession()
        #expect(helper.owner == nil)
    }

    @Test func applyConstantWritesModeBeforeTarget() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()

        try await applyAndRollBack([0: .manual(rpm: 3000)], strategy: strategy(helper), client: client)
        #expect(helper.smc.writeLog == ["F0Md=1", "F0Tg=3000"])
        #expect(helper.smc.number("F0Md") == 1)
        #expect(helper.smc.number("F0Tg") == 3000)
        #expect(helper.smc.number("F1Md") == 0)  // other fan untouched
        await client.closeSession()
    }

    @Test func writeWithoutSessionFailsLocally() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        await #expect(throws: FanControlError.sessionNotOpen) {
            try await client.write(key: .fanMode(0), bytes: [1])
        }
        #expect(helper.receivedMessages == 0)
        #expect(helper.smc.writeLog.isEmpty)
    }

    @Test func helperValidatesWrites() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()

        // Below the hardware minimum (bypassing FanWriteStrategy's own check).
        do {
            try await client.write(key: .fanTarget(0), bytes: FakeSMC.flt(1000))
            Issue.record("expected a rejection")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.badRequest.rawValue)
        }
        // Not in the allowlist (F<n>Mn is read-only on Apple Silicon).
        do {
            try await client.write(key: .fanMin(0), bytes: FakeSMC.flt(1000))
            Issue.record("expected a rejection")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.keyNotAllowed.rawValue)
        }
        // Mode must be 0 or 1.
        do {
            try await client.write(key: .fanMode(0), bytes: [2])
            Issue.record("expected a rejection")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.badRequest.rawValue)
        }
        #expect(helper.smc.writeLog.isEmpty)
        // A rejected value does not end the session.
        #expect(client.isSessionOpen)
        await client.closeSession()
    }

    @Test func partialFailureRollsBackModeKey() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        helper.smc.failWrites(to: "F0Tg")

        do {
            try await applyAndRollBack([0: .manual(rpm: 3000)], strategy: strategy(helper), client: client)
            Issue.record("expected the F0Tg write to fail")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.smcError.rawValue)
        }
        // Md=1 was accepted, Tg failed, the rollback handed the fan back.
        #expect(helper.smc.writeLog == ["F0Md=1", "F0Md=0"])
        #expect(helper.smc.number("F0Md") == 0)
        #expect(helper.smc.number("F0Tg") == 0)
        #expect(client.isSessionOpen)
        await client.closeSession()
    }

    @Test func closeSessionRestoresModeOnlyNotTarget() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await applyAndRollBack([0: .manual(rpm: 3000), 1: .manual(rpm: 4000)],
                                   strategy: strategy(helper), client: client)
        #expect(helper.smc.writeLog == ["F0Md=1", "F1Md=1", "F0Tg=3000", "F1Tg=4000"])
        helper.smc.clearWriteLog()

        await client.closeSession()
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)
        // Md=0 only: the idle snapshot Tg=0 is never written back (pre-write review HIGH 1).
        #expect(helper.smc.writeLog == ["F0Md=0", "F1Md=0"])
        #expect(helper.smc.number("F0Tg") == 3000)
    }

    @Test func clientDisconnectReleasesSession() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await applyAndRollBack([0: .manual(rpm: 3000)], strategy: strategy(helper), client: client)
        helper.smc.clearWriteLog()

        client.invalidate()
        #expect(!client.isSessionOpen)
        #expect(client.connectionState == .disconnected)
        #expect(await eventually { helper.owner == nil })
        #expect(helper.released.count == 1)
        #expect(helper.smc.writeLog == ["F0Md=0"])

        // The next call reconnects and needs a new session.
        await #expect(throws: FanControlError.sessionNotOpen) {
            try await client.write(key: .fanMode(0), bytes: [1])
        }
        try await client.openSession()
        #expect(helper.acceptedConnections == 2)
        await client.closeSession()
    }

    @Test func clientDeallocationReleasesSession() async throws {
        let helper = FakeHelper()
        do {
            let client = helper.makeClient()
            try await client.openSession()
            try await client.write(key: .fanMode(0), bytes: [1])
        }
        #expect(await eventually { helper.owner == nil })
        #expect(helper.smc.number("F0Md") == 0)
    }

    @Test func hungHelperTimesOutAndSessionIsReleased() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient(timeout: 0.3)
        try await client.openSession()
        try await client.write(key: .fanMode(0), bytes: [1])
        helper.updateConfig { $0.hangingMethods = ["writeKey"] }

        let started = Date()
        do {
            try await client.write(key: .fanTarget(0), bytes: FakeSMC.flt(3000))
            Issue.record("expected a timeout")
        } catch FanControlError.helperConnectionFailed(let reason) {
            #expect(reason == "timeout")
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!client.isSessionOpen)
        // The client invalidated the connection, so the helper hands the fan back.
        #expect(await eventually { helper.owner == nil })
        #expect(helper.smc.number("F0Md") == 0)
        if case .error = client.connectionState {} else if client.connectionState == .disconnected {} else {
            Issue.record("unexpected state \(client.connectionState)")
        }
    }

    @Test func protocolVersionMismatchIsReported() async throws {
        let helper = FakeHelper(config: .init(version: FanControlHelperConstants.protocolVersion + 1))
        let client = helper.makeClient()
        let (version, build) = try await client.version()
        #expect(version == FanControlHelperConstants.protocolVersion + 1)
        #expect(build == "fake")
        // FanControlManager.openSMCSession refuses to open a session on this
        // (manual install) or re-registers once (SMAppService); the client itself
        // stays connected and opened nothing.
        #expect(version != FanControlHelperConstants.protocolVersion)
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)
    }

    @Test func secondProcessIsRefusedWhileSessionIsOwned() async throws {
        let helper = FakeHelper(config: .init(distinctPids: true))
        let first = helper.makeClient()
        let second = helper.makeClient()
        try await first.openSession()

        do {
            try await second.openSession()
            Issue.record("expected notSessionOwner")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.notSessionOwner.rawValue)
        }
        #expect(!second.isSessionOpen)
        #expect(first.isSessionOpen)
        await first.closeSession()
        try await second.openSession()
        await second.closeSession()
    }

    @Test func sameProcessReconnectReclaimsSession() async throws {
        let helper = FakeHelper()
        let stale = helper.makeClient()
        try await stale.openSession()
        try await stale.write(key: .fanMode(0), bytes: [1])
        helper.smc.clearWriteLog()

        let fresh = helper.makeClient()
        try await fresh.openSession()
        // The stale connection's fans were handed back before the new session started.
        #expect(helper.smc.writeLog == ["F0Md=0"])
        #expect(helper.owner?.connectionID == 2)
        // The stale client's next write is refused by the helper and drops its flag.
        do {
            try await stale.write(key: .fanMode(0), bytes: [1])
            Issue.record("expected notSessionOwner")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.notSessionOwner.rawValue)
        }
        #expect(!stale.isSessionOpen)
        await fresh.closeSession()
    }

    @Test func helperShutdownRestores() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await applyAndRollBack([1: .manual(rpm: 5000)], strategy: strategy(helper), client: client)
        helper.smc.clearWriteLog()
        helper.shutdown()  // SIGTERM path
        #expect(helper.smc.writeLog == ["F1Md=0"])
        do {
            try await client.write(key: .fanMode(1), bytes: [1])
            Issue.record("expected sessionNotOpen from the helper")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.sessionNotOpen.rawValue)
        }
        #expect(!client.isSessionOpen)
    }

    @Test func sleepHandsBackAndWakeReapplies() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await applyAndRollBack([0: .manual(rpm: 3000)], strategy: strategy(helper), client: client)
        helper.smc.clearWriteLog()

        helper.prepareForSleep()
        #expect(helper.smc.writeLog == ["F0Md=0"])
        // Observed on Mac14,9: the SMC resets Tg to 0 on wake (Md stays as written).
        helper.smc.poke("F0Tg", FakeSMC.flt(0))
        helper.smc.clearWriteLog()
        helper.recoverAfterWake()
        #expect(helper.smc.writeLog == ["F0Md=1", "F0Tg=3000"])

        // The other observed case: Md kept at 1, Tg reset to 0 → only Tg is rewritten.
        helper.smc.poke("F0Tg", FakeSMC.flt(0))
        helper.smc.clearWriteLog()
        helper.recoverAfterWake()
        #expect(helper.smc.writeLog == ["F0Tg=3000"])
        #expect(client.isSessionOpen)
        await client.closeSession()
        #expect(helper.smc.number("F0Md") == 0)
    }

    @Test func keyInfoThroughHelper() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        let info = try await client.keyInfo(.fanTarget(0))
        #expect(info.dataSize == 4)
        #expect(info.dataType == .flt)
        #expect(info.isWritable)
        do {
            _ = try await client.keyInfo("ZZZZ")
            Issue.record("expected invalidKey")
        } catch {
            #expect(helperCode(error) == FanControlHelperErrorCode.invalidKey.rawValue)
        }
    }

    // MARK: Rejection (code-signing requirement)

    /// The app's requirement on the helper fails (`NSXPCConnectionCodeSigningRequirementFailure`):
    /// sticky `.rejected(.helperSignatureMismatch)`, later calls do not connect.
    @Test func helperSignatureMismatchIsStickyRejection() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient {
            $0.setCodeSigningRequirement("identifier \"com.example.not-the-helper\" and anchor apple generic")
        }
        do {
            _ = try await client.version()
            Issue.record("expected a rejection")
        } catch FanControlError.helperConnectionRejected {}
        #expect(client.connectionState == .rejected(reason: .helperSignatureMismatch))
        #expect(client.rejection == .helperSignatureMismatch)
        // Observed: the peer still receives (and here answers) the first message; the
        // client-side check discards the reply. Nothing reaches it afterwards.
        #expect(helper.receivedMessages <= 1)
        let received = helper.receivedMessages

        let accepted = helper.acceptedConnections
        await #expect(throws: FanControlError.self) { try await client.openSession() }
        #expect(helper.acceptedConnections == accepted)  // refused without connecting
        #expect(helper.receivedMessages == received)
        #expect(client.connectionState == .rejected(reason: .helperSignatureMismatch))

        client.resetRejection()
        #expect(client.connectionState == .disconnected)
        #expect(client.rejection == nil)
    }

    /// The helper's requirement on the client fails: the helper accepts the
    /// connection, then drops it on the first message (seen by the client as an
    /// interruption before any reply). Two such drops in a row are a rejection.
    @Test func helperDroppingTheClientBecomesRejection() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .dropOnFirstMessage))
        let client = helper.makeClient()
        let first = await Self.failure { try await client.version() }
        #expect(helper.receivedMessages == 1)
        #expect(Self.isConnectionFailed(first))  // first drop: transient, backs off
        #expect(client.rejection == nil)
        // Wait out the 2 s transient backoff, then fail again.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let second = await Self.failure { try await client.version() }
        #expect(Self.isRejected(second))
        #expect(client.connectionState == .rejected(reason: .droppedByHelper))
    }

    /// The helper's system-enforced client requirement (as `HelperListenerDelegate`
    /// sets it) rejects this process.
    @Test func helperClientRequirementRejectsTheApp() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .clientRequirement(
            "identifier \"com.example.not-the-app\" and anchor apple generic")))
        let client = helper.makeClient()
        let first = await Self.failure { try await client.version() }
        #expect(Self.isConnectionFailed(first))
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let second = await Self.failure { try await client.version() }
        #expect(Self.isRejected(second))
        #expect(helper.receivedMessages == 0)  // the system rejected the messages
        #expect(client.connectionState == .rejected(reason: .droppedByHelper))
    }

    /// A listener that refuses the connection outright invalidates it
    /// (`NSXPCConnectionInvalid`): a transient failure with backoff, not a rejection
    /// (the real helper never refuses; this is what a missing service looks like).
    @Test func listenerRefusingTheConnectionIsTransient() async throws {
        let helper = FakeHelper(config: .init(acceptMode: .refuse))
        let client = helper.makeClient()
        let first = await Self.failure { try await client.version() }
        #expect(Self.isConnectionFailed(first))
        #expect(helper.receivedMessages == 0)
        #expect(client.rejection == nil)
        if case .error = client.connectionState {} else { Issue.record("state \(client.connectionState)") }
        // Backing off: the next call fails fast without connecting.
        let accepted = helper.acceptedConnections
        let second = await Self.failure { try await client.version() }
        #expect(Self.isConnectionFailed(second))
        #expect(helper.acceptedConnections == accepted)
    }

    private static func failure(_ body: () async throws -> (Int, String)) async -> (any Error)? {
        do { _ = try await body(); return nil } catch { return error }
    }

    private static func isConnectionFailed(_ error: (any Error)?) -> Bool {
        if case FanControlError.helperConnectionFailed? = error { return true }
        return false
    }

    private static func isRejected(_ error: (any Error)?) -> Bool {
        if case FanControlError.helperConnectionRejected? = error { return true }
        return false
    }
}
#endif
