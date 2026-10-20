import Foundation
import Testing
import FanControlCore
@testable import FanControlXPC

/// Mac14,9 / macOS 26 key types (`F<n>Md` ui8, `F<n>Tg` little-endian flt) plus an
/// Intel-style `FS! ` ui16 for the force-bit cases.
private enum Keys {
    static let md = SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd0)
    static let tg = SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0xd4)
    static let fs = SMCKeyInfo(dataSize: 2, dataType: .ui16, attributes: 0xd0)
    static func flt(_ v: Double) -> [UInt8] { SMCCodec.encode(v, as: .flt, size: 4)! }
    static func info(_ key: SMCKey) -> SMCKeyInfo? {
        if key == .forceBits { return fs }
        switch key.name.suffix(2) {
        case "Md": return md
        case "Tg": return tg
        default: return nil
        }
    }
}

private typealias P = PowerTransitionPolicy

private func remembered(_ lastWritten: [String: [UInt8]], touched: UInt64 = 0) -> [P.RememberedFan] {
    var map: [SMCKey: [UInt8]] = [:]
    for (name, bytes) in lastWritten { map[SMCKey(name)!] = bytes }
    return P.rememberedFans(lastWritten: map, touchedForceBits: touched, keyInfo: Keys.info)
}

private func names(_ writes: [P.Write]) -> [String] { writes.map { "\($0.key.name)=\($0.bytes)" } }

/// Mode-key fans, values as observed on wake in first-write test 4.
private func snapshot(_ fans: [(md: UInt8?, tg: Double?)], force: [UInt8]? = nil) -> P.Snapshot {
    P.Snapshot(fans: fans.enumerated().map { P.FanState(fan: $0.offset, modeBytes: $0.element.md.map { [$0] },
                                                        targetRPM: $0.element.tg) },
               forceBytes: force,
               forceMask: force.map { $0.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } })
}

struct PowerTransitionPolicyTests {

    // MARK: Remembered intent

    @Test func rememberedFansFromLastWrites() {
        let fans = remembered(["F0Md": [1], "F0Tg": Keys.flt(3000), "F1Md": [0], "F1Tg": Keys.flt(2500)])
        // F1's last mode write was 0: handed back by the client, not forced.
        #expect(fans == [P.RememberedFan(fan: 0, control: .modeKey(onBytes: [1]),
                                         targetBytes: Keys.flt(3000), targetRPM: 3000)])
    }

    @Test func rememberedModeWithoutTarget() {
        let fans = remembered(["F0Md": [1]])
        #expect(fans.count == 1)
        #expect(fans[0].targetBytes == nil)
        #expect(fans[0].hasTarget == false)
    }

    @Test func rememberedForceBitsOnlySessionBits() {
        // FS! last written 0b011, but this session only touched bit 0 (bit 1 belonged to someone else).
        let fans = remembered(["FS! ": [0x00, 0x03], "F0Tg": [0x00, 0x00, 0x00, 0x00]], touched: 0b01)
        #expect(fans.map(\.fan) == [0])
        #expect(fans[0].control == .forceBit)
    }

    @Test func targetOnlyFan() {
        let fans = remembered(["F0Tg": Keys.flt(3000)])
        #expect(fans.map(\.control) == [.targetOnly])
    }

    // MARK: Sleep

    @Test func sleepHandsBackForcedFansOnly() {
        let fans = remembered(["F0Md": [1], "F0Tg": Keys.flt(3000), "F1Md": [0]])
        let writes = P.sleepHandBack(remembered: fans, snapshot: snapshot([(1, 3000), (0, 2400)]))
        #expect(names(writes) == ["F0Md=[0]"])  // no F<n>Tg, F1 untouched
    }

    @Test func sleepHandBackClearsForceBits() {
        let fans = remembered(["FS! ": [0x00, 0x03], "F0Tg": Keys.flt(3000), "F1Tg": Keys.flt(3000)], touched: 0b11)
        let writes = P.sleepHandBack(remembered: fans, snapshot: snapshot([(nil, 3000), (nil, 3000)], force: [0x00, 0x07]))
        #expect(names(writes) == ["FS! =[0, 4]"])  // bit 2 (not ours) kept
    }

    @Test func sleepWithNothingForced() {
        #expect(P.sleepHandBack(remembered: [], snapshot: snapshot([(1, 0)])).isEmpty)
    }

    // MARK: Wake

    /// First-write test 4: both fans woke with Md=1 / Tg=0. Fan 1 was forced to 3000
    /// by the session, Fan 2 was automatic.
    @Test func wakeReappliesRememberedAndHandsBackTheRest() {
        let fans = remembered(["F0Md": [1], "F0Tg": Keys.flt(3000), "F1Md": [0]])
        let writes = P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 0), (1, 0)]))
        // Md=1 already: only the target for F0; F1 is manual without a remembered target -> Md=0.
        #expect(names(writes) == ["F1Md=[0]", "F0Tg=\(Keys.flt(3000))"])
    }

    @Test func wakeAfterHandBackWritesModeThenTarget() {
        let fans = remembered(["F0Md": [1], "F0Tg": Keys.flt(3000), "F1Md": [1], "F1Tg": Keys.flt(4000)])
        let writes = P.wakeRecovery(remembered: fans, snapshot: snapshot([(0, 2400), (0, 0)]))
        #expect(names(writes) == ["F0Md=[1]", "F1Md=[1]", "F0Tg=\(Keys.flt(3000))", "F1Tg=\(Keys.flt(4000))"])
    }

    @Test func wakeIsIdempotentWhenSettled() {
        let fans = remembered(["F0Md": [1], "F0Tg": Keys.flt(3000)])
        #expect(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 3002), (0, 0)])).isEmpty)
        // Outside the tolerance -> target only.
        #expect(names(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 2900), (0, 0)])))
                == ["F0Tg=\(Keys.flt(3000))"])
    }

    @Test func wakeManualWithoutRememberedTargetGoesAutomatic() {
        // Md=1 written but the target never succeeded: nothing valid to run at.
        let fans = remembered(["F0Md": [1]])
        #expect(names(P.wakeRecovery(remembered: fans, snapshot: snapshot([(1, 0)]))) == ["F0Md=[0]"])
        // No session intent at all (e.g. after the client switched everything to automatic).
        #expect(names(P.wakeRecovery(remembered: [], snapshot: snapshot([(1, 0), (0, 0)]))) == ["F0Md=[0]"])
    }

    @Test func wakeForceBits() {
        let fans = remembered(["FS! ": [0x00, 0x01], "F0Tg": Keys.flt(3000)], touched: 0b01)
        // Bit 0 lost, bit 1 set without intent -> set 0, clear 1, then the target.
        let writes = P.wakeRecovery(remembered: fans, snapshot: snapshot([(nil, 0), (nil, 0)], force: [0x00, 0x02]))
        #expect(names(writes) == ["FS! =[0, 1]", "F0Tg=\(Keys.flt(3000))"])
    }

    @Test func wakeRetriesAreBounded() {
        #expect(P.wakeRetryDelays == [0, 1, 3])
        #expect(P.wakeRetryDelays.count <= 3)
        #expect(P.wakeRetryDelays.max()! <= 5)
    }

    @Test func manualFansForWakeWithoutSession() {
        #expect(P.manualFans(snapshot([(1, 0), (0, 0)])) == [0])
        #expect(P.manualFans(snapshot([(nil, 0), (nil, 0)], force: [0x00, 0x02])) == [1])
        #expect(P.manualFans(snapshot([(0, 0)])).isEmpty)
    }

    // MARK: Snapshot

    @Test func snapshotReadsModeAndTarget() {
        let reader = TinyReader([
            ("F0Md", .ui8, [1]), ("F0Tg", .flt, Keys.flt(0)),
            ("F1Md", .ui8, [0]), ("F1Tg", .flt, Keys.flt(2468)),
        ])
        let snap = P.snapshot(using: reader, fanCount: 2)
        #expect(snap.fans == [P.FanState(fan: 0, modeBytes: [1], targetRPM: 0),
                              P.FanState(fan: 1, modeBytes: [0], targetRPM: 2468)])
        #expect(snap.forceBytes == nil)
    }

    @Test func settingBits() {
        #expect(P.settingBits(0b101, in: [0x00, 0x02]) == [0x00, 0x07])
    }
}

/// Minimal in-memory `SMCReader`.
private final class TinyReader: SMCReader {
    private var entries: [SMCKey: (SMCDataType, [UInt8])] = [:]
    init(_ list: [(String, SMCDataType, [UInt8])]) {
        for (name, type, bytes) in list { entries[SMCKey(name)!] = (type, bytes) }
    }
    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        guard let e = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return SMCKeyInfo(dataSize: e.1.count, dataType: e.0)
    }
    func readBytes(_ key: SMCKey) throws -> [UInt8] {
        guard let e = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return e.1
    }
    func keyCount() throws -> Int { entries.count }
    func key(at index: Int) throws -> SMCKey { throw FanControlError.invalidKey("#\(index)") }
}
