#if os(macOS)
import AppKit
import Observation
import FanControlCore
import FanControlXPC

/// The helper side of `FanControlManager` (docs/kit.md "Architecture"): install
/// status, the connection / session handshake, the session flag mirrored from
/// `HelperClient`, and the detection of other fan control apps.
///
/// Main-actor state; `SMAppService.register()` runs off the main actor. It never
/// opens a session on its own: `openSession()` is only reached from explicit user
/// actions through `FanController`.
@MainActor
@Observable
final class HelperCoordinator {

    /// While monitoring, `conflictingControllers` is re-checked at most this often
    /// from the poll timer (besides app launch / terminate notifications).
    nonisolated static let conflictCheckInterval: TimeInterval = 60

    // MARK: - Observable state (forwarded by `FanControlManager`)

    private(set) var helperStatus: HelperInstallStatus = .notRegistered
    private(set) var helperConnectionState: HelperConnectionState = .disconnected
    /// Mirrors `client.isSessionOpen` (`syncSessionFlag()`).
    private(set) var isSMCWriteSessionOpen: Bool = false
    private(set) var conflictingControllers: [String] = [] {
        didSet {
            guard conflictingControllers != oldValue else { return }
            onConflictingControllersChange?(conflictingControllers)
        }
    }
    private(set) var conflictingControllerStatuses: [ConflictingControllerStatus] = []

    // MARK: - Dependencies and hooks

    @ObservationIgnored nonisolated let client: HelperClient
    @ObservationIgnored nonisolated let installer: HelperInstaller
    @ObservationIgnored let conflictDetector: ConflictingControllerDetector
    /// When `conflictingControllers` was last refreshed.
    @ObservationIgnored private(set) var lastConflictCheck: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// `install()` and `retryConnection()` record their errors here.
    @ObservationIgnored var recordErrors: ErrorRecorder = .ignoring
    /// Called on the main actor after `isSMCWriteSessionOpen` changed.
    @ObservationIgnored var onSessionFlagChange: (() -> Void)?
    /// Called after `conflictingControllers` changed (the facade posts the notification).
    @ObservationIgnored var onConflictingControllersChange: (([String]) -> Void)?

    init(client: HelperClient, installer: HelperInstaller, conflictDetector: ConflictingControllerDetector) {
        self.client = client
        self.installer = installer
        self.conflictDetector = conflictDetector
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperConnectionState = state
                self.syncSessionFlag()
            }
        }
    }

    var isSessionOpen: Bool { client.isSessionOpen }

    /// Mirrors `client.isSessionOpen` into `isSMCWriteSessionOpen`.
    func syncSessionFlag() {
        let open = client.isSessionOpen
        guard open != isSMCWriteSessionOpen else { return }
        isSMCWriteSessionOpen = open
        onSessionFlagChange?()
    }

    // MARK: - Install status

    /// File / `SMAppService` reads only; never connects to the helper.
    func refreshStatus() {
        helperStatus = installer.status()
    }

    /// `FanControlManager.installHelper()`.
    func install() async throws {
        try await recordErrors {
            // `SMAppService.register()` talks to launchd / BTM: keep it off the main actor.
            let status = try await Self.register(self.installer)
            self.helperStatus = status
            try Self.requireUsable(status)
        }
    }

    /// Maps a registration result to the error `installHelper()` throws (none for
    /// `.enabled` / `.installedManually`).
    static func requireUsable(_ status: HelperInstallStatus) throws {
        switch status {
        case .enabled, .installedManually:
            return
        case .installedManuallyMismatch(let pinned, let app):
            // Only root can re-pin: the user must re-run install.sh.
            throw FanControlError.helperConnectionRejected(
                HelperRejectionReason.clientNotPinned(pinnedCDHash: pinned, appCDHash: app).description)
        case .requiresApproval:
            HelperInstaller.openSystemSettingsLoginItems()
            throw FanControlError.helperNotInstalled
        case .notFound:
            throw FanControlError.helperConnectionFailed(
                "\(FanControlHelperConstants.plistName) is missing from DynamicNotch.app/Contents/Library/LaunchDaemons.")
        case .notRegistered, .unknown:
            throw FanControlError.helperNotInstalled
        }
    }

    /// Runs `installer.register()` on the global concurrent executor.
    private nonisolated static func register(_ installer: HelperInstaller) async throws -> HelperInstallStatus {
        try installer.register()
    }

    // MARK: - Session handshake

    /// Ensures the helper is registered (`install()`), checks its protocol version
    /// (re-registering a stale helper once) and opens the write session. Does not
    /// record errors itself (`FanController.openSession()` does).
    func openSession() async throws {
        let status = installer.status()
        helperStatus = status
        // A manual installation pinned to another build is not "installed" for this
        // app, but there is nothing to register either: `version()` below is
        // refused by `HelperClient` without connecting (`.clientNotPinned`).
        if status != .enabled && !status.isManualInstallation {
            try await install()
        }
        var (version, _) = try await client.version()
        if version != FanControlHelperConstants.protocolVersion, status.isManualInstallation {
            // Only root can replace a manually installed helper.
            throw FanControlError.helperRejected(
                code: -1,
                message: "The manually installed helper speaks protocol \(version), the app needs \(FanControlHelperConstants.protocolVersion). Re-run sudo \(FanControlHelperConstants.manualInstallScriptName) with this app.")
        }
        if version != FanControlHelperConstants.protocolVersion {
            // A helper from an older/newer app build is still registered.
            client.invalidate()
            try? await installer.unregister()
            try await install()
            (version, _) = try await client.version()
            guard version == FanControlHelperConstants.protocolVersion else {
                throw FanControlError.helperRejected(
                    code: -1,
                    message: "Helper protocol version \(version) does not match the app's \(FanControlHelperConstants.protocolVersion).")
            }
        }
        try await client.openSession()
    }

    /// `FanControlManager.retryHelperConnection()`: forgets a sticky rejection,
    /// re-reads the status and probes an installed helper with `version()`.
    func retryConnection() async throws {
        try await recordErrors {
            self.client.resetRejection()
            let status = self.installer.status()
            self.helperStatus = status
            guard status == .enabled || status.isManualInstallation else { return }
            _ = try await self.client.version()
        }
    }

    // MARK: - Conflicting controllers

    /// Re-runs the conflict check. Cheap: `NSRunningApplication` and `stat`.
    func refreshConflictingControllers(now: Date = Date()) {
        lastConflictCheck = now
        let statuses = conflictDetector.detect()
        if statuses != conflictingControllerStatuses { conflictingControllerStatuses = statuses }
        let names = ConflictingControllerDetector.runningNames(statuses)
        if names != conflictingControllers {
            if !names.isEmpty {
                kitLog.notice("Other fan control app running: \(names.joined(separator: ", "), privacy: .public)")
            }
            conflictingControllers = names
        }
    }

    /// Whether the poll timer should re-check (`conflictCheckInterval` elapsed or never checked).
    func isConflictCheckDue(now: Date = Date()) -> Bool {
        lastConflictCheck.map { now.timeIntervalSince($0) >= Self.conflictCheckInterval } ?? true
    }

    /// Called before every timer / wake / un-pause poll.
    func refreshConflictingControllersIfDue(now: Date = Date()) {
        if isConflictCheckDue(now: now) { refreshConflictingControllers(now: now) }
    }

    /// Re-checks when another fan control app launches or quits. Idempotent.
    func registerObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            // Delivered on the main queue.
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleIdentifier = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.applicationLaunchedOrTerminated(bundleIdentifier) }
            }
            observers.append(token)
        }
    }

    private func applicationLaunchedOrTerminated(_ bundleIdentifier: String?) {
        guard conflictDetector.isRelevant(bundleIdentifier: bundleIdentifier) else { return }
        refreshConflictingControllers()
    }
}
#endif
