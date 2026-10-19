import Foundation

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
    case smc, iokit, gpu, diskSMART, average, greatest, virtual
}

/// Unit used to present temperatures.
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

    /// The temperature converted to `unit`.
    public func temperature(in unit: TemperatureUnit) -> Double {
        switch unit {
        case .celsius: return temperature
        case .fahrenheit: return temperature * 9 / 5 + 32
        }
    }
}

// MARK: - Control modes and profiles

/// How a single fan is driven.
///
/// The design doc (§3.1) sketches `sensor(targetTemperature:minRPM:maxRPM:)`.
/// This implementation instead uses a
/// "sensor-based" mode, which uses two temperatures: the fan runs at its own
/// `minRPM` at or below `startTemperature`, at its own `maxRPM` at or above
/// `maxTemperature`, and scales linearly in between.
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
}

/// A named set of per-fan modes.
public struct FanProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Mode per fan, keyed by `FanDevice.id`. Missing fans are `.automatic`.
    public var modes: [Int: FanControlMode]
    /// Built-in profiles cannot be deleted from a `ProfileStore`.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, modes: [Int: FanControlMode] = [:], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.modes = modes
        self.isBuiltIn = isBuiltIn
    }

    /// Fixed identifiers of the built-in profiles, so they dedupe across launches.
    public enum BuiltInID {
        public static let automatic = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000001")!
        public static let silent = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000002")!
        public static let maximum = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000003")!
    }

    /// Every fan under SMC control.
    public static func automatic() -> FanProfile {
        FanProfile(id: BuiltInID.automatic, name: "Automatic", modes: [:], isBuiltIn: true)
    }

    /// Every fan at a constant speed equal to its `minRPM`.
    public static func silent(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.silent, name: "Silent",
                   modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant(rpm: $0.minRPM)) }),
                   isBuiltIn: true)
    }

    /// Every fan at a constant speed equal to its `maxRPM`.
    public static func maximum(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.maximum, name: "Maximum",
                   modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant(rpm: $0.maxRPM)) }),
                   isBuiltIn: true)
    }

    /// The mode configured for `fan`, defaulting to `.automatic`.
    public func mode(for fan: FanDevice) -> FanControlMode {
        modes[fan.id] ?? .automatic
    }
}

// MARK: - Snapshot

/// A point-in-time view of fans and sensors, suitable for the UI.
public struct FanControlSnapshot: Codable, Hashable, Sendable {
    public var fans: [FanDevice]
    /// Measured RPM per fan id.
    public var currentRPMs: [Int: Int]
    /// Target RPM per fan id.
    public var targetRPMs: [Int: Int]
    public var sensors: [SensorReading]
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

// MARK: - Errors

/// Errors raised across the fan-control stack.
public enum FanControlError: Error, Equatable, Sendable, LocalizedError {
    case smcUnavailable
    case keyNotFound(String)
    case invalidKey(String)
    case readFailed(key: String, code: Int32)
    case writeFailed(key: String, code: Int32)
    case helperNotInstalled
    case helperConnectionFailed(String)
    case helperRejected(code: Int, message: String)
    case sessionNotOpen
    case rpmOutOfRange(fan: Int, rpm: Int, allowed: ClosedRange<Int>)
    case unsupportedDataType(String)

    public var errorDescription: String? {
        switch self {
        case .smcUnavailable:
            return "The System Management Controller (SMC) is not available."
        case .keyNotFound(let key):
            return "SMC key \"\(key)\" was not found."
        case .invalidKey(let key):
            return "\"\(key)\" is not a valid SMC key."
        case .readFailed(let key, let code):
            return "Reading SMC key \"\(key)\" failed (code \(code))."
        case .writeFailed(let key, let code):
            return "Writing SMC key \"\(key)\" failed (code \(code))."
        case .helperNotInstalled:
            return "The fan control helper is not installed."
        case .helperConnectionFailed(let reason):
            return "Could not connect to the fan control helper: \(reason)"
        case .helperRejected(let code, let message):
            return "The fan control helper rejected the request (code \(code)): \(message)"
        case .sessionNotOpen:
            return "No fan control session is open."
        case .rpmOutOfRange(let fan, let rpm, let allowed):
            return "\(rpm) RPM is outside the allowed range \(allowed.lowerBound)-\(allowed.upperBound) RPM for fan \(fan)."
        case .unsupportedDataType(let type):
            return "Unsupported SMC data type \"\(type)\"."
        }
    }
}
