import Foundation

/// How a single fan is driven.
///
/// `.sensor` is a sensor-based mode with two temperatures: the fan
/// runs at its own `minRPM` at or below `startTemperature`, at its own `maxRPM` at or
/// above `maxTemperature`, and scales linearly in between.
///
/// Multi-point curves: a `.sensor` mode may carry a `FanCurve` in its profile
/// (`FanProfile.curves` / `defaultCurve`). The curve then replaces the linear ramp, and
/// `startTemperature` / `maxTemperature` are the curve's first / last temperature
/// (`FanProfile.curve(for:)`, `FanProfile.setCurve`). The enum keeps its three cases so
/// that exhaustive `switch`es and `case .sensor(let key, _, _)` patterns keep compiling
/// (docs/kit.md "Fan curves").
public enum FanControlMode: Codable, Hashable, Sendable {
    /// The SMC controls the fan (no override).
    case automatic
    /// Fixed speed in RPM (clamped to the fan's range when applied).
    case constant(rpm: Int)
    /// Speed follows the temperature of the sensor with key `sensorKey`.
    case sensor(sensorKey: String, startTemperature: Double, maxTemperature: Double)

    /// `false` only for `.automatic`.
    public var isManual: Bool {
        if case .automatic = self { return false }
        return true
    }

    /// `true` for `.sensor`.
    var isSensorBased: Bool {
        if case .sensor = self { return true }
        return false
    }

    /// The two-point linear curve of a `.sensor` mode (`FanCurve.linear`), or `nil` for
    /// other modes and for a degenerate ramp (`startTemperature >= maxTemperature` or a
    /// non-finite temperature: the step / fail-loud rule of `FanControlEngine`).
    var linearCurve: FanCurve? {
        guard case .sensor(_, let start, let max) = self, start.isFinite, max.isFinite, start < max else {
            return nil
        }
        return .linear(startTemperature: start, maxTemperature: max)
    }
}
