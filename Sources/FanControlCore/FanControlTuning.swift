import Foundation

/// Anti-hunting parameters of the control loop (docs/kit.md "Control loop"):
///
/// filter (`TemperatureSampleFilter`) → aggregate (`SensorAggregator`) →
/// **smoothing** (`TemperatureSmoother`) → curve (`FanControlEngine.plan`) →
/// **deadband / dwell / slew** (`FanTargetStabilizer`) → write.
///
/// Emergency override, restore and explicit user applies bypass the output stage.
public struct FanControlTuning: Codable, Hashable, Sendable {
    /// Time constant (s) of the exponential smoothing while the temperature rises. Default 3.
    public var riseTimeConstant: TimeInterval
    /// Time constant (s) while the temperature falls. Default 25: the fans slow down
    /// only after the load has really gone.
    public var fallTimeConstant: TimeInterval
    /// A poll does not rewrite a target that differs by less than this many RPM from the
    /// last stabilized one (planned targets at the fan's minimum or maximum are always
    /// reached). Default 150.
    public var deadbandRPM: Int
    /// Dwell (s), default 10. A target is kept at least this long after its last change
    /// before it may decrease or reverse direction, and a decrease is made only after the
    /// lower target has been planned (beyond the deadband) on every poll for this long:
    /// a momentary dip of the control temperature does not slow the fans.
    public var minimumDwell: TimeInterval
    /// `false` (default): consecutive *increases* are exempt from `minimumDwell` (still
    /// slew-limited), so a heating CPU gets more air every poll; only decreases and
    /// reversals wait. `true`: every change waits `minimumDwell`.
    public var dwellAppliesToIncreases: Bool
    /// Largest change of a target per poll (RPM). Default 500.
    public var maximumStepRPM: Int

    public init(riseTimeConstant: TimeInterval = 3, fallTimeConstant: TimeInterval = 25,
                deadbandRPM: Int = 150, minimumDwell: TimeInterval = 10,
                dwellAppliesToIncreases: Bool = false, maximumStepRPM: Int = 500) {
        self.riseTimeConstant = riseTimeConstant
        self.fallTimeConstant = fallTimeConstant
        self.deadbandRPM = deadbandRPM
        self.minimumDwell = minimumDwell
        self.dwellAppliesToIncreases = dwellAppliesToIncreases
        self.maximumStepRPM = maximumStepRPM
    }

    /// 3 s rise / 25 s fall, 150 RPM deadband, 10 s dwell (decreases and reversals),
    /// 500 RPM per poll.
    public static let `default` = FanControlTuning()

    /// No smoothing and no output stabilization (the behaviour before 2026-10-20:
    /// every poll writes the raw curve value).
    public static let disabled = FanControlTuning(riseTimeConstant: 0, fallTimeConstant: 0, deadbandRPM: 0,
                                                  minimumDwell: 0, dwellAppliesToIncreases: false,
                                                  maximumStepRPM: Int.max)

    /// Missing keys decode to the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanControlTuning.default
        riseTimeConstant = try c.decodeIfPresent(TimeInterval.self, forKey: .riseTimeConstant) ?? d.riseTimeConstant
        fallTimeConstant = try c.decodeIfPresent(TimeInterval.self, forKey: .fallTimeConstant) ?? d.fallTimeConstant
        deadbandRPM = try c.decodeIfPresent(Int.self, forKey: .deadbandRPM) ?? d.deadbandRPM
        minimumDwell = try c.decodeIfPresent(TimeInterval.self, forKey: .minimumDwell) ?? d.minimumDwell
        dwellAppliesToIncreases = try c.decodeIfPresent(Bool.self, forKey: .dwellAppliesToIncreases)
            ?? d.dwellAppliesToIncreases
        maximumStepRPM = try c.decodeIfPresent(Int.self, forKey: .maximumStepRPM) ?? d.maximumStepRPM
    }

    private enum CodingKeys: String, CodingKey {
        case riseTimeConstant, fallTimeConstant, deadbandRPM, minimumDwell, dwellAppliesToIncreases, maximumStepRPM
    }
}

// MARK: - Input smoothing

/// Asymmetric exponential smoothing of control temperatures, per sensor key.
///
/// For a sample `x` at time `t` after the previous one (`dt`), with the smoothed value `y`:
/// `y += (1 - exp(-dt / τ)) · (x - y)`, `τ = riseTimeConstant` if `x > y`, else
/// `fallTimeConstant` (τ ≤ 0 → no smoothing). The first sample of a key (or one after the
/// clock went backwards) is taken as-is. Non-finite samples are ignored (the key keeps
/// its state; `FanControlEngine` treats the missing reading as "run at maximum").
public struct TemperatureSmoother: Sendable {
    private struct State: Sendable {
        var value: Double
        var time: Date
    }

    private var states: [String: State] = [:]

    public init() {}

    /// The current smoothed value of `key`, if it has one.
    public func value(for key: String) -> Double? { states[key]?.value }

    /// Every key's smoothed value.
    public var values: [String: Double] { states.mapValues(\.value) }

    /// Feeds one sample of `key` and returns the smoothed value (`nil` for a non-finite
    /// sample of a key without state).
    @discardableResult
    public mutating func update(key: String, temperature: Double, at time: Date,
                                tuning: FanControlTuning) -> Double? {
        guard temperature.isFinite else { return states[key]?.value }
        guard let previous = states[key], time >= previous.time else {
            states[key] = State(value: temperature, time: time)
            return temperature
        }
        let dt = time.timeIntervalSince(previous.time)
        let tau = temperature > previous.value ? tuning.riseTimeConstant : tuning.fallTimeConstant
        let alpha = tau > 0 ? 1 - exp(-dt / tau) : 1
        let value = previous.value + alpha * (temperature - previous.value)
        states[key] = State(value: value, time: time)
        return value
    }

    /// Smooths the readings whose id is in `keys` (the other readings are returned
    /// unchanged) and forgets the state of every key not in `keys`, so a key that comes
    /// back into use starts from its raw value. Returns the readings to plan with.
    public mutating func smooth(_ sensors: [SensorReading], keys: Set<String>, at time: Date,
                                tuning: FanControlTuning) -> [SensorReading] {
        states = states.filter { keys.contains($0.key) }
        guard !keys.isEmpty else { return sensors }
        return sensors.map { reading in
            guard keys.contains(reading.id), reading.temperature.isFinite,
                  let smoothed = update(key: reading.id, temperature: reading.temperature, at: time, tuning: tuning)
            else { return reading }
            var copy = reading
            copy.temperature = smoothed
            return copy
        }
    }

    /// Forgets every key.
    public mutating func reset() { states = [:] }
}

// MARK: - Output stabilization

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
    public struct State: Hashable, Sendable {
        public var rpm: Int
        public var changedAt: Date
        /// Sign of the last change (+1 up, -1 down, 0 none / seeded).
        public var direction: Int
        /// Since when every poll has planned a decrease beyond the deadband.
        public var decreaseRequestedSince: Date?
    }

    public private(set) var states: [Int: State] = [:]

    public init() {}

    /// Stabilizes `plan` (fan id → planned RPM or `nil` = automatic) at `time`.
    /// `fans` provides each fan's range (targets at its bounds bypass the deadband).
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
            guard !bypass, let last = states[fan] else {
                let direction = states[fan].map { planned == $0.rpm ? $0.direction : (planned > $0.rpm ? 1 : -1) } ?? 0
                if states[fan]?.rpm != planned {
                    states[fan] = State(rpm: planned, changedAt: time, direction: direction)
                }
                result.updateValue(planned, forKey: fan)
                continue
            }
            let delta = planned - last.rpm
            let atBound = ranges[fan].map { planned == $0.lowerBound || planned == $0.upperBound } ?? false
            if delta == 0 || (abs(delta) < tuning.deadbandRPM && !atBound) {
                states[fan]?.decreaseRequestedSince = nil
                result.updateValue(last.rpm, forKey: fan)
                continue
            }
            let direction = delta > 0 ? 1 : -1
            var requestedSince: Date?
            if direction < 0 {
                requestedSince = last.decreaseRequestedSince ?? time
                states[fan]?.decreaseRequestedSince = requestedSince
            } else {
                states[fan]?.decreaseRequestedSince = nil
            }
            let needsDwell = tuning.dwellAppliesToIncreases || direction < 0 || last.direction < 0
            if needsDwell, time.timeIntervalSince(last.changedAt) < tuning.minimumDwell {
                result.updateValue(last.rpm, forKey: fan)
                continue
            }
            if let requestedSince, time.timeIntervalSince(requestedSince) < tuning.minimumDwell {
                result.updateValue(last.rpm, forKey: fan)
                continue
            }
            let step = max(tuning.maximumStepRPM, 1)
            let rpm = last.rpm + min(max(delta, -step), step)
            states[fan] = State(rpm: rpm, changedAt: time, direction: direction,
                                decreaseRequestedSince: requestedSince)
            result.updateValue(rpm, forKey: fan)
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
}
