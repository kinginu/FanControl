#if os(macOS)
import Foundation
import FanControlXPC

// F2: Low Power Mode request (docs/helper.md "Low Power Mode request"). The validation,
// allowlist, rate limit and read-back live in `LowPowerModeRequestHandler` (FanControlXPC,
// unit-tested with a fake runner, with the real `ProcessCommandRunner`); this file only
// provides the helper's handler instance and the XPC entry point.

/// The helper's single Low Power Mode handler (rate limit shared by all connections).
let lowPowerModeHandler = LowPowerModeRequestHandler(runner: ProcessCommandRunner(), log: { level, message in
    switch level {
    case .info: helperLog.info("\(message, privacy: .public)")
    case .notice: helperLog.notice("\(message, privacy: .public)")
    case .error: helperLog.error("\(message, privacy: .public)")
    }
})

extension HelperService {
    /// `FanControlHelperProtocol.setLowPowerMode`. The only inputs are two Bools; the argv is
    /// fixed. Runs on this connection's queue; the app sends it on its own short-lived,
    /// session-less connection, so a slow pmset never delays (or, on a client timeout, ends)
    /// the fan write session's connection.
    func setLowPowerMode(battery: Bool, ac: Bool, reply: @escaping (Int, String) -> Void) {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        let result = lowPowerModeHandler.handle(battery: battery, ac: ac, requester: "pid \(pid)")
        reply(result.code.rawValue, result.message)
    }
}
#endif
