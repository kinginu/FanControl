#if os(macOS)
// Formatting helpers shared by the Fan Control views (settings pane, widgets, Live Activity):
// temperatures and RPMs, alert colours, sensor and profile names, curve and mode summaries.
// Labels go through the host's Localizable.strings (`Bundle.main`).

import Foundation
import SwiftUI
import FanControlCore
import FanControlKit

// MARK: - Formatting helpers shared by the Fan Control views

public enum FanControlFormatting {

    /// "61°C" / "142°F"; "--" for non-finite values. Unit symbols are not localized.
    public static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        guard celsius.isFinite else { return "--" }
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return "\(Int(value.rounded()))\(unitSymbol(unit))"
    }

    /// "61°C" for a reading.
    public static func temperature(_ reading: SensorReading, unit: TemperatureUnit) -> String {
        temperature(reading.temperature, unit: unit)
    }

    public static func unitSymbol(_ unit: TemperatureUnit) -> String {
        unit == .celsius ? "°C" : "°F"
    }

    /// "2,500" using the current locale's grouping; "--" when unknown.
    public static func rpm(_ rpm: Int?) -> String {
        guard let rpm else { return "--" }
        return rpm.formatted()
    }

    /// Whether `sensor` is shown in red: the same rule as the high-temperature
    /// alert (`AlertEvaluator.evaluateHighTemperature`), i.e. only CPU/GPU sensors
    /// (`policy.emergencySensorPrefixes`) at or above `policy.highTemperatureAlert`.
    /// An aggregate counts as CPU/GPU when one of its member prefixes is an
    /// emergency prefix (its value is then that of an emergency sensor).
    public static func isAlertTemperature(_ sensor: SensorReading, policy: SafetyPolicy) -> Bool {
        guard sensor.temperature.isFinite, sensor.temperature >= policy.highTemperatureAlert else { return false }
        return isAlertSensor(sensor, policy: policy)
    }

    /// How far below `policy.highTemperatureAlert` a CPU/GPU value turns orange.
    public static let warmTemperatureMargin: Double = 10

    /// Whether `sensor` is shown in orange: a CPU/GPU sensor (same rule as
    /// `isAlertTemperature`) within `warmTemperatureMargin` below the alert threshold.
    public static func isWarmTemperature(_ sensor: SensorReading, policy: SafetyPolicy) -> Bool {
        guard sensor.temperature.isFinite,
              sensor.temperature < policy.highTemperatureAlert,
              sensor.temperature >= policy.highTemperatureAlert - warmTemperatureMargin else { return false }
        return isAlertSensor(sensor, policy: policy)
    }

    /// CPU/GPU sensors (`policy.emergencySensorPrefixes`; an aggregate counts when one
    /// of its member prefixes is an emergency prefix).
    private static func isAlertSensor(_ sensor: SensorReading, policy: SafetyPolicy) -> Bool {
        if sensor.isAggregate {
            let members = FanControlPlatform.sensorAggregateDefinitions
                .first { $0.id == sensor.id }?.memberPrefixes ?? []
            return members.contains { policy.emergencySensorPrefixes.contains($0) }
        }
        return policy.emergencySensorPrefixes.contains { sensor.id.hasPrefix($0) }
    }

    /// Localized display name for any sensor (aggregates and catalog names alike;
    /// `FanControlSensorNames`).
    public static func sensorName(_ sensor: SensorReading) -> String {
        FanControlSensorNames.localized(sensor)
    }

    /// `readings` with the aggregates moved to the front (each part keeps its order).
    public static func aggregatesFirst(_ readings: [SensorReading]) -> [SensorReading] {
        readings.filter(\.isAggregate) + readings.filter { !$0.isAggregate }
    }

    /// `readings` with the keys excluded from ranking
    /// (`SensorCatalog.isExcludedFromRanking`, e.g. `Tf*`) moved to the end,
    /// order otherwise unchanged (stable). Used when sorting by temperature so
    /// constant / non-thermal values do not top the list.
    public static func rankableFirst(_ readings: [SensorReading]) -> [SensorReading] {
        readings.filter { !$0.isExcludedFromRanking } + readings.filter(\.isExcludedFromRanking)
    }

    // MARK: Curves

    /// The points of `curve` as text, e.g. "50°C min · 60°C 3,500 · 70°C 5,200 · 85°C max".
    /// With `rpmRange` (one fan) RPMs are clamped to it and its ends read "min" / "max";
    /// without, the fan-agnostic `FanCurve.fanMinimumRPM` / `fanMaximumRPM` do.
    public static func curvePointsSummary(_ curve: FanCurve, rpmRange: ClosedRange<Int>? = nil,
                                   unit: TemperatureUnit) -> String {
        let points = (rpmRange.map { curve.resolved(rpmRange: $0) } ?? curve.normalized()).points
        let low = rpmRange?.lowerBound ?? FanCurve.fanMinimumRPM
        let high = rpmRange?.upperBound ?? FanCurve.fanMaximumRPM
        return points.map { point in
            let rpm = point.rpm <= low ? String(localized: "min")
                : point.rpm >= high ? String(localized: "max")
                : point.rpm.formatted()
            return "\(temperature(point.temperature, unit: unit)) \(rpm)"
        }.joined(separator: " · ")
    }

    /// Localized display name for a profile. The seven fixed profiles show
    /// their localized default name ("Automatic", "Constant Quiet", …,
    /// "Custom 1"); a renamed custom slot shows the user's name verbatim.
    public static func profileName(_ profile: FanProfile) -> String {
        if let defaultName = FanProfile.defaultName(id: profile.id) {
            if profile.isCustomSlot && profile.name != defaultName { return profile.name }
            return NSLocalizedString(defaultName, comment: "Fixed fan profile name")
        }
        guard profile.isBuiltIn else { return profile.name }
        return NSLocalizedString(profile.name, comment: "Built-in fan profile name")
    }

    // MARK: Key temperatures

    /// Keys of the key temperatures, in display order: CPU (max), GPU (max)
    /// and the SSD (`TH0x`, "NAND (SSD)" on Apple Silicon).
    public static let keyTemperatureKeys = [SensorAggregator.ID.cpu, SensorAggregator.ID.gpu, "TH0x"]

    /// The key temperatures present in `readings` (finite values only), in
    /// `keyTemperatureKeys` order.
    public static func keyTemperatures(_ readings: [SensorReading]) -> [SensorReading] {
        keyTemperatureKeys.compactMap { key in
            readings.first { $0.id == key && $0.temperature.isFinite }
        }
    }

    /// Short label of a key temperature ("CPU" / "GPU" / "SSD"), else the sensor name.
    public static func keyTemperatureLabel(_ sensor: SensorReading) -> String {
        switch sensor.id {
        case SensorAggregator.ID.cpu: return String(localized: "CPU")
        case SensorAggregator.ID.gpu: return String(localized: "GPU")
        case "TH0x": return String(localized: "SSD")
        default: return sensorName(sensor)
        }
    }

    // MARK: Profile descriptions

    /// One-line summary of a mode, e.g. "3,000 RPM", "CPU (max) 50–80°C", "Automatic".
    public static func modeSummary(_ mode: FanControlMode, sensors: [SensorReading], unit: TemperatureUnit) -> String {
        switch mode {
        case .automatic:
            return String(localized: "Automatic")
        case .constant(let rpm):
            return "\(rpm.formatted()) RPM"
        case .sensor(let key, let start, let maxTemperature):
            let name = sensors.first { $0.id == key }.map(sensorName)
                ?? (key == SensorAggregator.ID.cpu ? NSLocalizedString("CPU (max)", comment: "Aggregate sensor name") : key)
            return "\(name) \(temperature(start, unit: unit))–\(temperature(maxTemperature, unit: unit))"
        }
    }
}

extension FanControlFormatting {
    /// Red at/above the high-temperature alert, orange within `warmTemperatureMargin`
    /// below it (CPU/GPU sensors only), else primary.
    public static func temperatureColor(_ sensor: SensorReading, policy: SafetyPolicy) -> Color {
        if isAlertTemperature(sensor, policy: policy) { return .red }
        if isWarmTemperature(sensor, policy: policy) { return .orange }
        return .primary
    }
}

// MARK: - Localized sensor names

/// Localized sensor names (design doc §5.7), built from
/// `SensorCatalog.nameComponents(for:)`: the label key ("CPU Performance Core",
/// "Battery", …, "Sensor" for unknown keys, or an aggregate name such as
/// "CPU (max)") goes through Localizable.strings, the suffix (rest of the SMC
/// key, sensor index or raw key) is appended verbatim, e.g. `Tp09` →
/// "CPU Performance Core 09". `SensorReading.name` / `SensorCatalog.displayName(for:)`
/// stay English (stored, legacy key).
public enum FanControlSensorNames {
    public static func localized(_ sensor: SensorReading) -> String {
        localized(key: sensor.id)
    }

    public static func localized(key: String) -> String {
        let components = SensorCatalog.nameComponents(for: key)
        return components.name(label: NSLocalizedString(components.labelKey, comment: "Sensor name label (SensorCatalog)"))
    }
}
#endif
