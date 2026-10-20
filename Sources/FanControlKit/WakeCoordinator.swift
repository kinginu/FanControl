#if os(macOS)
import AppKit
import Observation

/// What `WakeCoordinator` needs from the rest of the kit (the facade implements it).
@MainActor
protocol WakeCoordinatorHost: AnyObject {
    /// Whether the helper write session is open.
    var isSessionOpen: Bool { get }
    /// A poll if monitoring (`MonitoringService.pollIfMonitoring()`).
    func pollIfMonitoring()
    /// Sets (in order with the queued polls) the poller's sleep flag, which
    /// suspends poll-driven writes.
    func setSystemSleeping(_ sleeping: Bool)
    /// Closes the session in a new task (`FanController.closeSessionInBackground()`).
    func closeSessionAfterWake()
    /// Re-applies the active profile in a new task without ever opening a session
    /// (`FanController.reapplyActiveProfile(recordingErrors:)`).
    func reapplyActiveProfileAfterWake(recordingErrors: Bool)
}

/// Sleep / wake handling of `FanControlManager` (docs/kit.md "Architecture").
///
/// Across sleep the SMC resets `F<n>Tg` to 0 but keeps `F<n>Md` = 1
/// (first-write test 4), so with a session open at wake:
/// - `reapplyProfileAfterWake == true`: the active profile is re-applied right
///   away and again at `delays` (bypassing the throttle, never opening a session;
///   errors are recorded only for the last attempt, since the SMC may reject
///   writes right at wake);
/// - `false`: the session is closed immediately (the helper restores).
/// The flag is read when each attempt runs. Polls resume (and flag unsettled
/// fans) at once. Before sleep nothing destructive happens: the helper hands the
/// forced fans back to the SMC itself (`docs/helper.md` §5).
@MainActor
@Observable
final class WakeCoordinator {

    /// Seconds after `NSWorkspace.didWakeNotification` of the re-apply attempts.
    nonisolated static let defaultReapplyDelays: [TimeInterval] = [0, 2, 5]

    /// `FanControlManager.reapplyProfileAfterWake`.
    var reapplyProfileAfterWake: Bool = true

    @ObservationIgnored weak var host: (any WakeCoordinatorHost)?
    @ObservationIgnored let delays: [TimeInterval]
    /// Runs a work item after a delay on the main queue (injected by tests).
    @ObservationIgnored private let schedule: @MainActor (TimeInterval, DispatchWorkItem) -> Void
    /// Pending wake re-apply attempts.
    @ObservationIgnored private var workItems: [DispatchWorkItem] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(delays: [TimeInterval] = WakeCoordinator.defaultReapplyDelays,
         schedule: @escaping @MainActor (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
         }) {
        self.delays = delays
        self.schedule = schedule
    }

    /// Number of scheduled attempts not yet cancelled (tests).
    var pendingAttemptCount: Int { workItems.filter { !$0.isCancelled }.count }

    /// Observes `NSWorkspace` will-sleep / did-wake (main queue). Idempotent.
    func registerObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        let sleep = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        observers = [wake, sleep]
    }

    /// Cancels pending wake attempts and stops poll-driven writes until wake.
    func handleWillSleep() {
        cancelPendingWork()
        host?.setSystemSleeping(true)
        if host?.isSessionOpen == true {
            kitLog.notice("System will sleep; poll writes suspended (the helper hands the fans back to the SMC)")
        }
    }

    func handleWake() {
        cancelPendingWork()
        guard let host else { return }
        host.setSystemSleeping(false)
        host.pollIfMonitoring()
        guard host.isSessionOpen else { return }
        guard reapplyProfileAfterWake else {
            kitLog.notice("Woke with a session open and reapplyProfileAfterWake off: closing the session")
            host.closeSessionAfterWake()
            return
        }
        kitLog.notice("Woke with a session open: re-applying the active profile at \(self.delays.map { "\($0)s" }.joined(separator: ", "), privacy: .public)")
        for (index, delay) in delays.enumerated() {
            let isLast = index == delays.count - 1
            let item = DispatchWorkItem { [weak self] in
                // Executed on the main queue (`schedule`).
                MainActor.assumeIsolated { self?.reapplyAttempt(polling: delay > 0, isLast: isLast) }
            }
            workItems.append(item)
            schedule(delay, item)
        }
    }

    /// One wake re-apply attempt.
    private func reapplyAttempt(polling: Bool, isLast: Bool) {
        guard let host else { return }
        if polling { host.pollIfMonitoring() }
        guard host.isSessionOpen else { return }
        guard reapplyProfileAfterWake else {
            host.closeSessionAfterWake()
            return
        }
        host.reapplyActiveProfileAfterWake(recordingErrors: isLast)
    }

    func cancelPendingWork() {
        workItems.forEach { $0.cancel() }
        workItems = []
    }
}
#endif
