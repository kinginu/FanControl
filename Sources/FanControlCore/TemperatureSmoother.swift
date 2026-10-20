import Foundation

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
