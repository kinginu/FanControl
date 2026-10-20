#if os(macOS)
import AppKit
import Foundation
import IOKit
import FanControlCore

// F2: The live context power-profile rules are evaluated against (power source, lid, time).
// macOS Focus is deliberately absent: no public API reports which Focus is on
// (DynamicNotchApp/docs/power-profiles.md "Focus").

/// Supplies `PowerContext` to `PowerProfileEngine` (a fake in tests).
@MainActor
public protocol PowerContextProviding: AnyObject {
    func currentContext() -> PowerContext
    /// Calls `onChange` (main actor) whenever the context may have changed: power source,
    /// lid, wake, Low Power Mode, and a periodic tick for time windows. Replaces a previous handler.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// `PowerContextProviding` from IOKit and the system clock:
/// - power source: `PowerSourceMonitor` (IOPS notifications);
/// - lid: `IOPMrootDomain`'s `AppleClamshellState` (re-read on every root-domain
///   interest message, e.g. clamshell changes, and on the tick); `nil` on Macs without a lid;
/// - time: a tick every `tickInterval` (time windows have minute resolution);
/// - wake (`NSWorkspace.didWakeNotification`) and Low Power Mode changes
///   (`NSProcessInfoPowerStateDidChange`).
@MainActor
public final class SystemPowerContextProvider: PowerContextProviding {
    public nonisolated static let tickInterval: TimeInterval = 30

    private let powerSource = PowerSourceMonitor()
    private var onChange: (@MainActor () -> Void)?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyPort: IONotificationPortRef?
    private var interest: io_object_t = IO_OBJECT_NULL
    private var lastLidClosed: Bool?

    public init() {
        lastLidClosed = Self.readIsLidClosed()
    }

    isolated deinit {
        stopObserving()
    }

    public func currentContext() -> PowerContext {
        let lid = Self.readIsLidClosed()
        lastLidClosed = lid
        return PowerContext(powerSource: powerSource.isOnBattery ? .battery : .ac, isLidClosed: lid, date: Date())
    }

    /// `AppleClamshellState` of `IOPMrootDomain`; `nil` when absent (no lid) or unreadable.
    public nonisolated static func readIsLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value as? Bool
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard timer == nil else { return }
        powerSource.startObserving { [weak self] _ in self?.changed() }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        observers.append((workspace, wake))
        // Posted on an arbitrary thread.
        let lowPower = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        observers.append((NotificationCenter.default, lowPower))
        startLidObservation()
    }

    public func stopObserving() {
        onChange = nil
        timer?.invalidate()
        timer = nil
        powerSource.stopObserving()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if interest != IO_OBJECT_NULL {
            IOObjectRelease(interest)
            interest = IO_OBJECT_NULL
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
    }

    private func changed() {
        onChange?()
    }

    /// Root-domain general-interest messages (clamshell open / close among them) on the main
    /// run loop; each one re-reads the lid and reports a change.
    private func startLidObservation() {
        guard notifyPort == nil, lastLidClosed != nil else { return }  // no lid: nothing to watch
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notification: io_object_t = IO_OBJECT_NULL
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemPowerContextProvider>.fromOpaque(refcon).takeUnretainedValue().lidMessage()
            }
        }, context, &notification)
        guard result == KERN_SUCCESS else {
            kitLog.error("IOServiceAddInterestNotification(IOPMrootDomain) failed: \(result, privacy: .public); lid changes are seen on the periodic tick only")
            IONotificationPortDestroy(port)
            return
        }
        notifyPort = port
        interest = notification
    }

    private func lidMessage() {
        let lid = Self.readIsLidClosed()
        guard lid != lastLidClosed else { return }
        lastLidClosed = lid
        kitLog.notice("Lid \(lid == true ? "closed" : "open", privacy: .public)")
        changed()
    }
}
#endif
