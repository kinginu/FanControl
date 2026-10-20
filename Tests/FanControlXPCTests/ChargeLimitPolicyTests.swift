import Foundation
import Testing
import FanControlCore
@testable import FanControlXPC

/// In-memory SMC for `ChargeLimitPolicy.apply` (records writes; can fail or lie on read-back).
private final class FakeChargeSMC {
    struct Failure: Error {}
    var info: SMCKeyInfo? = SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd4)
    var value: [UInt8] = [0]
    var writes: [(String, [UInt8])] = []
    var reads = 0
    var failWrite = false
    var failRead = false
    /// When set, the value the SMC reports after a write (instead of the written one).
    var valueAfterWrite: [UInt8]?

    func apply(_ enabled: Bool) -> ChargeLimitPolicy.Outcome {
        ChargeLimitPolicy.apply(
            enabled: enabled,
            keyInfo: { key in
                guard let info = self.info else { throw FanControlError.keyNotFound(key.name) }
                return info
            },
            read: { _ in
                self.reads += 1
                if self.failRead { throw Failure() }
                return self.value
            },
            write: { key, bytes in
                if self.failWrite { throw Failure() }
                self.writes.append((key.name, bytes))
                self.value = self.valueAfterWrite ?? bytes
            })
    }
}

struct ChargeLimitPolicyTests {

    // MARK: Allow-list

    @Test func allowListIsExactlyCHWA() {
        #expect(ChargeLimitPolicy.allowedKeys == ["CHWA"])
        #expect(ChargeLimitPolicy.allowedValues == [0, 1])
        #expect(ChargeLimitPolicy.isKeyAllowed("CHWA"))
        for other in ["CHWB", "chwa", "CHW", "CHWAA", "CHTE", "CHIE", "BCLM", "CH0B", "CH0C", "F0Md", "F0Tg", "FS! "] {
            #expect(!ChargeLimitPolicy.isKeyAllowed(other), Comment(rawValue: other))
        }
    }

    @Test func genericWritePathCannotWriteCHWA() {
        // The charge limit has its own request; the fan allow-list is unchanged.
        #expect(!FanControlHelperConstants.isWriteAllowed(key: "CHWA"))
        #expect(FanControlHelperConstants.allowedWriteKeyPatterns == ["^F[0-9]Tg$", "^F[0-9]Md$"])
    }

    @Test func protocolVersionAnnouncesChargeLimit() {
        #expect(FanControlHelperConstants.protocolVersion == 2)
    }

    @Test func payloadAndDecode() {
        #expect(ChargeLimitPolicy.bytes(enabled: true) == [1])
        #expect(ChargeLimitPolicy.bytes(enabled: false) == [0])
        #expect(ChargeLimitPolicy.decode([1]) == true)
        #expect(ChargeLimitPolicy.decode([0]) == false)
        #expect(ChargeLimitPolicy.decode([2]) == nil)
        #expect(ChargeLimitPolicy.decode([0, 0]) == nil)
        #expect(ChargeLimitPolicy.decode([]) == nil)
    }

    // MARK: Validation

    private let goodInfo = SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd4)

    @Test func validateAcceptsOnlyZeroAndOne() {
        #expect(ChargeLimitPolicy.validate([0], for: "CHWA", info: goodInfo) == nil)
        #expect(ChargeLimitPolicy.validate([1], for: "CHWA", info: goodInfo) == nil)
        for bad: [UInt8] in [[2], [0x50], [0xff], [], [0, 1], [1, 0]] {
            #expect(ChargeLimitPolicy.validate(bad, for: "CHWA", info: goodInfo)?.code == .badRequest,
                    Comment(rawValue: "\(bad)"))
        }
    }

    @Test func validateRejectsOtherKeys() {
        #expect(ChargeLimitPolicy.validate([1], for: "CHTE", info: goodInfo)?.code == .keyNotAllowed)
        #expect(ChargeLimitPolicy.validate([1], for: "F0Md", info: goodInfo)?.code == .keyNotAllowed)
    }

    @Test func validateRejectsUnexpectedLayout() {
        let cases: [SMCKeyInfo] = [
            SMCKeyInfo(dataSize: 4, dataType: .ui32, attributes: 0xd4),  // CHTE-like
            SMCKeyInfo(dataSize: 1, dataType: .hex, attributes: 0xd4),   // CHIE-like
            SMCKeyInfo(dataSize: 1, dataType: .flag, attributes: 0xd4),
            SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0x84),   // read-only
            SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0x40),   // not readable
        ]
        for info in cases {
            #expect(ChargeLimitPolicy.validate([1], for: "CHWA", info: info)?.code == .badRequest,
                    Comment(rawValue: "\(info)"))
        }
    }

    // MARK: Apply

    @Test func enableWritesOneAndReadsBack() {
        let smc = FakeChargeSMC()
        let outcome = smc.apply(true)
        #expect(outcome.code == .ok)
        #expect(outcome.value == 1)
        #expect(outcome.wrote)
        #expect(smc.writes.map(\.0) == ["CHWA"])
        #expect(smc.writes.map(\.1) == [[1]])
        #expect(smc.reads == 2)  // before and after the write
    }

    @Test func disableWritesZero() {
        let smc = FakeChargeSMC()
        smc.value = [1]
        let outcome = smc.apply(false)
        #expect(outcome.code == .ok)
        #expect(outcome.value == 0)
        #expect(smc.writes.map(\.1) == [[0]])
    }

    @Test func alreadyInStateDoesNotWrite() {
        let smc = FakeChargeSMC()
        smc.value = [1]
        let outcome = smc.apply(true)
        #expect(outcome.code == .ok)
        #expect(outcome.value == 1)
        #expect(!outcome.wrote)
        #expect(smc.writes.isEmpty)
    }

    @Test func missingKeyIsInvalidKeyWithoutWrite() {
        // Mac14,9 / macOS 26.5.2: CHWA does not exist (2026-10-20 dump).
        let smc = FakeChargeSMC()
        smc.info = nil
        let outcome = smc.apply(true)
        #expect(outcome.code == .invalidKey)
        #expect(outcome.value == ChargeLimitPolicy.unknownValue)
        #expect(smc.writes.isEmpty)
        #expect(smc.reads == 0)
    }

    @Test func unexpectedLayoutIsRefusedWithoutWrite() {
        let smc = FakeChargeSMC()
        smc.info = SMCKeyInfo(dataSize: 4, dataType: .ui32, attributes: 0xd4)
        smc.value = [0, 0, 0, 0]
        #expect(smc.apply(true).code == .badRequest)
        #expect(smc.apply(false).code == .badRequest)
        #expect(smc.writes.isEmpty)
    }

    @Test func unexpectedCurrentValueRefusesEnableButAllowsDisable() {
        let smc = FakeChargeSMC()
        smc.value = [7]
        let enable = smc.apply(true)
        #expect(enable.code == .badRequest)
        #expect(smc.writes.isEmpty)
        let disable = smc.apply(false)
        #expect(disable.code == .ok)
        #expect(smc.writes.map(\.1) == [[0]])
        #expect(smc.value == [0])
    }

    @Test func unreadableBeforeWriteRefuses() {
        let smc = FakeChargeSMC()
        smc.failRead = true
        let outcome = smc.apply(true)
        #expect(outcome.code == .smcError)
        #expect(smc.writes.isEmpty)
    }

    @Test func writeFailureIsSMCError() {
        let smc = FakeChargeSMC()
        smc.failWrite = true
        let outcome = smc.apply(true)
        #expect(outcome.code == .smcError)
        #expect(!outcome.wrote)
        #expect(smc.value == [0])
    }

    @Test func readBackMismatchIsReported() {
        let smc = FakeChargeSMC()
        smc.valueAfterWrite = [0]  // the firmware ignored the write
        let outcome = smc.apply(true)
        #expect(outcome.code == .smcError)
        #expect(outcome.value == 0)
        #expect(outcome.wrote)
    }

    // MARK: Not part of the fan session

    @Test func sessionRestoreNeverTouchesCHWA() {
        // Even if CHWA ever ended up in a session's originals, the fan restore
        // sequence ignores every non-fan key: the charge limit is never reverted.
        var writes: [String] = []
        let performed = HelperWritePolicy.restore(
            originals: [(key: "CHWA", bytes: [0])],
            fanLimits: [:],
            keyInfo: { _ in SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xd4) },
            write: { key, _ in writes.append(key.name) })
        #expect(performed.isEmpty)
        #expect(writes.isEmpty)
    }
}
