#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt
import FanControlXPC

/// IOKit system power notifications for the helper (thin glue; the decisions are in
/// `PowerTransitionPolicy`, executed by `SessionRegistry`).
///
/// The helper runs `dispatchMain()` (no CFRunLoop on the main thread), so the
/// notification port is attached to a private serial dispatch queue
/// (`IONotificationPortSetDispatchQueue`) instead of a run-loop source. That queue
/// is also this actor's executor, so the IOKit callback runs isolated to it.
///
/// - `kIOMessageCanSystemSleep`: always allowed (idle sleep is not vetoed).
/// - `kIOMessageSystemWillSleep`: `SessionRegistry.prepareForSleep()` (hands the
///   session's forced fans back to the SMC), then `IOAllowPowerChange`. The writes
///   are a handful of SMC calls; the acknowledgement is sent even if they fail, well
///   within the 30 s limit.
/// - `kIOMessageSystemHasPoweredOn`: `SessionRegistry.recoverAfterWake` at
///   `PowerTransitionPolicy.wakeRetryDelays` (0 s, 1 s, 3 s). A new sleep cancels
///   the attempts still pending.
actor PowerObserver {
    static let shared = PowerObserver()

    /// IOMessage.h: `iokit_common_msg(x)` = sys_iokit (0xE0000000) | sub_iokit_common (0) | x.
    /// The macros are not imported into Swift.
    private enum Message: UInt32 {
        case canSystemSleep = 0xE000_0270
        case systemWillSleep = 0xE000_0280
        case systemWillNotSleep = 0xE000_0290
        case systemHasPoweredOn = 0xE000_0300
        case systemWillPowerOn = 0xE000_0320
    }

    private nonisolated let queue = DispatchSerialQueue(label: FanControlHelperConstants.machServiceName + ".power")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Bumped on every sleep / wake (queue only); stale wake attempts are dropped.
    private var epoch: UInt64 = 0

    private init() {}

    /// Registers for system power notifications. Returns `false` (and logs) on failure;
    /// the helper keeps running without sleep/wake handling in that case.
    /// Synchronous (runs on `queue` with `queue.sync`).
    @discardableResult
    nonisolated func start() -> Bool {
        queue.sync {
            assumeIsolated { $0.register() }
        }
    }

    private func register() -> Bool {
        guard rootPort == 0 else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let port = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            // The argument is only an opaque token for IOAllowPowerChange.
            let token = Int(bitPattern: messageArgument)
            // Delivered on `queue` (IONotificationPortSetDispatchQueue below), the executor.
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().assumeIsolated {
                $0.handle(messageType: messageType, token: token)
            }
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
    private func handle(messageType: UInt32, token: Int) {
        guard let message = Message(rawValue: messageType) else { return }
        switch message {
        case .canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case .systemWillSleep:
            epoch &+= 1
            SessionRegistry.shared.prepareForSleep()
            IOAllowPowerChange(rootPort, token)
        case .systemWillNotSleep:
            helperLog.info("Power: sleep cancelled")
        case .systemWillPowerOn:
            break
        case .systemHasPoweredOn:
            epoch &+= 1
            let current = epoch
            let delays = PowerTransitionPolicy.wakeRetryDelays
            helperLog.notice("Power: system has powered on; wake recovery at \(delays.map { "\($0)s" }.joined(separator: ", "), privacy: .public)")
            for (index, delay) in delays.enumerated() {
                queue.asyncAfter(deadline: .now() + delay) { [self] in
                    let isCurrent = assumeIsolated { $0.epoch == current }
                    guard isCurrent else { return }
                    SessionRegistry.shared.recoverAfterWake(attempt: index + 1, of: delays.count)
                }
            }
        }
    }
}
#endif
