import Foundation

// Value types shared by every layer: fans, temperature readings and the UI snapshot.
// Control modes and profiles: FanControlMode.swift, FanProfile*.swift. Errors:
// FanControlError.swift.

// MARK: - Fans

/// A physical fan discovered through the SMC.
public struct FanDevice: Identifiable, Codable, Hashable, Sendable {
    /// SMC fan index (the `i` in `F<i>Ac`).
    public let id: Int
    /// Display name (from `F<i>ID` when available, else "Fan N").
    public var name: String
    /// Hardware minimum speed in RPM (`F<i>Mn`).
    public var minRPM: Int
    /// Hardware maximum speed in RPM (`F<i>Mx`).
    public var maxRPM: Int

    public init(id: Int, name: String, minRPM: Int, maxRPM: Int) {
        self.id = id
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// The allowed RPM range (`minRPM...maxRPM`, normalised if inverted).
    public var rpmRange: ClosedRange<Int> {
        Swift.min(minRPM, maxRPM)...Swift.max(minRPM, maxRPM)
    }
}

// MARK: - Sensors

/// Origin of a temperature reading.
public enum SensorType: String, Codable, Sendable, CaseIterable {
    /// An SMC temperature key (`T…`).
    case smc
    /// An IOKit / HID temperature service.
    case iokit
    /// A GPU-reported temperature.
    case gpu
    /// A disk's S.M.A.R.T. temperature.
    case diskSMART
    /// The mean of several sensors.
    case average
    /// The maximum of several sensors (e.g. the `agg:*` aggregates of `SensorAggregator`).
    case greatest
    /// Any other synthesized value.
    case virtual
}

/// Unit used to present temperatures (values are always stored in °C).
public enum TemperatureUnit: String, Codable, Sendable, CaseIterable {
    case celsius, fahrenheit
}

/// A single temperature sample.
public struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    /// SMC key name (e.g. `"TC0P"`), or another stable identifier for non-SMC sensors.
    public let id: String
    /// Display name.
    public var name: String
    /// Temperature in degrees Celsius.
    public var temperature: Double
    /// Where the reading came from.
    public var sensorType: SensorType

    public init(id: String, name: String, temperature: Double, sensorType: SensorType = .smc) {
        self.id = id
        self.name = name
        self.temperature = temperature
        self.sensorType = sensorType
    }

    /// The temperature converted to `unit` (`TemperatureUnitConversion.displayValue`).
    public func temperature(in unit: TemperatureUnit) -> Double {
        TemperatureUnitConversion.displayValue(celsius: temperature, kind: .absolute, unit: unit)
    }
}

// MARK: - Snapshot

/// A point-in-time view of fans and sensors, suitable for the UI.
public struct FanControlSnapshot: Codable, Hashable, Sendable {
    /// The discovered fans.
    public var fans: [FanDevice]
    /// Measured RPM per fan id.
    public var currentRPMs: [Int: Int]
    /// Target RPM per fan id.
    public var targetRPMs: [Int: Int]
    /// Temperature readings (°C).
    public var sensors: [SensorReading]
    /// When the values were read.
    public var timestamp: Date

    public init(fans: [FanDevice] = [], currentRPMs: [Int: Int] = [:], targetRPMs: [Int: Int] = [:],
                sensors: [SensorReading] = [], timestamp: Date = Date()) {
        self.fans = fans
        self.currentRPMs = currentRPMs
        self.targetRPMs = targetRPMs
        self.sensors = sensors
        self.timestamp = timestamp
    }
}
