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
    /// `FanControlHelperProtocol.setLowPowerMode`. The only input is a Bool; the argv is fixed.
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Int, String) -> Void) {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        let result = lowPowerModeHandler.handle(enabled: enabled, requester: "pid \(pid)")
        reply(result.code.rawValue, result.message)
    }
}
#endif
