#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

/// Exported object for one client connection: decodes and checks the request shape
/// (key syntax, allowlist, payload size), then hands it to `SessionRegistry`, which does
/// the value validation and the SMC I/O. All input is validated; nothing here traps.
///
/// `Sendable` (immutable): XPC may deliver one connection's messages on any of its queues.
final class HelperService: NSObject, FanControlHelperProtocol, Sendable {
    let owner: SessionOwner  // F1: internal (read by the charge-limit extension, ChargeLimitService.swift)

    /// Payload sizes accepted by `writeKey` (the SMC's own limit; the exact size is
    /// checked against the key's `dataSize` by `HelperWritePolicy.validate`).
    static let payloadSizeRange = 1...32

    init(owner: SessionOwner) {
        self.owner = owner
        super.init()
    }

    func version(reply: @escaping (Int, String) -> Void) {
        reply(FanControlHelperConstants.protocolVersion, HelperConfiguration.buildString)
    }

    func openSession(reply: @escaping (Int, String) -> Void) {
        send(SessionRegistry.shared.open(for: owner), operation: "openSession", reply: reply)
    }

    func writeKey(_ key: String, bytes: Data, reply: @escaping (Int, String) -> Void) {
        let result: HelperResult
        if let smcKey = SMCKey(key) {
            if !FanControlHelperConstants.isWriteAllowed(key: key) {
                result = .failure(.keyNotAllowed, "key '\(key)' is not in the write allowlist")
            } else if !Self.payloadSizeRange.contains(bytes.count) {
                result = .failure(.badRequest, "payload must be \(Self.payloadSizeRange.lowerBound)...\(Self.payloadSizeRange.upperBound) bytes, got \(bytes.count)")
            } else {
                // Value validation (mode 0/1, RPM within hardware Mn...Mx) happens in
                // SessionRegistry.write, which holds the per-session hardware limits.
                result = SessionRegistry.shared.write([UInt8](bytes), to: smcKey, from: owner)
            }
        } else {
            result = .failure(.invalidKey, "key must be exactly 4 ASCII characters")
        }
        send(result, operation: "writeKey(\(key))", reply: reply)
    }

    func closeSession(reply: @escaping (Int, String) -> Void) {
        send(SessionRegistry.shared.close(for: owner), operation: "closeSession", reply: reply)
    }

    func readKeyInfo(_ key: String, reply: @escaping (Int, Int, UInt32, UInt8, String) -> Void) {
        guard let smcKey = SMCKey(key) else {
            reply(FanControlHelperErrorCode.invalidKey.rawValue, 0, 0, 0, "key must be exactly 4 ASCII characters")
            return
        }
        switch SessionRegistry.shared.keyInfo(smcKey) {
        case .success(let info):
            // Raw FourCC as reported by the SMC (not re-derived from the parsed type).
            reply(FanControlHelperErrorCode.ok.rawValue, info.dataSize, info.rawType, info.attributes, "ok")
        case .failure(let error):
            let code: FanControlHelperErrorCode
            switch error {
            case .keyNotFound, .invalidKey: code = .invalidKey
            case .smcUnavailable: code = .smcUnavailable
            default: code = .smcError
            }
            reply(code.rawValue, 0, 0, 0, "\(error)")
        }
    }

    /// Logs a failed request (SMC failures as errors, refused requests as warnings) and replies.
    private func send(_ result: HelperResult, operation: String, reply: (Int, String) -> Void) {
        switch result.code {
        case .ok:
            break
        case .smcUnavailable, .smcError:
            helperLog.error("XPC: \(operation, privacy: .public) from pid \(self.owner.pid, privacy: .public) failed (\(result.code.rawValue, privacy: .public)): \(result.message, privacy: .public)")
        default:  // notSessionOwner, sessionNotOpen, invalidKey, keyNotAllowed, badRequest
            helperLog.warning("XPC: \(operation, privacy: .public) from pid \(self.owner.pid, privacy: .public) refused (\(result.code.rawValue, privacy: .public)): \(result.message, privacy: .public)")
        }
        reply(result.code.rawValue, result.message)
    }
}
#endif
