#if os(macOS)
import Foundation
import Observation
import FanControlCore

/// The poll-loop driver of `FanControlManager` (docs/kit.md "Architecture"): the
/// monitoring flag, the main-run-loop poll timer, the effective interval (power
/// source aware), and the Nook pause / live-data holds.
///
/// It decides *when* to poll; *what* a poll does is `FanControlPoller` (entered
/// through the `poll` hook, which the facade wires to `refreshNow()`). Main-actor state.
@MainActor
@Observable
final class MonitoringService {

    // MARK: - Observable state (forwarded by `FanControlManager`)

    private(set) var isMonitoring: Bool = false
    /// The host's last `setPaused` request (Nook hidden).
    private(set) var isMonitoringPaused: Bool = false
    /// `isMonitoringPaused` and no live-data hold.
    private(set) var isPauseInEffect: Bool = false
    private(set) var isOnBattery: Bool = false
    /// `PollingIntervalPolicy.effectiveInterval` of the settings below.
    private(set) var effectivePollingInterval: TimeInterval = 2.0

    // MARK: - Settings (forwarded by `FanControlManager`)

    var pollingInterval: TimeInterval = 2.0 {
        didSet { updateEffectivePollingInterval() }
    }
    var slowPollingOnBattery: Bool = true {
        didSet { updateEffectivePollingInterval() }
    }
    var batteryPollingInterval: TimeInterval = PollingIntervalPolicy.defaultBatteryInterval {
        didSet { updateEffectivePollingInterval() }
    }
    var keepAlertsWhilePaused: Bool = true {
        didSet {
            if keepAlertsWhilePaused != oldValue, isMonitoring, isPauseInEffect { scheduleTimer() }
        }
    }

    // MARK: - Private state, dependencies and hooks

    /// Interval of the scheduled poll timer, `nil` when none is scheduled (tests).
    @ObservationIgnored private(set) var scheduledTimerInterval: TimeInterval?
    @ObservationIgnored private var pauseState = MonitoringPauseState()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let powerSource: any PowerSourceProviding
    @ObservationIgnored private let poller: FanControlPoller
    /// Whether a write session is open: it keeps the slow poll alive while paused.
    @ObservationIgnored var isSessionOpen: () -> Bool = { false }
    /// Runs before every timer / wake / un-pause poll (the conflict check).
    @ObservationIgnored var beforePoll: (() -> Void)?
    /// Performs one poll (the facade's `refreshNow()`).
    @ObservationIgnored var poll: (() -> Void)?

    /// Reads the power source once and starts observing it.
    init(poller: FanControlPoller, powerSource: any PowerSourceProviding) {
        self.poller = poller
        self.powerSource = powerSource
        isOnBattery = powerSource.isOnBattery
        updateEffectivePollingInterval()
        powerSource.startObserving { [weak self] onBattery in
            self?.powerSourceDidChange(onBattery)
        }
    }

    // MARK: - Start / stop

    /// Sets the monitoring flag (here and, in order, on the poller). Returns `false`
    /// if monitoring was already on. The caller then schedules the timer
    /// (`scheduleTimer()`) and polls.
    func markStarted() -> Bool {
        guard !isMonitoring else { return false }
        isMonitoring = true
        poller.enqueue { $0.monitoringActive = true }
        return true
    }

    /// Clears the flag, stops the timer and closes the SMC reader on the poll
    /// queue (queued polls are dropped there). Returns `false` if not monitoring.
    func stop() -> Bool {
        guard isMonitoring else { return false }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        poller.enqueue { poller in
            poller.monitoringActive = false
            poller.closeReader()
        }
        return true
    }

    /// Timer / wake / un-pause polls: only while monitoring.
    func pollIfMonitoring() {
        guard isMonitoring else { return }
        beforePoll?()
        poll?()
    }

    // MARK: - Pause / live-data hold

    func setPaused(_ paused: Bool) {
        guard paused != isMonitoringPaused else { return }
        isMonitoringPaused = paused
        pauseState.requested = paused
        syncPauseInEffect()
    }

    func setLiveDataHold(_ held: Bool, for holder: String) {
        pauseState.setHold(held, for: holder)
        syncPauseInEffect()
    }

    /// Reschedules the timer when `isPauseInEffect` changes; polls at once when
    /// the pause ends.
    private func syncPauseInEffect() {
        let inEffect = pauseState.isInEffect
        guard inEffect != isPauseInEffect else { return }
        isPauseInEffect = inEffect
        scheduleTimer()
        if !inEffect { pollIfMonitoring() }
    }

    /// The session flag changed: while paused, a session keeps slow polling alive.
    func sessionStateDidChange() {
        if isPauseInEffect { scheduleTimer() }
    }

    // MARK: - Timer

    /// Recomputes `effectivePollingInterval`; reschedules the timer (while
    /// monitoring) when it changed.
    private func updateEffectivePollingInterval() {
        let interval = PollingIntervalPolicy.effectiveInterval(
            pollingInterval: pollingInterval, batteryInterval: batteryPollingInterval,
            slowOnBattery: slowPollingOnBattery, onBattery: isOnBattery)
        guard interval != effectivePollingInterval else { return }
        effectivePollingInterval = interval
        if isMonitoring { scheduleTimer() }
    }

    /// `PowerSourceProviding` callback (main actor).
    private func powerSourceDidChange(_ onBattery: Bool) {
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        updateEffectivePollingInterval()
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        scheduledTimerInterval = nil
        guard isMonitoring else { return }
        let interval: TimeInterval
        if isPauseInEffect {
            // Slow mode keeps sensor-based modes / the emergency override (session)
            // and the alerts (`keepAlertsWhilePaused`) alive while hidden.
            guard isSessionOpen() || keepAlertsWhilePaused else { return }
            interval = PollingIntervalPolicy.pausedInterval(effective: effectivePollingInterval)
        } else {
            interval = effectivePollingInterval
        }
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.pollIfMonitoring() }
        }
        newTimer.tolerance = interval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        scheduledTimerInterval = interval
    }
}
#endif
