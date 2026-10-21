#if os(macOS)
import AppKit

/// Another fan control app whose writes would fight ours.
/// Our helper uses its own Mach service (`FanControlHelperConstants`), so the two
/// helpers do not collide; but both apps writing `F<n>Md` / `F<n>Tg` at the same
/// time override each other.
public struct ConflictingController: Sendable, Hashable {
    /// Shown in the UI (not localized: a product name).
    public var displayName: String
    /// Bundle identifiers of the app (`NSRunningApplication`).
    public var bundleIdentifiers: [String]
    /// launchd labels of its privileged helper: installed when
    /// `/Library/LaunchDaemons/<label>.plist` or `/Library/PrivilegedHelperTools/<label>` exists.
    public var helperLabels: [String]

    public init(displayName: String, bundleIdentifiers: [String], helperLabels: [String]) {
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
        self.helperLabels = helperLabels
    }

    /// FanFi: app `com.fanfi.fanfi`, with a privileged helper whose launchd label and Mach
    /// service are `com.fanfi.fanfi.smcwrite` (as installed under /Library/LaunchDaemons).
    public static let fanFi = ConflictingController(displayName: "FanFi",
                                                    bundleIdentifiers: ["com.fanfi.fanfi"],
                                                    helperLabels: ["com.fanfi.fanfi.smcwrite"])

    /// The controllers checked by default.
    public static let known: [ConflictingController] = [.fanFi]
}

/// What `ConflictingControllerDetector.detect()` found for one controller.
public struct ConflictingControllerStatus: Sendable, Hashable {
    public var controller: ConflictingController
    /// The app is running now: its writes may override ours (and vice versa).
    public var isAppRunning: Bool
    /// Its helper is installed (it can write whenever the app runs).
    public var isHelperInstalled: Bool

    public init(controller: ConflictingController, isAppRunning: Bool, isHelperInstalled: Bool) {
        self.controller = controller
        self.isAppRunning = isAppRunning
        self.isHelperInstalled = isHelperInstalled
    }
}

/// Detects other fan control apps. Probes are injectable for tests;
/// the defaults ask `NSRunningApplication` and the file system (cheap, no I/O beyond `stat`).
public struct ConflictingControllerDetector: Sendable {
    public static let launchDaemonsDirectory = "/Library/LaunchDaemons"
    public static let privilegedHelperToolsDirectory = "/Library/PrivilegedHelperTools"

    public var controllers: [ConflictingController]
    /// `true` when an app with this bundle identifier is running.
    public var isAppRunning: @Sendable (String) -> Bool
    /// `true` when a file exists at this absolute path.
    public var fileExists: @Sendable (String) -> Bool

    public init(controllers: [ConflictingController] = ConflictingController.known,
                isAppRunning: @escaping @Sendable (String) -> Bool = Self.systemIsAppRunning,
                fileExists: @escaping @Sendable (String) -> Bool = Self.systemFileExists) {
        self.controllers = controllers
        self.isAppRunning = isAppRunning
        self.fileExists = fileExists
    }

    public static let systemIsAppRunning: @Sendable (String) -> Bool = { bundleIdentifier in
        // Right after `didTerminateApplicationNotification` the app may still be listed.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    public static let systemFileExists: @Sendable (String) -> Bool = { path in
        FileManager.default.fileExists(atPath: path)
    }

    /// The paths that mark `label`'s helper as installed.
    public static func helperPaths(label: String) -> [String] {
        ["\(launchDaemonsDirectory)/\(label).plist", "\(privilegedHelperToolsDirectory)/\(label)"]
    }

    /// One status per controller that is running or has its helper installed
    /// (controllers with neither are left out), in `controllers` order.
    public func detect() -> [ConflictingControllerStatus] {
        controllers.compactMap { controller in
            let running = controller.bundleIdentifiers.contains { isAppRunning($0) }
            let installed = controller.helperLabels.contains { label in
                Self.helperPaths(label: label).contains { fileExists($0) }
            }
            guard running || installed else { return nil }
            return ConflictingControllerStatus(controller: controller, isAppRunning: running,
                                               isHelperInstalled: installed)
        }
    }

    /// Display names of the controllers whose app is running (the ones that can
    /// write right now), without duplicates, in `statuses` order.
    public static func runningNames(_ statuses: [ConflictingControllerStatus]) -> [String] {
        var seen = Set<String>()
        return statuses.filter(\.isAppRunning).map(\.controller.displayName).filter { seen.insert($0).inserted }
    }

    /// `true` when `bundleIdentifier` belongs to one of `controllers` (used to
    /// ignore unrelated app launch / terminate notifications).
    public func isRelevant(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return controllers.contains { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }
}
#endif
