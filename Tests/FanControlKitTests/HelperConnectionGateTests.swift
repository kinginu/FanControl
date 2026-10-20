import Foundation
import Testing
import FanControlXPC
@testable import FanControlKit

/// Retry / rejection state machine of `HelperClient` (mocked connection outcomes).
struct HelperConnectionGateTests {
    private static let install = "manual|791@1000|1340624@1000"
    private static let reinstalled = "manual|791@2000|1340624@2000"

    @Test func testFreshGateProceeds() {
        var gate = HelperConnectionGate()
        #expect(gate.decide(now: 0, fingerprint: Self.install) == .proceed)
        #expect(gate.rejection == nil)
    }

    @Test func testBackoffIsExponentialAndCapped() {
        let gate = HelperConnectionGate()
        #expect(gate.backoffDelay(afterFailures: 0) == 0)
        #expect(gate.backoffDelay(afterFailures: 1) == 2)
        #expect(gate.backoffDelay(afterFailures: 2) == 4)
        #expect(gate.backoffDelay(afterFailures: 3) == 8)
        #expect(gate.backoffDelay(afterFailures: 8) == 256)
        #expect(gate.backoffDelay(afterFailures: 9) == 300)
        #expect(gate.backoffDelay(afterFailures: 10_000) == 300)
    }

    @Test func testTransientFailuresBackOff() {
        var gate = HelperConnectionGate()
        #expect(gate.recordFailure(.transient, now: 100, fingerprint: Self.install) == nil)
        #expect(gate.decide(now: 101, fingerprint: Self.install) == .backingOff(remaining: 1))
        #expect(gate.decide(now: 102, fingerprint: Self.install) == .proceed)
        gate.recordFailure(.transient, now: 102, fingerprint: Self.install)
        #expect(gate.decide(now: 105, fingerprint: Self.install) == .backingOff(remaining: 1))
        #expect(gate.decide(now: 106, fingerprint: Self.install) == .proceed)
        #expect(gate.consecutiveFailures == 2)
        #expect(gate.rejection == nil)
    }

    @Test func testSuccessResetsBackoff() {
        var gate = HelperConnectionGate()
        gate.recordFailure(.transient, now: 0, fingerprint: Self.install)
        gate.recordFailure(.droppedWithoutReply, now: 0, fingerprint: Self.install)
        gate.recordSuccess()
        #expect(gate.consecutiveFailures == 0)
        #expect(gate.consecutiveDrops == 0)
        #expect(gate.decide(now: 0, fingerprint: Self.install) == .proceed)
    }

    /// What the 11:20 log showed: the helper accepts, then drops the peer right after
    /// the first message. Two such drops in a row are a sticky rejection.
    @Test func testRepeatedDropsWithoutReplyBecomeRejection() {
        var gate = HelperConnectionGate()
        #expect(gate.recordFailure(.droppedWithoutReply, now: 0, fingerprint: Self.install) == nil)
        #expect(gate.decide(now: 1, fingerprint: Self.install) == .backingOff(remaining: 1))
        #expect(gate.recordFailure(.droppedWithoutReply, now: 3, fingerprint: Self.install) == .droppedByHelper)
        // No time-based retry any more, however long we wait.
        #expect(gate.decide(now: 3 + 86_400, fingerprint: Self.install) == .rejected(.droppedByHelper))
    }

    @Test func testTransientFailureInterruptsDropStreak() {
        var gate = HelperConnectionGate()
        gate.recordFailure(.droppedWithoutReply, now: 0, fingerprint: Self.install)
        gate.recordFailure(.transient, now: 10, fingerprint: Self.install)
        #expect(gate.recordFailure(.droppedWithoutReply, now: 20, fingerprint: Self.install) == nil)
        #expect(gate.rejection == nil)
    }

    @Test func testCodeSigningFailureRejectsImmediately() {
        var gate = HelperConnectionGate()
        #expect(gate.recordFailure(.codeSigningRequirementFailed, now: 0, fingerprint: Self.install)
                == .helperSignatureMismatch)
        #expect(gate.decide(now: 1_000, fingerprint: Self.install) == .rejected(.helperSignatureMismatch))
    }

    @Test func testPinMismatchRejectionAndUserReset() {
        var gate = HelperConnectionGate()
        let reason = HelperRejectionReason.clientNotPinned(pinnedCDHash: String(repeating: "a", count: 40),
                                                           appCDHash: String(repeating: "b", count: 40))
        gate.recordRejection(reason, fingerprint: Self.install)
        #expect(gate.decide(now: 0, fingerprint: Self.install) == .rejected(reason))
        gate.reset()   // "Check Again"
        #expect(gate.decide(now: 0, fingerprint: Self.install) == .proceed)
    }

    /// Re-running install.sh rewrites the plist and the helper: the rejection is
    /// dropped without a user click.
    @Test func testReinstallClearsRejection() {
        var gate = HelperConnectionGate()
        gate.recordFailure(.codeSigningRequirementFailed, now: 0, fingerprint: Self.install)
        #expect(gate.decide(now: 1, fingerprint: Self.reinstalled) == .proceed)
        #expect(gate.rejection == nil)
        #expect(gate.consecutiveFailures == 0)
    }

    @Test func testCustomPolicyThreshold() {
        var gate = HelperConnectionGate(policy: .init(initialBackoff: 1, multiplier: 3, maxBackoff: 60,
                                                      dropsBeforeRejection: 1))
        #expect(gate.backoffDelay(afterFailures: 3) == 9)
        #expect(gate.backoffDelay(afterFailures: 5) == 60)
        #expect(gate.recordFailure(.droppedWithoutReply, now: 0, fingerprint: Self.install) == .droppedByHelper)
        #expect(HelperConnectionGate.Policy(dropsBeforeRejection: 0).dropsBeforeRejection == 1)
    }

    @Test func testClassification() {
        let cocoa = NSCocoaErrorDomain
        #expect(HelperConnectionGate.classify(errorDomain: cocoa, errorCode: 4102, hadReplyBeforeSend: false)
                == .codeSigningRequirementFailed)
        #expect(HelperConnectionGate.classify(errorDomain: cocoa, errorCode: 4102, hadReplyBeforeSend: true)
                == .codeSigningRequirementFailed)
        #expect(HelperConnectionGate.classify(errorDomain: cocoa, errorCode: 4097, hadReplyBeforeSend: false)
                == .droppedWithoutReply)
        // Interrupted after earlier replies: helper crashed / restarted.
        #expect(HelperConnectionGate.classify(errorDomain: cocoa, errorCode: 4097, hadReplyBeforeSend: true)
                == .transient)
        // Invalid: helper not running / not registered.
        #expect(HelperConnectionGate.classify(errorDomain: cocoa, errorCode: 4099, hadReplyBeforeSend: false)
                == .transient)
        #expect(HelperConnectionGate.classify(errorDomain: NSPOSIXErrorDomain, errorCode: 4097, hadReplyBeforeSend: false)
                == .transient)
    }

    /// End-to-end sequence as `HelperClient` drives it: decide → (connect) → record.
    @Test func testRejectedClientStopsConnecting() {
        var gate = HelperConnectionGate()
        var connections = 0
        // Ten user clicks, three seconds apart, against a helper that drops every peer.
        for click in 0..<10 {
            let now = TimeInterval(click) * 3
            guard gate.decide(now: now, fingerprint: Self.install) == .proceed else { continue }
            connections += 1
            gate.recordFailure(HelperConnectionGate.classify(errorDomain: NSCocoaErrorDomain, errorCode: 4097,
                                                             hadReplyBeforeSend: false),
                               now: now, fingerprint: Self.install)
        }
        #expect(connections == 2)
        #expect(gate.rejection == .droppedByHelper)
    }

    @Test func testRejectionDescriptionsNameTheRemedy() {
        let reasons: [HelperRejectionReason] = [
            .clientNotPinned(pinnedCDHash: "p", appCDHash: "a"), .droppedByHelper, .helperSignatureMismatch,
        ]
        for reason in reasons {
            #expect(reason.description.contains("sudo install.sh"))
        }
        #expect(HelperRejectionReason.clientNotPinned(pinnedCDHash: "p", appCDHash: "a").description
                    .contains("pinned to a different build of the app"))
    }
}
