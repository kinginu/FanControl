#if os(macOS)
import Foundation
import FanControlCore
@testable import FanControlKit

/// Test doubles for every dependency of `FanControlManager` and its components that
/// could reach the real system: the installed FanControlHelper (Mach service), the
/// SMC (IOKit), `SMAppService`, the power source, running apps and `UserDefaults`.
/// Kit tests build managers, coordinators and pollers only from these.
///
/// Not covered (no seam): `FanControlPoller.prepareReader()` opens the IOKit
/// `SMCClient`, so no test calls `startMonitoring()` / `refreshNow()` or applies a
/// profile that needs the SMC; the poller is driven through `run` / `enqueue`.
enum Isolated {

    /// A `HelperClient` whose connections go to an in-process anonymous listener that
    /// refuses them: an accidental call fails with `.helperConnectionFailed` instead
    /// of reaching the installed helper (which would write to the SMC).
    static func helperClient() -> HelperClient {
        let endpoint = RefusingListener.shared.endpoint
        return HelperClient(connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint.value) })
    }

    /// Reports a complete, correctly pinned manual installation, so `status()` and
    /// `register()` never query or call `SMAppService` and no file is read.
    static func installer() -> HelperInstaller {
        HelperInstaller(fileExists: { _ in true }, pinCheck: { .matches })
    }

    /// No other fan controller is installed; `running` bundle ids are "running".
    static func conflictDetector(running: Set<String> = []) -> ConflictingControllerDetector {
        ConflictingControllerDetector(isAppRunning: { running.contains($0) }, fileExists: { _ in false })
    }

    /// A manager on scratch defaults with isolated helper, installer, power source and
    /// conflict detector. Keep `defaults` alive for the test (it removes its suite on release).
    @MainActor
    static func manager(defaults: ScratchDefaults = ScratchDefaults(),
                        power: MockPowerSource = MockPowerSource(onBattery: false),
                        running: Set<String> = []) -> FanControlManager {
        FanControlManager(defaults: defaults.defaults, helperClient: helperClient(), installer: installer(),
                          powerSource: power, conflictDetector: conflictDetector(running: running))
    }

    /// A poller that talks to no helper (`helperClient()`); its IOKit reader is never opened by the tests.
    static func poller(label: String) -> FanControlPoller {
        FanControlPoller(helperClient: helperClient(), label: label)
    }
}

/// Anonymous `NSXPCListener` that refuses every connection (process lifetime).
private final class RefusingListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = RefusingListener()

    private let listener = NSXPCListener.anonymous()
    let endpoint: UncheckedBox<NSXPCListenerEndpoint>

    private override init() {
        endpoint = UncheckedBox(listener.endpoint)
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        false
    }
}

/// A `UserDefaults` suite private to one test: a fresh unique name, removed on release
/// (no state leaks between tests or runs).
final class ScratchDefaults: @unchecked Sendable {
    let suiteName = "FanControlKitTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// `PowerSourceProviding` without IOKit: starts on AC or battery, changes on `simulate`.
@MainActor
final class MockPowerSource: PowerSourceProviding {
    private(set) var isOnBattery: Bool
    private var onChange: (@MainActor (Bool) -> Void)?

    init(onBattery: Bool) { isOnBattery = onBattery }

    func startObserving(_ onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }

    func simulate(onBattery: Bool) {
        isOnBattery = onBattery
        onChange?(onBattery)
    }
}
#endif
