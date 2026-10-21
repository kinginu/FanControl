#if os(macOS)
// Settings models of the Fan Control widget and the Fan Control settings pane, stored under
// `FanControlSettingKey.widget` / `.general`. The JSON field names are
// the stored format (sindresorhus/Defaults 8.2, sorted keys): never rename one.
//
// Decoding is tolerant (`decodeIfPresent` with defaults) so that adding a field in a later
// version never resets the user's stored settings.

import Foundation
import FanControlCore
import FanControlKit

// MARK: - Widget settings

public struct FanControlWidgetSettings: Codable, CodableStoredValue, Equatable, Hashable, Sendable {

    /// Size of the widget in the Nook grid.
    /// Raw values match `NookWidget.NookGridSizeType` (medium = 2, doubleWide = 5),
    /// and DynamicNotch lays widgets out at `rawValue * 50` points.
    public enum GridSizeChoice: Int, Codable, CaseIterable, Hashable, Sendable {
        case medium = 2
        case doubleWide = 5

        /// Width in points inside the Nook (`gridSizeType * 50`).
        public var widthInPoints: CGFloat { CGFloat(rawValue) * 50 }
    }

    /// Widget layout size.
    public var gridSize: GridSizeChoice = .medium
    /// Fan ids to show (`FanDevice.id`); `nil` shows every fan.
    public var visibleFanIDs: [Int]? = nil
    /// Sensor keys to show (`SensorReading.id`, aggregate ids such as
    /// `"agg:cpu"` included); `nil` shows the key temperatures
    /// (CPU (max), GPU (max), SSD; see `visibleSensors(from:aggregateDefinitions:)`).
    /// Not shown by the Fan Control widget any more: temperatures moved to the Temperature
    /// widget (2026-10-20, `FanControlTemperatureWidgetView`). Kept so stored settings decode
    /// unchanged (and for `visibleSensors`, which other views may still use).
    public var visibleSensorKeys: [String]? = nil
    /// Unit used for temperatures in the Fan Control and Temperature widgets, the alert and the
    /// settings pane.
    public var temperatureUnit: TemperatureUnit = .celsius
    /// Show the profile list (all seven profiles, click to apply) in the widget.
    /// The stored key keeps its old name (it was a pull-down menu before 2026-10-20).
    public var showProfilePicker: Bool = true
    /// Show the target RPM next to the measured RPM.
    public var showTargetRPM: Bool = false
    /// Show the fan curve of the active profile (double-wide layout only).
    public var showFanCurve: Bool = true

    public init(gridSize: GridSizeChoice = .medium,
         visibleFanIDs: [Int]? = nil,
         visibleSensorKeys: [String]? = nil,
         temperatureUnit: TemperatureUnit = .celsius,
         showProfilePicker: Bool = true,
         showTargetRPM: Bool = false,
         showFanCurve: Bool = true) {
        self.gridSize = gridSize
        self.visibleFanIDs = visibleFanIDs
        self.visibleSensorKeys = visibleSensorKeys
        self.temperatureUnit = temperatureUnit
        self.showProfilePicker = showProfilePicker
        self.showTargetRPM = showTargetRPM
        self.showFanCurve = showFanCurve
    }

    enum CodingKeys: String, CodingKey {
        case gridSize, visibleFanIDs, visibleSensorKeys, temperatureUnit, showProfilePicker, showTargetRPM,
             showFanCurve
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FanControlWidgetSettings()
        gridSize = try container.decodeIfPresent(GridSizeChoice.self, forKey: .gridSize) ?? defaults.gridSize
        visibleFanIDs = try container.decodeIfPresent([Int].self, forKey: .visibleFanIDs)
        visibleSensorKeys = try container.decodeIfPresent([String].self, forKey: .visibleSensorKeys)
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? defaults.temperatureUnit
        showProfilePicker = try container.decodeIfPresent(Bool.self, forKey: .showProfilePicker) ?? defaults.showProfilePicker
        showTargetRPM = try container.decodeIfPresent(Bool.self, forKey: .showTargetRPM) ?? defaults.showTargetRPM
        showFanCurve = try container.decodeIfPresent(Bool.self, forKey: .showFanCurve) ?? defaults.showFanCurve
    }

    /// The fans to display, in hardware order.
    public func visibleFans(from fans: [FanDevice]) -> [FanDevice] {
        guard let ids = visibleFanIDs else { return fans }
        return fans.filter { ids.contains($0.id) }
    }

    /// The sensors to display: the user's selection in selection order, or,
    /// when nothing is selected, the key temperatures
    /// (`FanControlFormatting.keyTemperatures`: CPU (max), GPU (max), SSD
    /// `TH0x`, whichever exist). Without aggregates (e.g. an older kit or no
    /// CPU/GPU keys) this falls back to the 3 hottest overview sensors
    /// (`SensorAggregator.hottestOverview`; non-thermal keys such as `Tf06`
    /// never take part). An explicit selection is honoured as-is.
    public func visibleSensors(from readings: [SensorReading],
                        aggregateDefinitions: [SensorAggregateDefinition] = FanControlPlatform.sensorAggregateDefinitions)
        -> [SensorReading] {
        guard let keys = visibleSensorKeys else {
            let key = FanControlFormatting.keyTemperatures(readings)
            return key.contains(where: \.isAggregate)
                ? key
                : SensorAggregator.hottestOverview(readings, definitions: aggregateDefinitions, limit: 3)
        }
        return keys.compactMap { key in readings.first { $0.id == key } }
    }
}

// MARK: - General settings

public struct FanControlGeneralSettings: Codable, CodableStoredValue, Equatable, Hashable, Sendable {

    /// Polling intervals offered in the settings pane (seconds).
    public static let pollingIntervalChoices: [TimeInterval] = [1, 2, 5, 10]

    /// Master switch for the fan control feature (off by default).
    public var isEnabled: Bool = false
    /// Sensor/RPM polling interval in seconds.
    public var pollingInterval: TimeInterval = 2.0
    /// Start monitoring at app launch when the feature is enabled.
    public var autoStartMonitoring: Bool = true
    /// Pause polling while the Nook (and therefore the widget) is hidden.
    public var pauseWhenNookHidden: Bool = true
    /// Re-apply the active profile after the Mac wakes from sleep.
    public var reapplyProfileAfterWake: Bool = true
    /// Show the high-temperature Live Activity.
    public var highTemperatureAlertEnabled: Bool = true
    /// Show the fan-stopped Live Activity.
    public var fanAnomalyAlertEnabled: Bool = true
    /// Poll every 10 s (or the longer polling interval) on battery.
    public var slowPollingOnBattery: Bool = true

    public init(isEnabled: Bool = false,
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
             reapplyProfileAfterWake, highTemperatureAlertEnabled, fanAnomalyAlertEnabled,
             slowPollingOnBattery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanControlGeneralSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        pollingInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollingInterval) ?? d.pollingInterval
        autoStartMonitoring = try container.decodeIfPresent(Bool.self, forKey: .autoStartMonitoring) ?? d.autoStartMonitoring
        pauseWhenNookHidden = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenNookHidden) ?? d.pauseWhenNookHidden
        reapplyProfileAfterWake = try container.decodeIfPresent(Bool.self, forKey: .reapplyProfileAfterWake) ?? d.reapplyProfileAfterWake
        highTemperatureAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .highTemperatureAlertEnabled) ?? d.highTemperatureAlertEnabled
        fanAnomalyAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .fanAnomalyAlertEnabled) ?? d.fanAnomalyAlertEnabled
        slowPollingOnBattery = try container.decodeIfPresent(Bool.self, forKey: .slowPollingOnBattery) ?? d.slowPollingOnBattery
    }
}

#endif
