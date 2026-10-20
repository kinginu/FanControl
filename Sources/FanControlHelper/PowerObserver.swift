#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt
import FanControlXPC

/// IOKit system power notifications for the helper (thin glue; the decisions are in
/// `PowerTransitionPolicy`, executed by `SessionRegistry`).
///
/// The helper runs `dispatchMain()` (no CFRunLoop on the main thread), so the
/// notification port is attached to a private dispatch queue
/// (`IONotificationPortSetDispatchQueue`) instead of a run-loop source.
///
/// - `kIOMessageCanSystemSleep`: always allowed (idle sleep is not vetoed).
/// - `kIOMessageSystemWillSleep`: `SessionRegistry.prepareForSleep()` (hands the
///   session's forced fans back to the SMC), then `IOAllowPowerChange`. The writes
///   are a handful of SMC calls; the acknowledgement is sent even if they fail, well
///   within the 30 s limit.
/// - `kIOMessageSystemHasPoweredOn`: `SessionRegistry.recoverAfterWake` at
///   `PowerTransitionPolicy.wakeRetryDelays` (0 s, 1 s, 3 s). A new sleep cancels
///   the attempts still pending.
final class PowerObserver: @unchecked Sendable {
    static let shared = PowerObserver()

    // IOMessage.h: iokit_common_msg(x) = sys_iokit (0xE0000000) | sub_iokit_common (0) | x.
    // The macros are not imported into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemWillNotSleep: UInt32 = 0xE000_0290
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    static let systemWillPowerOn: UInt32 = 0xE000_0320

    private let queue = DispatchQueue(label: "com.example.dynamicnotch.DynamicNotch.fanfi.power")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Bumped on every sleep / wake (queue only); stale wake attempts are dropped.
    private var epoch: UInt64 = 0

    private init() {}

    /// Registers for system power notifications. Returns `false` (and logs) on failure;
    /// the helper keeps running without sleep/wake handling in that case.
    @discardableResult
    func start() -> Bool {
        guard rootPort == 0 else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let port = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType: messageType, argument: messageArgument)
        }, &notifier)
        guard port != 0, let notifyPort else {
            helperLog.error("Power: IORegisterForSystemPower failed; sleep/wake fan handling is disabled")
            return false
        }
        rootPort = port
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        helperLog.info("Power: registered for system sleep/wake notifications")
        return true
    }

    /// Runs on `queue`.
    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            epoch &+= 1
            SessionRegistry.shared.prepareForSleep()
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillNotSleep:
            helperLog.info("Power: sleep cancelled")
        case Self.systemWillPowerOn:
            break
        case Self.systemHasPoweredOn:
            epoch &+= 1
            let current = epoch
            let delays = PowerTransitionPolicy.wakeRetryDelays
            helperLog.notice("Power: system has powered on; wake recovery at \(delays.map { "\($0)s" }.joined(separator: ", "), privacy: .public)")
            for (index, delay) in delays.enumerated() {
                queue.asyncAfter(deadline: .now() + delay) { [self] in
                    guard epoch == current else { return }
                    SessionRegistry.shared.recoverAfterWake(attempt: index + 1, of: delays.count)
                }
            }
        default:
            break
        }
    }
}
#endif
