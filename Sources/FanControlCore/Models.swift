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
///
/// The app offers a fixed set of six profiles (`ProfileStore`, `FanProfile.fixedProfileIDs`):
/// Automatic, Constant Quiet, Constant High, Boost (read-only presets) and
/// Custom 1 / Custom 2 (user-editable slots).
public struct FanProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Mode per fan, keyed by `FanDevice.id`. Fans without an entry use
    /// `defaultMode` (or `.automatic` when that is `nil`). An explicit
    /// `.automatic` entry overrides `defaultMode`.
    public var modes: [Int: FanControlMode]
    /// Built-in profiles cannot be deleted from a `ProfileStore`. `true` for
    /// the presets (Automatic, Constant Quiet, Constant High, Boost) and the
    /// legacy Silent / Maximum; `false` for the Custom 1 / Custom 2 slots.
    public var isBuiltIn: Bool
    /// Mode for every fan that has no entry in `modes` ("every fan" presets,
    /// which are defined before the fans are known). `nil` = `.automatic`.
    ///
    /// Note: `FanControlManager.applyProfile` decides whether it needs the
    /// write session from `modes` alone, so pass `resolved(for:)` (explicit
    /// per-fan modes) to it. Planning (`FanControlEngine.plan`) uses
    /// `mode(for:)` and therefore honours `defaultMode` as stored.
    public var defaultMode: FanControlMode?

    public init(id: UUID = UUID(), name: String, modes: [Int: FanControlMode] = [:], isBuiltIn: Bool = false,
                defaultMode: FanControlMode? = nil) {
        self.id = id
        self.name = name
        self.modes = modes
        self.isBuiltIn = isBuiltIn
        self.defaultMode = defaultMode
    }

    /// Fixed identifiers of the built-in profiles and custom slots, so they
    /// dedupe across launches.
    public enum BuiltInID {
        public static let automatic = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000001")!
        /// Legacy (before the fixed six): every fan at its `minRPM`. No longer offered;
        /// migrated away by `ProfileStore` (kept because `FanControlManager` references it).
        public static let silent = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000002")!
        /// Legacy (before the fixed six): every fan at its `maxRPM`. No longer offered;
        /// the emergency override (`SafetyPolicy`) still forces max speed when hot.
        public static let maximum = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000003")!
        public static let constantQuiet = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000011")!
        public static let constantHigh = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000012")!
        public static let boost = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000013")!
        public static let custom1 = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000021")!
        public static let custom2 = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000022")!
    }

    /// Parameters of the presets and the custom-slot defaults (provisional
    /// values, to be confirmed by the user; see docs/kit.md "Profiles").
    public enum Preset {
        /// Constant Quiet: every fan at this RPM (clamped to Mn…Mx when applied).
        public static let quietRPM = 3000
        /// Constant High: every fan at this RPM (clamped to Mn…Mx when applied).
        public static let highRPM = 5000
        /// Boost: sensor followed by every fan.
        public static let boostSensorKey = "agg:cpu"
        /// Boost: fans at `minRPM` at or below this temperature (°C).
        /// `agg:cpu` is the *hottest* core, which idles at ~72–78 °C on Apple Silicon
        /// (Mac14,9), so the ramp starts at 70 °C: near minimum at idle, full speed well
        /// before the SMC would (provisional; docs/kit.md "Profiles").
        public static let boostStartTemperature = 70.0
        /// Boost: fans at `maxRPM` at or above this temperature (°C); equals the
        /// emergency force-max threshold of `SafetyPolicy.default`.
        public static let boostMaxTemperature = 95.0
        /// Default of the Custom 2 slot: every fan at this RPM.
        public static let custom2RPM = 3500

        /// The Boost mode (`.sensor(agg:cpu, 70 → 95 °C)`).
        public static var boostMode: FanControlMode {
            .sensor(sensorKey: boostSensorKey, startTemperature: boostStartTemperature,
                    maxTemperature: boostMaxTemperature)
        }
    }

    /// Default (English) names of the fixed profiles; the app localizes them
    /// (a custom slot whose name equals its default name is shown localized).
    public enum DefaultName {
        public static let automatic = "Automatic"
        public static let constantQuiet = "Constant Quiet"
        public static let constantHigh = "Constant High"
        public static let boost = "Boost"
        public static let custom1 = "Custom 1"
        public static let custom2 = "Custom 2"
    }

    /// The six profiles offered by the app, in display order.
    public static let fixedProfileIDs: [UUID] = [
        BuiltInID.automatic, BuiltInID.constantQuiet, BuiltInID.constantHigh, BuiltInID.boost,
        BuiltInID.custom1, BuiltInID.custom2,
    ]

    /// The user-editable slots (Custom 1, Custom 2).
    public static let customSlotIDs: [UUID] = [BuiltInID.custom1, BuiltInID.custom2]

    /// Every fan under SMC control.
    public static func automatic() -> FanProfile {
        FanProfile(id: BuiltInID.automatic, name: DefaultName.automatic, modes: [:], isBuiltIn: true)
    }

    /// Every fan at `Preset.quietRPM` (3000 RPM).
    public static func constantQuiet() -> FanProfile {
        FanProfile(id: BuiltInID.constantQuiet, name: DefaultName.constantQuiet, isBuiltIn: true,
                   defaultMode: .constant(rpm: Preset.quietRPM))
    }

    /// Every fan at `Preset.highRPM` (5000 RPM).
    public static func constantHigh() -> FanProfile {
        FanProfile(id: BuiltInID.constantHigh, name: DefaultName.constantHigh, isBuiltIn: true,
                   defaultMode: .constant(rpm: Preset.highRPM))
    }

    /// Every fan follows `agg:cpu`: `minRPM` at ≤ 50 °C, linear to `maxRPM` at ≥ 80 °C.
    public static func boost() -> FanProfile {
        FanProfile(id: BuiltInID.boost, name: DefaultName.boost, isBuiltIn: true, defaultMode: Preset.boostMode)
    }

    /// Default content of the Custom 1 slot: a copy of Boost (editable).
    public static func defaultCustom1() -> FanProfile {
        FanProfile(id: BuiltInID.custom1, name: DefaultName.custom1, isBuiltIn: false, defaultMode: Preset.boostMode)
    }

    /// Default content of the Custom 2 slot: every fan at `Preset.custom2RPM` (3500 RPM).
    public static func defaultCustom2() -> FanProfile {
        FanProfile(id: BuiltInID.custom2, name: DefaultName.custom2, isBuiltIn: false,
                   defaultMode: .constant(rpm: Preset.custom2RPM))
    }

    /// The factory content of fixed profile `id` (preset or custom-slot
    /// default), or `nil` if `id` is not one of `fixedProfileIDs`.
    public static func fixedDefault(id: UUID) -> FanProfile? {
        switch id {
        case BuiltInID.automatic: return automatic()
        case BuiltInID.constantQuiet: return constantQuiet()
        case BuiltInID.constantHigh: return constantHigh()
        case BuiltInID.boost: return boost()
        case BuiltInID.custom1: return defaultCustom1()
        case BuiltInID.custom2: return defaultCustom2()
        default: return nil
        }
    }

    /// The default (English) name of fixed profile `id`.
    public static func defaultName(id: UUID) -> String? { fixedDefault(id: id)?.name }

    /// `true` for the Custom 1 / Custom 2 slots.
    public var isCustomSlot: Bool { Self.customSlotIDs.contains(id) }

    /// Legacy: every fan at a constant speed equal to its `minRPM`. Not part of
    /// the fixed six (kept for `FanControlManager.availableProfiles`).
    public static func silent(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.silent, name: "Silent",
                   modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant(rpm: $0.minRPM)) }),
                   isBuiltIn: true)
    }

    /// Legacy: every fan at a constant speed equal to its `maxRPM`. Not part of
    /// the fixed six (kept for `FanControlManager.availableProfiles`).
    public static func maximum(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.maximum, name: "Maximum",
                   modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant(rpm: $0.maxRPM)) }),
                   isBuiltIn: true)
    }

    /// The mode configured for `fan`: its `modes` entry, else `defaultMode`,
    /// else `.automatic`.
    public func mode(for fan: FanDevice) -> FanControlMode {
        modes[fan.id] ?? defaultMode ?? .automatic
    }

    /// A copy with an explicit `modes` entry for every fan in `fans`
    /// (`mode(for:)`; `.automatic` fans get no entry unless `defaultMode`
    /// is manual, in which case `.automatic` is stored explicitly).
    /// `defaultMode` is kept for fans not in `fans`. Pass this to
    /// `FanControlManager.applyProfile`, which opens the write session only
    /// when `modes` contains a manual mode.
    public func resolved(for fans: [FanDevice]) -> FanProfile {
        var copy = self
        for fan in fans {
            let mode = mode(for: fan)
            if mode.isManual || (defaultMode?.isManual ?? false) {
                copy.modes[fan.id] = mode
            } else {
                copy.modes[fan.id] = nil
            }
        }
        return copy
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
    /// The helper refuses this app's connections (code-signing requirement mismatch,
    /// e.g. a manual install pinned to another build of the app). Sticky until the
    /// user retries (`FanControlManager.retryHelperConnection()`) or reinstalls.
    case helperConnectionRejected(String)
    case sessionNotOpen
    case rpmOutOfRange(fan: Int, rpm: Int, allowed: ClosedRange<Int>)
    case unsupportedDataType(String)
    /// The host is not an Apple Silicon Mac (Intel support dropped 2026-10-20).
    /// The associated value describes the detected hardware.
    case unsupportedPlatform(String)
    /// Fan `fan` has `F<n>Tg` but no `F<n>Md` mode key, so it cannot be put into
    /// manual mode with the (only supported) Apple Silicon write scheme.
    case fanModeKeyMissing(fan: Int)

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
        case .helperConnectionRejected(let reason):
            return "The fan control helper refuses this app: \(reason)"
        case .sessionNotOpen:
            return "No fan control session is open."
        case .rpmOutOfRange(let fan, let rpm, let allowed):
            return "\(rpm) RPM is outside the allowed range \(allowed.lowerBound)-\(allowed.upperBound) RPM for fan \(fan)."
        case .unsupportedDataType(let type):
            return "Unsupported SMC data type \"\(type)\"."
        case .unsupportedPlatform(let detail):
            return "Fan control requires a Mac with Apple silicon (\(detail))."
        case .fanModeKeyMissing(let fan):
            return "Fan \(fan) has no SMC mode key \"F\(fan)Md\" and cannot be controlled on this Mac."
        }
    }
}
