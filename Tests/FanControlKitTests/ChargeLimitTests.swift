#if os(macOS)
import Foundation
import Synchronization
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

// MARK: - Fakes

extension FakeHelper {
    /// `ChargeLimitService.setEnabled` against the fake SMC (no session involved).
    func setChargeLimit(_ enabled: Bool) -> ChargeLimitPolicy.Outcome {
        let smc = self.smc
        return ChargeLimitPolicy.apply(enabled: enabled,
                                       keyInfo: { try smc.keyInfo($0) },
                                       read: { try smc.readBytes($0) },
                                       write: { try smc.writeBytes($1, to: $0) })
    }
}

extension FakeSMC {
    /// `mac14_9()` plus a `CHWA` key (ui8, 0xd4 like the other writable charging keys).
    /// The real Mac14,9 / macOS 26.5.2 has no `CHWA` (dump of 2026-10-20).
    static func withChargeLimit(_ value: UInt8 = 0, type: SMCDataType = .ui8, attributes: UInt8 = 0xd4) -> FakeSMC {
        let bytes: [UInt8] = type == .ui32 ? [value, 0, 0, 0] : [value]
        return FakeSMC([
            ("FNum", .ui8, [2], 0x80),
            ("F0Md", .ui8, [0], 0xd0),
            ("F0Mn", .flt, flt(2317), 0x84),
            ("F0Mx", .flt, flt(6800), 0x84),
            ("F0Ac", .flt, flt(0), 0x80),
            ("F0Tg", .flt, flt(0), 0xd4),
            ("F1Md", .ui8, [0], 0xd0),
            ("F1Mn", .flt, flt(2317), 0x84),
            ("F1Mx", .flt, flt(6800), 0x84),
            ("F1Ac", .flt, flt(0), 0x80),
            ("F1Tg", .flt, flt(0), 0xd4),
            ("CHWA", type, bytes, attributes),
        ])
    }

    var chargeLimitByte: UInt8? { try? readBytes("CHWA").first }
}

@MainActor
private final class FakeChargeLimitHelper: ChargeLimitHelperAccess {
    var isHelperUsable = true
    var prepareError: (any Error)?
    var setError: (any Error)?
    var readBack = 1
    var calls: [String] = []

    func refreshHelperStatus() {}

    func prepareHelper() async throws {
        calls.append("prepare")
        if let prepareError { throw prepareError }
    }

    func setChargeLimitEnabled(_ enabled: Bool) async throws -> Int {
        calls.append("set(\(enabled))")
        if let setError { throw setError }
        return readBack
    }
}

/// Holds a fake CHWA read until `release()` (one waiter).
private final class StaleReadGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    var isWaiting: Bool { continuation.withLock { $0 != nil } }

    func waitForRelease() async {
        await withCheckedContinuation { cont in continuation.withLock { $0 = cont } }
    }

    func release() {
        continuation.withLock { cont in
            cont?.resume()
            cont = nil
        }
    }
}

// MARK: - Helper contract over XPC

@Suite("Charge limit over XPC (FakeHelper)", .serialized)
struct ChargeLimitEndToEndTests {

    @Test func needsNoSession() async throws {
        let helper = FakeHelper(smc: .withChargeLimit(0))
        let client = helper.makeClient()
        let value = try await client.setChargeLimitEnabled(true)
        #expect(value == 1)
        #expect(helper.smc.chargeLimitByte == 1)
        #expect(!client.isSessionOpen)
        #expect(helper.owner == nil)

        #expect(try await client.setChargeLimitEnabled(false) == 0)
        #expect(helper.smc.chargeLimitByte == 0)
    }

    @Test func notRevertedBySessionCloseConnectionLossOrShutdown() async throws {
        let helper = FakeHelper(smc: .withChargeLimit(0))
        let client = helper.makeClient()
        try await client.openSession()
        try await client.write(key: "F0Md", bytes: [1])
        #expect(try await client.setChargeLimitEnabled(true) == 1)

        await client.closeSession()
        #expect(helper.smc.number("F0Md") == 0)  // the fan is handed back …
        #expect(helper.smc.chargeLimitByte == 1)  // … the charge limit is not
        #expect(helper.restores.allSatisfy { $0.allSatisfy { $0.key.name != "CHWA" } })

        try await client.openSession()
        client.invalidate()
        #expect(await eventually { helper.owner == nil })
        helper.shutdown()
        #expect(helper.smc.chargeLimitByte == 1)
    }

    @Test func missingKeyIsReportedAsInvalidKey() async throws {
        let helper = FakeHelper(smc: .mac14_9())  // no CHWA, like the real Mac14,9
        let client = helper.makeClient()
        do {
            _ = try await client.setChargeLimitEnabled(true)
            Issue.record("expected a rejection")
        } catch FanControlError.helperRejected(let code, _) {
            #expect(code == FanControlHelperErrorCode.invalidKey.rawValue)
        }
        #expect(helper.smc.writeLog.isEmpty)
    }

    @Test func unexpectedLayoutIsRefused() async throws {
        let helper = FakeHelper(smc: .withChargeLimit(0, type: .ui32))
        let client = helper.makeClient()
        do {
            _ = try await client.setChargeLimitEnabled(true)
            Issue.record("expected a rejection")
        } catch FanControlError.helperRejected(let code, _) {
            #expect(code == FanControlHelperErrorCode.badRequest.rawValue)
        }
        #expect(helper.smc.writeLog.isEmpty)
    }

    @Test func genericWritePathRefusesCHWA() async throws {
        let helper = FakeHelper(smc: .withChargeLimit(0))
        let client = helper.makeClient()
        try await client.openSession()
        do {
            try await client.write(key: "CHWA", bytes: [1])
            Issue.record("expected a rejection")
        } catch FanControlError.helperRejected(let code, _) {
            #expect(code == FanControlHelperErrorCode.keyNotAllowed.rawValue)
        }
        #expect(helper.smc.chargeLimitByte == 0)
        await client.closeSession()
    }
}

// MARK: - ChargeLimitController

@MainActor
struct ChargeLimitControllerTests {

    private func makeController(_ helper: FakeChargeLimitHelper,
                                reading: ChargeLimitReading = .off) -> ChargeLimitController {
        ChargeLimitController(helper: helper, read: { reading })
    }

    @Test func refreshReadsAndCombinesHelperState() async {
        let helper = FakeChargeLimitHelper()
        let controller = makeController(helper, reading: .on)
        #expect(controller.status == .unknown)
        await controller.refresh()
        #expect(controller.reading == .on)
        #expect(controller.status == .on)
        #expect(controller.status.isOn)

        helper.isHelperUsable = false
        await controller.refresh()
        #expect(controller.status == .needsHelper(isOn: true))
        #expect(controller.status.isOn)
        #expect(controller.status.isAvailable)
    }

    @Test func unsupportedReadingIsUnavailable() async throws {
        let helper = FakeChargeLimitHelper()
        let controller = makeController(helper, reading: .unsupported("no CHWA"))
        await controller.refresh()
        #expect(controller.status == .unsupported("no CHWA"))
        #expect(!controller.status.isAvailable)
        await #expect(throws: FanControlError.keyNotFound("CHWA")) { try await controller.setEnabled(true) }
        #expect(helper.calls.isEmpty)  // never asks the helper
    }

    @Test func setEnabledPreparesHelperThenWrites() async throws {
        let helper = FakeChargeLimitHelper()
        let controller = makeController(helper)
        await controller.refresh()
        try await controller.setEnabled(true)
        #expect(helper.calls == ["prepare", "set(true)"])
        #expect(controller.reading == .on)
        #expect(controller.lastError == nil)
        #expect(!controller.isBusy)

        helper.readBack = 0
        try await controller.setEnabled(false)
        #expect(controller.reading == .off)
    }

    @Test func staleRefreshDoesNotOverwriteAFinishedChange() async throws {
        let helper = FakeChargeLimitHelper()
        helper.readBack = 1
        let gate = StaleReadGate()
        let controller = ChargeLimitController(helper: helper, read: {
            await gate.waitForRelease()
            return .off   // read before the change landed
        })
        let refresh = Task { @MainActor in await controller.refresh() }
        #expect(await eventually { gate.isWaiting })
        // The change runs from start to finish while the read is in flight.
        try await controller.setEnabled(true)
        #expect(controller.reading == .on)
        #expect(!controller.isBusy)
        gate.release()
        await refresh.value
        #expect(controller.reading == .on)   // not the older .off
    }

    @Test func missingKeyFromHelperMarksUnsupported() async {
        let helper = FakeChargeLimitHelper()
        helper.setError = FanControlError.helperRejected(code: FanControlHelperErrorCode.invalidKey.rawValue,
                                                         message: "'CHWA' does not exist on this SMC")
        let controller = makeController(helper)
        await controller.refresh()
        await #expect(throws: FanControlError.self) { try await controller.setEnabled(true) }
        #expect(controller.reading == .unsupported("'CHWA' does not exist on this SMC"))
        #expect(controller.errorMessage == "This Mac does not support limiting charging to 80 %.")
    }

    @Test func helperNotInstalledStopsBeforeWriting() async {
        let helper = FakeChargeLimitHelper()
        helper.isHelperUsable = false
        helper.prepareError = FanControlError.helperNotInstalled
        let controller = makeController(helper)
        await controller.refresh()
        #expect(controller.status == .needsHelper(isOn: false))
        await #expect(throws: FanControlError.helperNotInstalled) { try await controller.setEnabled(true) }
        #expect(helper.calls == ["prepare"])
        #expect(controller.reading == .off)
        #expect(controller.errorMessage?.hasPrefix("The fan control helper is needed") == true)
    }

    @Test func readBackMapping() {
        #expect(ChargeLimitController.reading(fromReadBack: 1) == .on)
        #expect(ChargeLimitController.reading(fromReadBack: 0) == .off)
        if case .unreadable = ChargeLimitController.reading(fromReadBack: -1) {} else {
            Issue.record("-1 must be unreadable")
        }
    }

    @Test func classifyReadsCHWAOnly() {
        #expect(ChargeLimitController.classify(FakeSMC.withChargeLimit(1)) == .on)
        #expect(ChargeLimitController.classify(FakeSMC.withChargeLimit(0)) == .off)
        if case .unsupported = ChargeLimitController.classify(FakeSMC.mac14_9()) {} else {
            Issue.record("absent CHWA must be unsupported")
        }
        if case .unsupported = ChargeLimitController.classify(FakeSMC.withChargeLimit(0, type: .ui32)) {} else {
            Issue.record("unexpected layout must be unsupported")
        }
        if case .unsupported = ChargeLimitController.classify(FakeSMC.withChargeLimit(0, attributes: 0x84)) {} else {
            Issue.record("read-only CHWA must be unsupported")
        }
        if case .unreadable = ChargeLimitController.classify(FakeSMC.withChargeLimit(5)) {} else {
            Issue.record("value 5 must be unreadable")
        }
    }

    @Test func messages() {
        #expect(ChargeLimitController.message(for: .keyNotFound("CHWA"))
                == "This Mac does not support limiting charging to 80 %.")
        let smc = ChargeLimitController.message(
            for: .helperRejected(code: FanControlHelperErrorCode.smcError.rawValue, message: "boom"))
        #expect(smc == "The SMC did not accept the change: boom")
    }
}
#endif
