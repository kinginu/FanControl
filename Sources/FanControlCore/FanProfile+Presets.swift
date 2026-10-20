import Foundation

// Built-in profiles: fixed identifiers, preset parameters, default names and factories.

extension FanProfile {
    /// Fixed identifiers of the built-in profiles and custom slots, so they
    /// dedupe across launches.
    public enum BuiltInID {
        /// Automatic (every fan under SMC control).
        public static let automatic = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000001")!
        /// Legacy (before the fixed set): every fan at its `minRPM`. No longer offered;
        /// migrated away by `ProfileStore` (kept because `FanControlManager` references it).
        public static let silent = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000002")!
        /// Legacy (before the fixed set): every fan at its `maxRPM`. No longer offered;
        /// the emergency override (`SafetyPolicy`) still forces max speed when hot.
        public static let maximum = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000003")!
        /// Constant Quiet (`Preset.quietRPM`).
        public static let constantQuiet = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000011")!
        /// Constant High (`Preset.highRPM`).
        public static let constantHigh = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000012")!
        /// Boost (`Preset.boostMode` on `Preset.boostCurve`).
        public static let boost = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000013")!
        /// Max: every fan at full speed (`Preset.maxRPM`). Not the legacy `maximum`.
        public static let max = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000014")!
        /// The first user-editable slot.
        public static let custom1 = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000021")!
        /// The second user-editable slot.
        public static let custom2 = UUID(uuidString: "6F1A0000-0000-4000-8000-000000000022")!
    }

    /// Parameters of the presets and the custom-slot defaults (provisional values;
    /// docs/kit.md "Profiles").
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
        /// Boost curve (full speed well before 100 °C): 50 °C min, 60 °C 3500,
        /// 70 °C 5200, 80 °C 6400, 85 °C 6800 (`FanCurve.boost`).
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

    // MARK: Legacy built-ins

    /// Legacy: every fan at a constant speed equal to its `minRPM`. Not part of
    /// the fixed seven (kept for `FanControlManager.availableProfiles`).
    public static func silent(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.silent, name: "Silent",
                   modes: everyFan(fans) { .constant(rpm: $0.minRPM) },
                   isBuiltIn: true)
    }

    /// Legacy: every fan at a constant speed equal to its `maxRPM`. Not part of
    /// the fixed seven (kept for `FanControlManager.availableProfiles`; the
    /// preset with the same effect is `max()`).
    public static func maximum(for fans: [FanDevice]) -> FanProfile {
        FanProfile(id: BuiltInID.maximum, name: "Maximum",
                   modes: everyFan(fans) { .constant(rpm: $0.maxRPM) },
                   isBuiltIn: true)
    }

    /// `mode(fan)` keyed by fan id (the first fan wins on a duplicate id).
    private static func everyFan(_ fans: [FanDevice], _ mode: (FanDevice) -> FanControlMode) -> [Int: FanControlMode] {
        Dictionary(fans.map { ($0.id, mode($0)) }, uniquingKeysWith: { first, _ in first })
    }
}
