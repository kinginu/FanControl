#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

/// Exported object for one client connection. All input is validated; nothing here traps.
final class HelperService: NSObject, FanControlHelperProtocol {
    private let owner: SessionOwner

    init(owner: SessionOwner) {
        self.owner = owner
        super.init()
    }

    func version(reply: @escaping (Int, String) -> Void) {
        reply(FanControlHelperConstants.protocolVersion, HelperConfiguration.buildString)
    }

    func openSession(reply: @escaping (Int, String) -> Void) {
        let result = SessionRegistry.shared.open(for: owner)
        reply(result.code.rawValue, result.message)
    }

    func writeKey(_ key: String, bytes: Data, reply: @escaping (Int, String) -> Void) {
        guard let smcKey = SMCKey(key) else {
            reply(FanControlHelperErrorCode.invalidKey.rawValue, "key must be exactly 4 ASCII characters")
            return
        }
        guard FanControlHelperConstants.isWriteAllowed(key: key) else {
            helperLog.warning("pid \(self.owner.pid, privacy: .public) tried to write disallowed key \(key, privacy: .public)")
            reply(FanControlHelperErrorCode.keyNotAllowed.rawValue, "key '\(key)' is not in the write allowlist")
            return
        }
        guard (1...32).contains(bytes.count) else {
            reply(FanControlHelperErrorCode.badRequest.rawValue, "payload must be 1...32 bytes, got \(bytes.count)")
            return
        }
        // Value validation (mode 0/1, RPM within hardware Mn...Mx, FS! bits < 1 << FNum)
        // happens in SessionRegistry.write, which holds the per-session hardware limits.
        let result = SessionRegistry.shared.write([UInt8](bytes), to: smcKey, from: owner)
        if result.code != .ok {
            helperLog.error("write \(key, privacy: .public) failed: \(result.message, privacy: .public)")
        }
        reply(result.code.rawValue, result.message)
    }

    func closeSession(reply: @escaping (Int, String) -> Void) {
        let result = SessionRegistry.shared.close(for: owner)
        reply(result.code.rawValue, result.message)
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
}
#endif
