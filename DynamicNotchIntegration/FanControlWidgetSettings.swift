#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// Settings models for the Fan Control Nook widget and the Fan Control
// settings pane, persisted with sindresorhus/Defaults (design doc §4.1, §4.3).
//
// Decoding is tolerant (`decodeIfPresent` with defaults) so that adding a
// field in a later version never resets the user's stored settings.

import Foundation
import Defaults
import FanControlCore
import FanControlKit

// MARK: - Widget settings

struct FanControlWidgetSettings: Defaults.Serializable, Codable, Equatable, Hashable {

    /// Size of the widget in the Nook grid.
    /// Raw values match `NookWidget.NookGridSizeType` (medium = 2, doubleWide = 5),
    /// and DynamicNotch lays widgets out at `rawValue * 50` points.
    enum GridSizeChoice: Int, Codable, CaseIterable, Hashable {
        case medium = 2
        case doubleWide = 5

        /// Width in points inside the Nook (`gridSizeType * 50`).
        var widthInPoints: CGFloat { CGFloat(rawValue) * 50 }
    }

    /// Widget layout size.
    var gridSize: GridSizeChoice = .medium
    /// Fan ids to show (`FanDevice.id`); `nil` shows every fan.
    var visibleFanIDs: [Int]? = nil
    /// Sensor keys to show (`SensorReading.id`, aggregate ids such as
    /// `"agg:cpu"` included); `nil` shows the 3 hottest overview sensors
    /// (see `visibleSensors(from:aggregateDefinitions:)`).
    var visibleSensorKeys: [String]? = nil
    /// Unit used for temperatures in the widget, the alert and the settings pane.
    var temperatureUnit: TemperatureUnit = .celsius
    /// Show the profile pull-down menu in the widget.
    var showProfilePicker: Bool = true
    /// Show the target RPM next to the measured RPM.
    var showTargetRPM: Bool = false

    init(gridSize: GridSizeChoice = .medium,
         visibleFanIDs: [Int]? = nil,
         visibleSensorKeys: [String]? = nil,
         temperatureUnit: TemperatureUnit = .celsius,
         showProfilePicker: Bool = true,
         showTargetRPM: Bool = false) {
        self.gridSize = gridSize
        self.visibleFanIDs = visibleFanIDs
        self.visibleSensorKeys = visibleSensorKeys
        self.temperatureUnit = temperatureUnit
        self.showProfilePicker = showProfilePicker
        self.showTargetRPM = showTargetRPM
    }

    enum CodingKeys: String, CodingKey {
        case gridSize, visibleFanIDs, visibleSensorKeys, temperatureUnit, showProfilePicker, showTargetRPM
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FanControlWidgetSettings()
        gridSize = try container.decodeIfPresent(GridSizeChoice.self, forKey: .gridSize) ?? defaults.gridSize
        visibleFanIDs = try container.decodeIfPresent([Int].self, forKey: .visibleFanIDs)
        visibleSensorKeys = try container.decodeIfPresent([String].self, forKey: .visibleSensorKeys)
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? defaults.temperatureUnit
        showProfilePicker = try container.decodeIfPresent(Bool.self, forKey: .showProfilePicker) ?? defaults.showProfilePicker
        showTargetRPM = try container.decodeIfPresent(Bool.self, forKey: .showTargetRPM) ?? defaults.showTargetRPM
    }

    /// The fans to display, in hardware order.
    func visibleFans(from fans: [FanDevice]) -> [FanDevice] {
        guard let ids = visibleFanIDs else { return fans }
        return fans.filter { ids.contains($0.id) }
    }

    /// The sensors to display: the user's selection in selection order, or,
    /// when nothing is selected, the 3 hottest finite readings of
    /// `SensorAggregator.overview` — the CPU (max) / GPU (max) aggregates stand
    /// in for their individual core keys (so the hottest core is not listed
    /// twice), other sensors (battery, storage, …) compete as before. Without
    /// aggregates (e.g. an older kit or no CPU/GPU keys) this is the plain
    /// 3 hottest sensors.
    func visibleSensors(from readings: [SensorReading],
                        aggregateDefinitions: [SensorAggregateDefinition] = FanControlPlatform.sensorAggregateDefinitions)
        -> [SensorReading] {
        guard let keys = visibleSensorKeys else {
            return Array(SensorAggregator.overview(readings, definitions: aggregateDefinitions)
                .filter { $0.temperature.isFinite }
                .sorted { $0.temperature > $1.temperature }
                .prefix(3))
        }
        return keys.compactMap { key in readings.first { $0.id == key } }
    }
}

// MARK: - General settings

struct FanControlGeneralSettings: Defaults.Serializable, Codable, Equatable, Hashable {

    /// Polling intervals offered in the settings pane (seconds, design doc §4.3).
    static let pollingIntervalChoices: [TimeInterval] = [1, 2, 5, 10]

    /// Master switch for the fan control feature (off by default, design doc §5.5).
    var isEnabled: Bool = false
    /// Sensor/RPM polling interval in seconds.
    var pollingInterval: TimeInterval = 2.0
    /// Start monitoring at app launch when the feature is enabled.
    var autoStartMonitoring: Bool = true
    /// Pause polling while the Nook (and therefore the widget) is hidden (design doc §5.4 (c)).
    var pauseWhenNookHidden: Bool = true
    /// Re-apply the active profile after the Mac wakes from sleep.
    var reapplyProfileAfterWake: Bool = true
    /// Show the high-temperature Live Activity.
    var highTemperatureAlertEnabled: Bool = true
    /// Show the fan-stopped Live Activity.
    var fanAnomalyAlertEnabled: Bool = true

    init(isEnabled: Bool = false,
         pollingInterval: TimeInterval = 2.0,
         autoStartMonitoring: Bool = true,
         pauseWhenNookHidden: Bool = true,
         reapplyProfileAfterWake: Bool = true,
         highTemperatureAlertEnabled: Bool = true,
         fanAnomalyAlertEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.pollingInterval = pollingInterval
        self.autoStartMonitoring = autoStartMonitoring
        self.pauseWhenNookHidden = pauseWhenNookHidden
        self.reapplyProfileAfterWake = reapplyProfileAfterWake
        self.highTemperatureAlertEnabled = highTemperatureAlertEnabled
        self.fanAnomalyAlertEnabled = fanAnomalyAlertEnabled
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, pollingInterval, autoStartMonitoring, pauseWhenNookHidden,
             reapplyProfileAfterWake, highTemperatureAlertEnabled, fanAnomalyAlertEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanControlGeneralSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        pollingInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollingInterval) ?? d.pollingInterval
        autoStartMonitoring = try container.decodeIfPresent(Bool.self, forKey: .autoStartMonitoring) ?? d.autoStartMonitoring
        pauseWhenNookHidden = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenNookHidden) ?? d.pauseWhenNookHidden
        reapplyProfileAfterWake = try container.decodeIfPresent(Bool.self, forKey: .reapplyProfileAfterWake) ?? d.reapplyProfileAfterWake
        highTemperatureAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .highTemperatureAlertEnabled) ?? d.highTemperatureAlertEnabled
        fanAnomalyAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .fanAnomalyAlertEnabled) ?? d.fanAnomalyAlertEnabled
    }
}

// MARK: - Defaults keys

extension Defaults.Keys {
    static let fanControlWidgetSettings = Key<FanControlWidgetSettings>("fanControlWidgetSettings", default: .init())
    static let fanControlGeneralSettings = Key<FanControlGeneralSettings>("fanControlGeneralSettings", default: .init())
}

// MARK: - Formatting helpers shared by the Fan Control views

enum FanControlFormatting {

    /// "61°C" / "142°F"; "--" for non-finite values. Unit symbols are not localized.
    static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        guard celsius.isFinite else { return "--" }
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return "\(Int(value.rounded()))\(unitSymbol(unit))"
    }

    /// "61°C" for a reading.
    static func temperature(_ reading: SensorReading, unit: TemperatureUnit) -> String {
        temperature(reading.temperature, unit: unit)
    }

    static func unitSymbol(_ unit: TemperatureUnit) -> String {
        unit == .celsius ? "°C" : "°F"
    }

    /// "2,500" using the current locale's grouping; "--" when unknown.
    static func rpm(_ rpm: Int?) -> String {
        guard let rpm else { return "--" }
        return rpm.formatted()
    }

    /// Whether `sensor` is shown in red: the same rule as the high-temperature
    /// alert (`AlertEvaluator.evaluateHighTemperature`), i.e. only CPU/GPU sensors
    /// (`policy.emergencySensorPrefixes`) at or above `policy.highTemperatureAlert`.
    /// An aggregate counts as CPU/GPU when one of its member prefixes is an
    /// emergency prefix (its value is then that of an emergency sensor).
    static func isAlertTemperature(_ sensor: SensorReading, policy: SafetyPolicy) -> Bool {
        guard sensor.temperature.isFinite, sensor.temperature >= policy.highTemperatureAlert else { return false }
        if sensor.isAggregate {
            let members = FanControlPlatform.sensorAggregateDefinitions
                .first { $0.id == sensor.id }?.memberPrefixes ?? []
            return members.contains { policy.emergencySensorPrefixes.contains($0) }
        }
        return policy.emergencySensorPrefixes.contains { sensor.id.hasPrefix($0) }
    }

    /// Display name for a reading: aggregate names ("CPU (max)", …, our own
    /// labels) go through Localizable.strings; SMC sensor names from
    /// `SensorCatalog` stay verbatim (community-sourced, not localized).
    static func sensorName(_ sensor: SensorReading) -> String {
        guard sensor.isAggregate else { return sensor.name }
        return NSLocalizedString(sensor.name, comment: "Aggregate sensor name")
    }

    /// `readings` with the aggregates moved to the front (each part keeps its order).
    static func aggregatesFirst(_ readings: [SensorReading]) -> [SensorReading] {
        readings.filter(\.isAggregate) + readings.filter { !$0.isAggregate }
    }

    /// Localized display name for a profile: built-in names ("Automatic",
    /// "Silent", "Maximum") go through Localizable.strings, user names are verbatim.
    static func profileName(_ profile: FanProfile) -> String {
        guard profile.isBuiltIn else { return profile.name }
        return NSLocalizedString(profile.name, comment: "Built-in fan profile name")
    }
}
#endif
