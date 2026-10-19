import Foundation

/// Safety thresholds applied on top of the user's profile.
public struct SafetyPolicy: Codable, Hashable, Sendable {
    /// If the hottest emergency sensor reaches this temperature (°C), every fan
    /// is forced to its maximum speed regardless of profile.
    public var emergencyTemperature: Double = 95
    /// Key prefixes of sensors considered for the emergency override and the
    /// high-temperature alert (CPU/GPU sensors on Intel and Apple Silicon).
    public var emergencySensorPrefixes: [String] = ["Tp", "Te", "TC", "Tg", "TG"]
    /// Temperature (°C) at which the high-temperature alert turns on.
    public var highTemperatureAlert: Double = 90
    /// The alert turns off again at `highTemperatureAlert - alertHysteresis`.
    public var alertHysteresis: Double = 5
    /// When `true`, constant speeds are never set below the fan's hardware
    /// minimum. When `false`, constant speeds may go down to 0 RPM.
    ///
    /// This is only a client-side planning preference. FanControlHelper is the
    /// safety authority: it rejects any `F<n>Tg` / `F<n>Mn` write outside the
    /// fan's hardware `F<n>Mn...F<n>Mx` range regardless of this setting, so
    /// sub-minimum targets planned with `false` will fail at the helper.
    public var enforceHardwareMinimum: Bool = true

    public init(emergencyTemperature: Double = 95,
                emergencySensorPrefixes: [String] = ["Tp", "Te", "TC", "Tg", "TG"],
                highTemperatureAlert: Double = 90,
                alertHysteresis: Double = 5,
                enforceHardwareMinimum: Bool = true) {
        self.emergencyTemperature = emergencyTemperature
        self.emergencySensorPrefixes = emergencySensorPrefixes
        self.highTemperatureAlert = highTemperatureAlert
        self.alertHysteresis = alertHysteresis
        self.enforceHardwareMinimum = enforceHardwareMinimum
    }

    /// The default policy. Its `emergencySensorPrefixes` is the
    /// architecture-neutral list `["Tp", "Te", "TC", "Tg", "TG"]` (kept for
    /// compatibility). Prefer `default(appleSilicon:)`, which drops prefixes
    /// whose meaning differs between architectures.
    public static let `default` = SafetyPolicy()

    /// Emergency/alert sensor prefixes for the given CPU architecture.
    ///
    /// - Intel (`appleSilicon == false`): `["Tp", "Te", "TC", "Tg", "TG"]`
    ///   (the list of `SafetyPolicy.default`). `TC*` = CPU, `TG0P`/`TG0D` = GPU;
    ///   `Tp`/`Te`/`Tg` normally do not exist on Intel and are harmless.
    /// - Apple Silicon: `["Tp", "Te", "TC", "Tg"]`. `TG*` is excluded: on
    ///   Mac14,9 (M2 Pro) / macOS 26 the `TG*` keys (`TG0B`, `TG0C`, `TG0H`,
    ///   `TG0V`, `TG1B`, `TG2B`, type `ioft`) read ~33 °C, tracking the battery
    ///   sensor `TB0T`, while the GPU is `Tg*` (`flt `). Excluding them only
    ///   removes battery-area sensors from the CPU/GPU emergency maximum.
    ///   `TC*` stays (`TCMz` tracks the hottest P core on Mac14,9).
    public static func defaultEmergencySensorPrefixes(appleSilicon: Bool) -> [String] {
        appleSilicon ? ["Tp", "Te", "TC", "Tg"] : ["Tp", "Te", "TC", "Tg", "TG"]
    }

    /// `SafetyPolicy.default` with `emergencySensorPrefixes` set to
    /// `defaultEmergencySensorPrefixes(appleSilicon:)`. Every other threshold
    /// is the same as `default`.
    public static func `default`(appleSilicon: Bool) -> SafetyPolicy {
        SafetyPolicy(emergencySensorPrefixes: defaultEmergencySensorPrefixes(appleSilicon: appleSilicon))
    }
}

/// Pure, stateless fan-speed calculations.
public enum FanControlEngine {

    /// Clamps `rpm` into the fan's `minRPM...maxRPM` range.
    public static func clamp(_ rpm: Int, to fan: FanDevice) -> Int {
        min(max(rpm, fan.rpmRange.lowerBound), fan.rpmRange.upperBound)
    }

    /// The target speed for `fan` under `mode`, or `nil` for `.automatic`.
    ///
    /// - `.constant`: the RPM clamped to the fan's range.
    /// - `.sensor`: `minRPM` at or below `startTemperature`, `maxRPM` at or above
    ///   `maxTemperature`, linear in between (rounded). If
    ///   `startTemperature >= maxTemperature` it is a step function:
    ///   `maxRPM` at or above `maxTemperature`, else `minRPM`.
    ///   If `sensorTemperature` is `nil` (sensor missing or unreadable) the fan
    ///   runs at `maxRPM`: fail hot = fail loud, never silently under-cool.
    public static func targetRPM(for mode: FanControlMode, fan: FanDevice, sensorTemperature: Double?) -> Int? {
        targetRPM(for: mode, fan: fan, sensorTemperature: sensorTemperature, enforceHardwareMinimum: true)
    }

    /// The hottest sensor whose key starts with one of `policy.emergencySensorPrefixes`.
    public static func hottestEmergencySensor(_ sensors: [SensorReading], policy: SafetyPolicy) -> SensorReading? {
        sensors
            .filter { sensor in
                sensor.temperature.isFinite
                    && policy.emergencySensorPrefixes.contains { sensor.id.hasPrefix($0) }
            }
            .max { $0.temperature < $1.temperature }
    }

    /// Computes the target RPM for every fan (`nil` value = leave in automatic).
    ///
    /// Emergency override: every fan (including automatic ones) is set to its
    /// `maxRPM` while the emergency is active.
    ///
    /// - `isEmergency == nil`: stateless check; the emergency is active if
    ///   `hottestEmergencySensor` is at or above `policy.emergencyTemperature`.
    /// - `isEmergency != nil`: the caller's latched state is used as-is (pass
    ///   `AlertEvaluator.evaluateEmergency(sensors:policy:)` to get hysteresis).
    public static func plan(profile: FanProfile, fans: [FanDevice], sensors: [SensorReading],
                            policy: SafetyPolicy, isEmergency: Bool? = nil) -> [Int: Int?] {
        var result: [Int: Int?] = [:]
        let emergency: Bool
        if let isEmergency {
            emergency = isEmergency
        } else if let hottest = hottestEmergencySensor(sensors, policy: policy) {
            emergency = hottest.temperature >= policy.emergencyTemperature
        } else {
            emergency = false
        }
        if emergency {
            for fan in fans { result.updateValue(fan.rpmRange.upperBound, forKey: fan.id) }
            return result
        }
        for fan in fans {
            let mode = profile.mode(for: fan)
            var temperature: Double?
            if case .sensor(let key, _, _) = mode {
                temperature = sensors.first { $0.id == key && $0.temperature.isFinite }?.temperature
            }
            let target = targetRPM(for: mode, fan: fan, sensorTemperature: temperature,
                                   enforceHardwareMinimum: policy.enforceHardwareMinimum)
            result.updateValue(target, forKey: fan.id)
        }
        return result
    }

    static func targetRPM(for mode: FanControlMode, fan: FanDevice, sensorTemperature: Double?,
                          enforceHardwareMinimum: Bool) -> Int? {
        let range = fan.rpmRange
        switch mode {
        case .automatic:
            return nil
        case .constant(let rpm):
            let lower = enforceHardwareMinimum ? range.lowerBound : 0
            return min(max(rpm, lower), range.upperBound)
        case .sensor(_, let start, let maxTemp):
            // Fail hot = fail loud: NaN/inf thresholds or readings run the fan at max.
            guard start.isFinite, maxTemp.isFinite, (sensorTemperature ?? 0).isFinite else {
                return range.upperBound
            }
            guard let temperature = sensorTemperature, temperature.isFinite else {
                return range.upperBound
            }
            if start >= maxTemp {
                return temperature >= maxTemp ? range.upperBound : range.lowerBound
            }
            let fraction = min(max((temperature - start) / (maxTemp - start), 0), 1)
            let span = Double(range.upperBound - range.lowerBound)
            return clamp(range.lowerBound + Int((fraction * span).rounded()), to: fan)
        }
    }
}

/// Stateful alert evaluation (hysteresis and consecutive-sample counting).
public struct AlertEvaluator: Sendable {
    /// Whether the high-temperature alert is currently active.
    public private(set) var isHighTemperatureActive = false
    /// Whether the emergency (all fans to max) latch is currently active.
    public private(set) var isEmergencyActive = false
    /// Consecutive anomalous samples per fan id.
    public private(set) var anomalyCounts: [Int: Int] = [:]

    public init() {}

    /// Updates and returns the high-temperature alert state, based on the
    /// hottest emergency sensor (`FanControlEngine.hottestEmergencySensor`).
    /// Turns on at `>= policy.highTemperatureAlert`, off at
    /// `<= policy.highTemperatureAlert - policy.alertHysteresis`; in between, or
    /// when no relevant sensor is present, the previous state is kept.
    public mutating func evaluateHighTemperature(sensors: [SensorReading], policy: SafetyPolicy) -> Bool {
        guard let hottest = FanControlEngine.hottestEmergencySensor(sensors, policy: policy) else {
            return isHighTemperatureActive
        }
        if hottest.temperature >= policy.highTemperatureAlert {
            isHighTemperatureActive = true
        } else if hottest.temperature <= policy.highTemperatureAlert - policy.alertHysteresis {
            isHighTemperatureActive = false
        }
        return isHighTemperatureActive
    }

    /// Updates and returns the emergency latch, based on the hottest emergency
    /// sensor. Turns on at `>= policy.emergencyTemperature`, off at
    /// `<= policy.emergencyTemperature - policy.alertHysteresis`; in between, or
    /// when no relevant sensor is present, the previous state is kept.
    /// Pass the result to `FanControlEngine.plan(...isEmergency:)`.
    public mutating func evaluateEmergency(sensors: [SensorReading], policy: SafetyPolicy) -> Bool {
        guard let hottest = FanControlEngine.hottestEmergencySensor(sensors, policy: policy) else {
            return isEmergencyActive
        }
        if hottest.temperature >= policy.emergencyTemperature {
            isEmergencyActive = true
        } else if hottest.temperature <= policy.emergencyTemperature - policy.alertHysteresis {
            isEmergencyActive = false
        }
        return isEmergencyActive
    }

    /// Returns ids of fans that reported 0 RPM while their target was > 0 for
    /// at least `consecutiveLimit` consecutive calls. Any other sample
    /// (including a missing reading) resets that fan's counter.
    public mutating func evaluateFanAnomaly(fans: [FanDevice], currentRPMs: [Int: Int], targetRPMs: [Int: Int],
                                            consecutiveLimit: Int = 3) -> Set<Int> {
        var anomalous = Set<Int>()
        var counts: [Int: Int] = [:]
        for fan in fans {
            if currentRPMs[fan.id] == 0, let target = targetRPMs[fan.id], target > 0 {
                let count = (anomalyCounts[fan.id] ?? 0) + 1
                counts[fan.id] = count
                if count >= consecutiveLimit { anomalous.insert(fan.id) }
            }
        }
        anomalyCounts = counts
        return anomalous
    }
}
