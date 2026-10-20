import Foundation

/// Deadband, minimum dwell and slew limit on planned targets (`FanControlEngine.plan`
/// output), per fan. Pure state machine; the poll loop feeds it, user applies `seed` it.
///
/// For a fan with a previous stabilized target `last` (changed at `changedAt`) and a
/// planned target `p`:
/// - `p == nil` (automatic): passed through, the fan's state is dropped;
/// - no state (first manual target, e.g. after automatic) or `bypass` (emergency
///   override): `p` as-is;
/// - `|p - last| < deadbandRPM` and `p` is not the fan's minimum / maximum: `last`;
/// - a decrease, or a reversal (or any change when `dwellAppliesToIncreases`), less than
///   `minimumDwell` after `changedAt`: `last`;
/// - a decrease that has not been planned on every poll for `minimumDwell` (the timer
///   restarts whenever a poll plans no decrease): `last`;
/// - otherwise `last` moved toward `p` by at most `maximumStepRPM`.
public struct FanTargetStabilizer: Sendable {
    /// The stabilized target of one fan (internal; inspected by tests).
    struct State: Hashable, Sendable {
        /// The last stabilized target.
        var rpm: Int
        /// When `rpm` last changed.
        var changedAt: Date
        /// Sign of the last change (+1 up, -1 down, 0 none / seeded).
        var direction: Int
        /// Since when every poll has planned a decrease beyond the deadband.
        var decreaseRequestedSince: Date?
    }

    /// Per fan id; fans under automatic control have no entry.
    private(set) var states: [Int: State] = [:]

    public init() {}

    /// Stabilizes `plan` (fan id → planned RPM or `nil` = automatic) at `time`.
    /// `fans` provides each fan's range (targets at its bounds bypass the deadband).
    /// With `bypass`, every planned target is taken as-is (and recorded).
    public mutating func stabilize(_ plan: [Int: Int?], fans: [FanDevice], at time: Date,
                                   tuning: FanControlTuning, bypass: Bool = false) -> [Int: Int?] {
        let ranges = Dictionary(fans.map { ($0.id, $0.rpmRange) }, uniquingKeysWith: { first, _ in first })
        var result: [Int: Int?] = [:]
        for (fan, planned) in plan {
            guard let planned else {
                states[fan] = nil
                result.updateValue(nil, forKey: fan)
                continue
            }
            let target: Int
            if !bypass, let last = states[fan] {
                target = limited(planned, last: last, fan: fan, range: ranges[fan], at: time, tuning: tuning)
            } else {
                target = adopted(planned, fan: fan, at: time)
            }
            result.updateValue(target, forKey: fan)
        }
        return result
    }

    /// Records `plan` as the current targets (an explicit apply, wake re-apply, restore):
    /// no limits, and the dwell restarts at `time` for every changed fan.
    public mutating func seed(_ plan: [Int: Int?], fans: [FanDevice], at time: Date) {
        _ = stabilize(plan, fans: fans, at: time, tuning: .default, bypass: true)
    }

    /// Forgets every fan (session opened / closed).
    public mutating func reset() { states = [:] }

    // MARK: Steps

    /// Takes `planned` as-is (first manual target, or `bypass`). The state changes only
    /// when the target does, so an unchanged target keeps its dwell timer.
    private mutating func adopted(_ planned: Int, fan: Int, at time: Date) -> Int {
        guard let last = states[fan] else {
            states[fan] = State(rpm: planned, changedAt: time, direction: 0)
            return planned
        }
        if last.rpm != planned {
            states[fan] = State(rpm: planned, changedAt: time, direction: planned > last.rpm ? 1 : -1)
        }
        return planned
    }

    /// Applies the deadband, dwell and slew rules to `planned` against `last`.
    private mutating func limited(_ planned: Int, last: State, fan: Int, range: ClosedRange<Int>?,
                                  at time: Date, tuning: FanControlTuning) -> Int {
        let delta = planned - last.rpm
        let atBound = range.map { planned == $0.lowerBound || planned == $0.upperBound } ?? false
        if delta == 0 || (abs(delta) < tuning.deadbandRPM && !atBound) {
            states[fan]?.decreaseRequestedSince = nil
            return last.rpm
        }
        let direction = delta > 0 ? 1 : -1
        let requestedSince: Date? = direction < 0 ? (last.decreaseRequestedSince ?? time) : nil
        states[fan]?.decreaseRequestedSince = requestedSince
        let needsDwell = tuning.dwellAppliesToIncreases || direction < 0 || last.direction < 0
        if needsDwell, time.timeIntervalSince(last.changedAt) < tuning.minimumDwell {
            return last.rpm
        }
        if let requestedSince, time.timeIntervalSince(requestedSince) < tuning.minimumDwell {
            return last.rpm
        }
        let step = max(tuning.maximumStepRPM, 1)
        let rpm = last.rpm + min(max(delta, -step), step)
        states[fan] = State(rpm: rpm, changedAt: time, direction: direction, decreaseRequestedSince: requestedSince)
        return rpm
    }
}
