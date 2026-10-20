#if os(macOS)
import Foundation
import IOKit.ps

/// Where the Mac currently draws power from (design doc §5.4 (a)).
/// Injected into `FanControlManager` (`init(powerSource:)`) so tests can switch it.
@MainActor
public protocol PowerSourceProviding: AnyObject {
    /// `true` while running on battery; `false` on AC power, on a Mac without a
    /// battery and when the state cannot be read.
    var isOnBattery: Bool { get }
    /// Starts delivering changes of `isOnBattery` on the main actor (replacing a
    /// previous handler). Called once by the manager.
    func startObserving(_ onChange: @escaping @MainActor (Bool) -> Void)
    func stopObserving()
}

/// `PowerSourceProviding` backed by IOKit power-source notifications
/// (`IOPSNotificationCreateRunLoopSource` on the main run loop) and
/// `IOPSGetProvidingPowerSourceType` (`kIOPSBatteryPowerValue` = on battery;
/// `kIOPSACPowerValue`, `kIOPSUPSPowerValue` or no information = not on battery).
@MainActor
public final class PowerSourceMonitor: PowerSourceProviding {

    public private(set) var isOnBattery: Bool
    private var onChange: (@MainActor (Bool) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    public init() {
        isOnBattery = Self.readIsOnBattery()
    }

    isolated deinit {
        stopObserving()
    }

    /// Reads the providing power source once (cheap, no I/O beyond IOKit).
    public nonisolated static func readIsOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == kIOPSBatteryPowerValue
    }

    public func startObserving(_ onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The callback runs on the run loop the source is added to (main).
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
            }
        }, context)?.takeRetainedValue() else {
            kitLog.error("IOPSNotificationCreateRunLoopSource failed; power source changes are not observed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        // The state may have changed between init and now.
        powerSourceChanged()
    }

    public func stopObserving() {
        onChange = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
    }

    private func powerSourceChanged() {
        let onBattery = Self.readIsOnBattery()
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        kitLog.notice("Power source changed: \(onBattery ? "battery" : "AC", privacy: .public)")
        onChange?(onBattery)
    }
}
#endif
