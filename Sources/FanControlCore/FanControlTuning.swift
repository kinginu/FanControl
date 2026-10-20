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

    /// No smoothing and no output stabilization: every poll writes the raw curve value.
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
