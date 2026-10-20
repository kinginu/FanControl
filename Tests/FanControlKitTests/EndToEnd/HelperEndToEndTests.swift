#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

/// End-to-end tests of the app ↔ helper contract over a real `NSXPCConnection`
/// (anonymous listener, in-process `FakeHelper`, `FakeSMC`): `HelperClient` +
/// `FanWriteStrategy` on the app side, `HelperWritePolicy` / `PowerTransitionPolicy`
/// on the helper side. No root, no launchd, no Mach service, no SMC hardware: every
/// client comes from `FakeHelper.makeClient` (`HelperClient(connectionFactory:)`).
///
/// `FanControlManager` / `FanControlPoller` are not driven (their reader is the IOKit
/// `SMCClient`); `E2E.applyAndRollBack` reproduces `FanControlPoller.applyTargets` +
/// `rollBackFailedWrites` with the same strategy calls. Code-signing rejection and
/// backoff: `HelperEndToEndRejectionTests`.
@Suite("Helper end-to-end: sessions and writes", .serialized, .tags(.endToEnd, .helper))
struct HelperEndToEndTests {

    // MARK: Session + writes

    @Test func versionHandshakeAndOpenSession() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        #expect(client.connectionState == .disconnected, "the client never connects on its own")

        let (version, _) = try await client.version()
        #expect(version == FanControlHelperConstants.protocolVersion)
        #expect(client.connectionState == .connected)

        try await client.openSession()
        #expect(client.isSessionOpen)
        #expect(helper.owner?.pid == getpid())
        try await client.openSession()
        #expect(helper.acceptedConnections == 1, "openSession is idempotent on the same connection")
        await client.closeSession()
        #expect(helper.owner == nil)
    }

    @Test func applyConstantWritesModeBeforeTarget() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()

        try await E2E.applyAndRollBack([0: .manual(rpm: 3000)], helper: helper, client: client)
        #expect(helper.smc.writeLog == ["F0Md=1", "F0Tg=3000"])
        #expect(helper.smc.number("F0Md") == 1)
        #expect(helper.smc.number("F0Tg") == 3000)
        #expect(helper.smc.number("F1Md") == 0, "the other fan is untouched")
        await client.closeSession()
    }

    @Test func writeWithoutSessionFailsLocally() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        await #expect(throws: FanControlError.sessionNotOpen) {
            try await client.write(key: .fanMode(0), bytes: [1])
        }
        #expect(helper.receivedMessages == 0, "refused before anything is sent")
        #expect(helper.smc.writeLog.isEmpty)
    }

    @Test func helperValidatesWrites() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()

        await E2E.expectHelperRejection(.badRequest, "below the hardware minimum (bypassing FanWriteStrategy)") {
            try await client.write(key: .fanTarget(0), bytes: FakeSMC.flt(1000))
        }
        await E2E.expectHelperRejection(.keyNotAllowed, "F<n>Mn is read-only on Apple Silicon") {
            try await client.write(key: .fanMin(0), bytes: FakeSMC.flt(1000))
        }
        await E2E.expectHelperRejection(.badRequest, "mode must be 0 or 1") {
            try await client.write(key: .fanMode(0), bytes: [2])
        }
        #expect(helper.smc.writeLog.isEmpty)
        #expect(client.isSessionOpen, "a rejected value does not end the session")
        await client.closeSession()
    }

    @Test func partialFailureRollsBackModeKey() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        helper.smc.failWrites(to: "F0Tg")

        await E2E.expectHelperRejection(.smcError, "the F0Tg write fails at the SMC") {
            try await E2E.applyAndRollBack([0: .manual(rpm: 3000)], helper: helper, client: client)
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
        try await E2E.applyAndRollBack([0: .manual(rpm: 3000), 1: .manual(rpm: 4000)], helper: helper, client: client)
        #expect(helper.smc.writeLog == ["F0Md=1", "F1Md=1", "F0Tg=3000", "F1Tg=4000"])
        helper.smc.clearWriteLog()

        await client.closeSession()
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)
        #expect(helper.smc.writeLog == ["F0Md=0", "F1Md=0"],
                "Md=0 only: the idle snapshot Tg=0 is never written back (pre-write review HIGH 1)")
        #expect(helper.smc.number("F0Tg") == 3000)
    }

    @Test func clientDisconnectReleasesSession() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await E2E.applyAndRollBack([0: .manual(rpm: 3000)], helper: helper, client: client)
        helper.smc.clearWriteLog()

        client.invalidate()
        #expect(!client.isSessionOpen)
        #expect(client.connectionState == .disconnected)
        #expect(await eventually { helper.owner == nil }, "the helper releases the session of a lost connection")
        #expect(helper.released.count == 1)
        #expect(helper.smc.writeLog == ["F0Md=0"])

        await #expect(throws: FanControlError.sessionNotOpen, "the next call reconnects and needs a new session") {
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
        #expect(await eventually { helper.owner == nil }, "deinit invalidates the connection")
        #expect(helper.smc.number("F0Md") == 0)
    }

    @Test func hungHelperTimesOutAndSessionIsReleased() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await client.write(key: .fanMode(0), bytes: [1])
        // Short timeout only for the hung call (setup keeps the default 5 s, so a busy machine cannot fail it).
        client.callTimeout = 0.3
        helper.updateConfig { $0.hangingMethods = ["writeKey"] }

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: FanControlError.helperConnectionFailed("timeout")) {
            try await client.write(key: .fanTarget(0), bytes: FakeSMC.flt(3000))
        }
        #expect(clock.now - started < .seconds(3), "the call timeout, not the XPC default, ended the call")
        #expect(!client.isSessionOpen)
        #expect(await eventually { helper.owner == nil }, "the client invalidated the connection")
        #expect(helper.smc.number("F0Md") == 0, "the helper handed the fan back")
        #expect(E2E.isErrorOrDisconnected(client.connectionState), "state \(client.connectionState)")
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
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)
    }

    @Test func secondProcessIsRefusedWhileSessionIsOwned() async throws {
        let helper = FakeHelper(config: .init(distinctPids: true))
        let first = helper.makeClient()
        let second = helper.makeClient()
        try await first.openSession()

        await E2E.expectHelperRejection(.notSessionOwner) { try await second.openSession() }
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
        #expect(helper.smc.writeLog == ["F0Md=0"], "the stale connection's fans are handed back first")
        #expect(helper.owner?.connectionID == 2)
        await E2E.expectHelperRejection(.notSessionOwner, "the stale client is refused") {
            try await stale.write(key: .fanMode(0), bytes: [1])
        }
        #expect(!stale.isSessionOpen, "the refusal drops the stale client's session flag")
        await fresh.closeSession()
    }

    @Test func helperShutdownRestores() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await E2E.applyAndRollBack([1: .manual(rpm: 5000)], helper: helper, client: client)
        helper.smc.clearWriteLog()
        helper.shutdown()  // SIGTERM path
        #expect(helper.smc.writeLog == ["F1Md=0"])
        await E2E.expectHelperRejection(.sessionNotOpen) { try await client.write(key: .fanMode(1), bytes: [1]) }
        #expect(!client.isSessionOpen)
    }

    @Test(.tags(.power))
    func sleepHandsBackAndWakeReapplies() async throws {
        let helper = FakeHelper()
        let client = helper.makeClient()
        try await client.openSession()
        try await E2E.applyAndRollBack([0: .manual(rpm: 3000)], helper: helper, client: client)
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
        await E2E.expectHelperRejection(.invalidKey) { _ = try await client.keyInfo("ZZZZ") }
    }
}
#endif
