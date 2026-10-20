import Foundation
import Testing
import FanControlCore
@testable import FanControlXPC

private typealias P = PowerTransitionPolicy

private func remembered(_ lastWritten: [String: [UInt8]]) -> [P.RememberedFan] {
    var map: [SMCKey: [UInt8]] = [:]
    for (name, bytes) in lastWritten { map[SMCKey(name)!] = bytes }
    return P.rememberedFans(lastWritten: map, keyInfo: Mac14_9.info)
}

private func names(_ writes: [P.Write]) -> [String] { writes.map { "\($0.key.name)=\($0.bytes)" } }

/// Mode-key fans, values as observed on wake in first-write test 4.
private func snapshot(_ fans: [(md: UInt8?, tg: Double?)]) -> P.Snapshot {
    P.Snapshot(fans: fans.enumerated().map { P.FanState(fan: $0.offset, modeBytes: $0.element.md.map { [$0] },
                                                        targetRPM: $0.element.tg) })
}

@Suite("Power transition policy", .tags(.helper, .power))
struct PowerTransitionPolicyTests {

    // MARK: Remembered intent

    @Test func rememberedFansFromLastWrites() {
        let fans = remembered(["F0Md": [1], "F0Tg": Mac14_9.flt(3000), "F1Md": [0], "F1Tg": Mac14_9.flt(2500)])
        // F1's last mode write was 0: handed back by the client, not forced.
        #expect(fans == [P.RememberedFan(fan: 0, control: .modeKey(onBytes: [1]),
                                         targetBytes: Mac14_9.flt(3000), targetRPM: 3000)])
    }

    @Test func rememberedModeWithoutTarget() {
        let fans = remembered(["F0Md": [1]])
        #expect(fans.count == 1)
        #expect(fans[0].targetBytes == nil)
        #expect(fans[0].hasTarget == false)
    }

    /// Intel dropped 2026-10-20: an `FS! ` entry (never accepted by the helper)
    /// does not mark any fan as forced.
    @Test func forceBitsKeyIsIgnored() {
        let fans = remembered(["FS! ": [0x00, 0x03], "F0Md": [1], "F0Tg": Mac14_9.flt(3000)])
        #expect(fans.map(\.fan) == [0])
        #expect(fans[0].control == .modeKey(onBytes: [1]))
    }

    @Test func targetOnlyFan() {
        let fans = remembered(["F0Tg": Mac14_9.flt(3000)])
        #expect(fans.map(\.control) == [.targetOnly])
    }

    // MARK: Sleep

    @Test func sleepHandsBackForcedFansOnly() {
        let fans = remembered(["F0Md": [1], "F0Tg": Mac14_9.flt(3000), "F1Md": [0]])
        let writes = P.sleepHandBack(remembered: fans, snapshot: snapshot([(1, 3000), (0, 2400)]))
        #expect(names(writes) == ["F0Md=[0]"])  // no F<n>Tg, F1 untouched
    }

    @Test func sleepWithNothingForced() {
        #expect(P.sleepHandBack(remembered: [], snapshot: snapshot([(1, 0)])).isEmpty)
    }

    // MARK: Wake

    /// First-write test 4: both fans woke with Md=1 / Tg=0. Fan 1 was forced to 3000
    /// by the session, Fan 2 was automatic.
    @Test func wakeReappliesRememberedAndHandsBackTheRest() {
        let fans = remembered(["F0Md": [1], "F0Tg": Mac14_9.flt(3000), "F1Md": [0]])
        let writes = P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 0), (1, 0)]))
        // Md=1 already: only the target for F0; F1 is manual without a remembered target -> Md=0.
        #expect(names(writes) == ["F1Md=[0]", "F0Tg=\(Mac14_9.flt(3000))"])
    }

    @Test func wakeAfterHandBackWritesModeThenTarget() {
        let fans = remembered(["F0Md": [1], "F0Tg": Mac14_9.flt(3000), "F1Md": [1], "F1Tg": Mac14_9.flt(4000)])
        let writes = P.wakeRecovery(remembered: fans, snapshot: snapshot([(0, 2400), (0, 0)]))
        #expect(names(writes) == ["F0Md=[1]", "F1Md=[1]", "F0Tg=\(Mac14_9.flt(3000))", "F1Tg=\(Mac14_9.flt(4000))"])
    }

    @Test func wakeIsIdempotentWhenSettled() {
        let fans = remembered(["F0Md": [1], "F0Tg": Mac14_9.flt(3000)])
        #expect(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 3002), (0, 0)])).isEmpty)
        // Outside the tolerance -> target only.
        #expect(names(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 2900), (0, 0)])))
                == ["F0Tg=\(Mac14_9.flt(3000))"])
    }

    @Test func wakeManualWithoutRememberedTargetGoesAutomatic() {
        // Md=1 written but the target never succeeded: nothing valid to run at.
        let fans = remembered(["F0Md": [1]])
        #expect(names(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 0)]))) == ["F0Md=[0]"])
        // No session intent at all (e.g. after the client switched everything to automatic).
        #expect(names(P.wakeRecovery(remembered: [], snapshot: snapshot([(1, 0), (0, 0)]))) == ["F0Md=[0]"])
    }

    @Test func wakeRetriesAreBounded() {
        #expect(P.wakeRetryDelays == [0, 1, 3])
        #expect(P.wakeRetryDelays.count <= 3)
        #expect(P.wakeRetryDelays.max()! <= 5)
    }

    @Test func manualFansForWakeWithoutSession() {
        #expect(P.manualFans(snapshot([(1, 0), (0, 0)])) == [0])
        #expect(P.manualFans(snapshot([(nil, 0), (nil, 0)])).isEmpty)
        #expect(P.manualFans(snapshot([(0, 0)])).isEmpty)
    }

    // MARK: Snapshot

    @Test func snapshotReadsModeAndTarget() {
        let reader = InMemorySMCReader([
            ("F0Md", .ui8, [1]), ("F0Tg", .flt, Mac14_9.flt(0)),
            ("F1Md", .ui8, [0]), ("F1Tg", .flt, Mac14_9.flt(2468)),
        ])
        let snap = P.snapshot(using: reader, fanCount: 2)
        #expect(snap.fans == [P.FanState(fan: 0, modeBytes: [1], targetRPM: 0),
                              P.FanState(fan: 1, modeBytes: [0], targetRPM: 2468)])
    }
}
