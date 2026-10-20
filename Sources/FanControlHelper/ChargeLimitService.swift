#if os(macOS)
import Foundation
import Synchronization
import FanControlCore
import FanControlSMC
import FanControlXPC

/// Serves `setChargeLimitEnabled(_:reply:)` (docs/helper.md "Charge limit (CHWA)").
///
/// Deliberately independent of `SessionRegistry`: the charge limit is not part of
/// the fan write session, so no session is required, nothing is snapshotted, and
/// nothing is restored when a session ends, the client goes away, the system sleeps
/// or the helper exits (SIGTERM). Every request opens its own short-lived AppleSMC
/// connection; requests are serialized by `lock`. All decisions (key, value,
/// metadata, read-before-write, read-back) are made by `ChargeLimitPolicy.apply`.
///
/// Client admission is unchanged: only a connection that passed the listener's
/// code-signing requirement reaches `HelperService`.
enum ChargeLimitService {
    private static let lock = Mutex(())

    static func setEnabled(_ enabled: Bool, requestedBy owner: SessionOwner) -> ChargeLimitPolicy.Outcome {
        lock.withLock { _ in
            let client: SMCClient
            do {
                client = try SMCClient()
            } catch {
                return ChargeLimitPolicy.Outcome(code: .smcUnavailable, value: ChargeLimitPolicy.unknownValue,
                                                 message: "cannot open AppleSMC: \(error)", wrote: false)
            }
            defer { client.close() }
            let outcome = ChargeLimitPolicy.apply(
                enabled: enabled,
                keyInfo: { try client.keyInfo($0) },
                read: { try client.readBytes($0) },
                write: { try client.writeBytes($1, to: $0) })
            if outcome.code == .ok {
                helperLog.notice("Charge limit: pid \(owner.pid, privacy: .public) requested \(enabled ? "on" : "off", privacy: .public); \(outcome.message, privacy: .public) (CHWA=\(outcome.value, privacy: .public), wrote: \(outcome.wrote, privacy: .public))")
            } else {
                helperLog.error("Charge limit: pid \(owner.pid, privacy: .public) requested \(enabled ? "on" : "off", privacy: .public); refused/failed (rc \(outcome.code.rawValue, privacy: .public)): \(outcome.message, privacy: .public)")
            }
            return outcome
        }
    }
}

// F1: the protocol method lives here so HelperService.swift only changes `owner`'s access level.
extension HelperService {
    func setChargeLimitEnabled(_ enabled: Bool, reply: @escaping (Int, Int, String) -> Void) {
        let outcome = ChargeLimitService.setEnabled(enabled, requestedBy: owner)
        reply(outcome.code.rawValue, outcome.value, outcome.message)
    }
}
#endif
