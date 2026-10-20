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
///
/// Multi-point curves (2026-10-20): a `.sensor` mode may carry a `FanCurve` in its
/// profile (`FanProfile.curves` / `defaultCurve`). The curve then replaces the linear
/// ramp, and `startTemperature` / `maxTemperature` are the curve's first / last
/// temperature (`FanProfile.curve(for:)`, `FanProfile.setCurve`). The enum keeps its
/// three cases so existing exhaustive `switch`es and `case .sensor(let key, _, _)`
/// patterns keep compiling (docs/kit.md "Fan curves").
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
/// The app offers a fixed set of seven profiles (`ProfileStore`, `FanProfile.fixedProfileIDs`):
/// Automatic, Constant Quiet, Constant High, Boost, Max (read-only presets) and
/// Custom 1 / Custom 2 (user-editable slots).
public struct FanProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Mode per fan, keyed by `FanDevice.id`. Fans without an entry use
    /// `defaultMode` (or `.automatic` when that is `nil`). An explicit
    /// `.automatic` entry overrides `defaultMode`.
    public var modes: [Int: FanControlMode]
    /// Built-in profiles cannot be deleted from a `ProfileStore`. `true` for
    /// the presets (Automatic, Constant Quiet, Constant High, Boost, Max) and the
    /// legacy Silent / Maximum; `false` for the Custom 1 / Custom 2 slots.
    public var isBuiltIn: Bool
    /// Mode for every fan that has no entry in `modes` ("every fan" presets,
    /// which are defined before the fans are known). `nil` = `.automatic`.
    ///
    /// `FanControlManager.applyProfile` opens the write session when `modes`
    /// or `defaultMode` holds a manual mode, so an unresolved preset works.
    /// Planning (`FanControlEngine.plan`) uses `mode(for:)` and therefore
    /// honours `defaultMode` as stored. UIs still pass `resolved(for:)` to show
    /// and store explicit per-fan modes.
    public var defaultMode: FanControlMode?
    /// Multi-point curves of the `.sensor` modes in `modes`, keyed by fan id. A curve
    /// applies only while its first / last temperature equal the mode's
    /// `startTemperature` / `maxTemperature` (`FanCurve.matches`); otherwise (the mode
    /// was edited by a curve-unaware editor) the mode's linear ramp is used.
    public var curves: [Int: FanCurve]
    /// Curve of `defaultMode` when that is `.sensor` (same matching rule); used by fans
    /// without a `modes` entry.
    public var defaultCurve: FanCurve?

    public init(id: UUID = UUID(), name: String, modes: [Int: FanControlMode] = [:], isBuiltIn: Bool = false,
                defaultMode: FanControlMode? = nil, curves: [Int: FanCurve] = [:], defaultCurve: FanCurve? = nil) {
        self.id = id
        self.name = name
        self.modes = modes
        self.isBuiltIn = isBuiltIn
        self.defaultMode = defaultMode
        self.curves = curves
        self.defaultCurve = defaultCurve
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modes, isBuiltIn, defaultMode, curves, defaultCurve
    }

    /// `curves` / `defaultCurve` are optional in the JSON (profiles stored before 2026-10-20).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        modes = try c.decodeIfPresent([Int: FanControlMode].self, forKey: .modes) ?? [:]
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        defaultMode = try c.decodeIfPresent(FanControlMode.self, forKey: .defaultMode)
        curves = try c.decodeIfPresent([Int: FanCurve].self, forKey: .curves) ?? [:]
        defaultCurve = try c.decodeIfPresent(FanCurve.self, forKey: .defaultCurve)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(modes, forKey: .modes)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encodeIfPresent(defaultMode, forKey: .defaultMode)
        if !curves.isEmpty { try c.encode(curves, forKey: .curves) }
        try c.encodeIfPresent(defaultCurve, forKey: .defaultCurve)
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
        /// Every fan at full speed (added 2026-10-20). Not the legacy `maximum`.
        public static let max = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000014")!
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
        /// Max: every fan at this RPM (the maximum of Mac14,9's fans; clamped to each
        /// fan's Mn…Mx when applied).
        public static let maxRPM = 6800
        /// Boost: sensor followed by every fan.
        public static let boostSensorKey = "agg:cpu"
        /// Boost: first point of `boostCurve` (fans at `minRPM` at or below it, °C).
        /// Also the default start of a new sensor-based mode in the editors.
        public static let boostStartTemperature = 50.0
        /// Boost: last point of `boostCurve` (fans at maximum at or above it, °C),
        /// 10 °C below the emergency threshold of `SafetyPolicy.default`.
        public static let boostMaxTemperature = 85.0
        /// Boost curve (user decision 2026-10-20, full speed well before 100 °C):
        /// 50 °C min, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800 (`FanCurve.boost`).
        public static var boostCurve: FanCurve { FanCurve.boost }
        /// Default of the Custom 2 slot: every fan at this RPM.
        public static let custom2RPM = 3500

        /// The Boost mode (`.sensor(agg:cpu, 50 → 85 °C)`; with `boostCurve` as the
        /// profile's `defaultCurve`).
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
        public static let max = "Max"
        public static let custom1 = "Custom 1"
        public static let custom2 = "Custom 2"
    }

    /// The seven profiles offered by the app, in display order.
    public static let fixedProfileIDs: [UUID] = [
        BuiltInID.automatic, BuiltInID.constantQuiet, BuiltInID.constantHigh, BuiltInID.boost,
        BuiltInID.max, BuiltInID.custom1, BuiltInID.custom2,
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

    /// Every fan follows `agg:cpu` on `Preset.boostCurve` (min at ≤ 50 °C … max at ≥ 85 °C).
    public static func boost() -> FanProfile {
        FanProfile(id: BuiltInID.boost, name: DefaultName.boost, isBuiltIn: true, defaultMode: Preset.boostMode,
                   defaultCurve: Preset.boostCurve)
    }

    /// Every fan at `Preset.maxRPM` (6800 RPM, clamped to each fan's range).
    public static func max() -> FanProfile {
        FanProfile(id: BuiltInID.max, name: DefaultName.max, isBuiltIn: true,
                   defaultMode: .constant(rpm: Preset.maxRPM))
    }

    /// Default content of the Custom 1 slot: a copy of Boost, curve included (editable).
    public static func defaultCustom1() -> FanProfile {
        FanProfile(id: BuiltInID.custom1, name: DefaultName.custom1, isBuiltIn: false, defaultMode: Preset.boostMode,
                   defaultCurve: Preset.boostCurve)
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
        case BuiltInID.max: return max()
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
    /// the fixed seven (kept for `FanControlManager.availableProfiles`).
    public static func silent(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.silent, name: "Silent",
                   modes: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant(rpm: $0.minRPM)) }),
                   isBuiltIn: true)
    }

    /// Legacy: every fan at a constant speed equal to its `maxRPM`. Not part of
    /// the fixed seven (kept for `FanControlManager.availableProfiles`; the
    /// preset with the same effect is `max()`).
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

    /// The stored curve for `fan` (its `curves` entry when it has a `modes` entry, else
    /// `defaultCurve`), whether or not it matches the mode.
    public func storedCurve(for fan: FanDevice) -> FanCurve? {
        modes[fan.id] != nil ? curves[fan.id] : defaultCurve
    }

    /// The curve that drives `fan`, or `nil` unless its mode is `.sensor`:
    /// the stored curve when it matches the mode's start / max temperatures, else the
    /// two-point linear curve of the mode (`FanCurve.linear`), or `nil` for a degenerate
    /// mode (`startTemperature >= maxTemperature` or non-finite: step / fail-loud rule of
    /// `FanControlEngine`).
    public func curve(for fan: FanDevice) -> FanCurve? {
        guard case .sensor(_, let start, let max) = mode(for: fan) else { return nil }
        if let stored = storedCurve(for: fan), stored.matches(startTemperature: start, maxTemperature: max) {
            return stored
        }
        guard start.isFinite, max.isFinite, start < max else { return nil }
        return .linear(startTemperature: start, maxTemperature: max)
    }

    /// Makes fan `fanID` (or, with `nil`, every fan without a `modes` entry) follow
    /// `sensorKey` on `curve`: sets the mode to `.sensor(sensorKey, first, last)` (the
    /// curve's normalized first / last temperatures) and stores the normalized curve.
    /// A curve with fewer than one point is ignored.
    public mutating func setCurve(_ curve: FanCurve, sensorKey: String, forFan fanID: Int?) {
        let normalized = curve.normalized()
        guard let first = normalized.points.first?.temperature, let last = normalized.points.last?.temperature
        else { return }
        let mode = FanControlMode.sensor(sensorKey: sensorKey, startTemperature: first, maxTemperature: last)
        if let fanID {
            modes[fanID] = mode
            curves[fanID] = normalized
        } else {
            defaultMode = mode
            defaultCurve = normalized
        }
    }

    /// Drops curves that do not drive a `.sensor` mode any more (mode changed, or its
    /// start / max no longer match the curve).
    public mutating func removeStaleCurves() {
        for (fan, curve) in curves {
            guard case .sensor(_, let start, let max)? = modes[fan],
                  curve.matches(startTemperature: start, maxTemperature: max) else {
                curves[fan] = nil
                continue
            }
        }
        if let defaultCurve {
            guard case .sensor(_, let start, let max)? = defaultMode,
                  defaultCurve.matches(startTemperature: start, maxTemperature: max) else {
                self.defaultCurve = nil
                return
            }
        }
    }

    /// A copy with an explicit `modes` entry for every fan in `fans`
    /// (`mode(for:)`; `.automatic` fans get no entry unless `defaultMode`
    /// is manual, in which case `.automatic` is stored explicitly).
    /// `defaultMode` is kept for fans not in `fans`. Each materialized fan also gets
    /// its stored curve (`storedCurve(for:)`) in `curves`. Pass this to
    /// `FanControlManager.applyProfile`, which opens the write session only
    /// when `modes` contains a manual mode.
    public func resolved(for fans: [FanDevice]) -> FanProfile {
        var copy = self
        for fan in fans {
            let mode = mode(for: fan)
            let curve = storedCurve(for: fan)
            if mode.isManual || (defaultMode?.isManual ?? false) {
                copy.modes[fan.id] = mode
                copy.curves[fan.id] = curve
            } else {
                copy.modes[fan.id] = nil
                copy.curves[fan.id] = nil
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
