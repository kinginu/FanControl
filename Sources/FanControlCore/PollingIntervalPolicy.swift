import Foundation

/// Pure poll-interval selection (design doc §5.4 (a) and (c)), used by
/// `FanControlManager` to schedule its timer.
public enum PollingIntervalPolicy {

    /// Effective range of any poll interval (seconds).
    public static let allowedRange: ClosedRange<TimeInterval> = 0.5...300
    /// Default interval on battery when `slowOnBattery` is on (seconds).
    public static let defaultBatteryInterval: TimeInterval = 10
    /// Lower bound of the low-frequency poll while the Nook pause is in effect.
    public static let minimumPausedInterval: TimeInterval = 10
    /// The paused interval is this many times the effective interval.
    public static let pausedMultiplier: Double = 5

    /// The interval the timer uses while the pause is not in effect:
    /// `slowOnBattery && onBattery ? max(pollingInterval, batteryInterval) : pollingInterval`,
    /// clamped to `allowedRange`. A non-finite input falls back to the other value
    /// (or to 2 s when both are invalid).
    public static func effectiveInterval(pollingInterval: TimeInterval, batteryInterval: TimeInterval,
                                         slowOnBattery: Bool, onBattery: Bool) -> TimeInterval {
        let base = pollingInterval.isFinite ? pollingInterval : 2
        var interval = base
        if slowOnBattery && onBattery && batteryInterval.isFinite {
            interval = max(base, batteryInterval)
        }
        return min(max(interval, allowedRange.lowerBound), allowedRange.upperBound)
    }

    /// The low-frequency poll while the Nook pause is in effect (session open or
    /// alerts kept alive): `max(5 × effective, 10 s)` (not clamped further).
    public static func pausedInterval(effective: TimeInterval) -> TimeInterval {
        max(effective * pausedMultiplier, minimumPausedInterval)
    }
}
