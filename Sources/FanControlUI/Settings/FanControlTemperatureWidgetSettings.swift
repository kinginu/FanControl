#if os(macOS)
// Settings of the Temperature widget (FanControlSettingKey.temperatureWidget, stored under
// "fanControlTemperatureWidgetSettings"). Added 2026-10-20 when the CPU / GPU / SSD
// temperatures moved out of the Fan Control widget. The temperature unit is shared with the
// Fan Control widget (`FanControlWidgetSettings.temperatureUnit`).
//
// Decoding is tolerant (`decodeIfPresent` with defaults) so that adding a field later never
// resets the stored settings.

import Foundation
import FanControlCore
import FanControlKit

public struct FanControlTemperatureWidgetSettings: Codable, CodableStoredValue, Equatable, Hashable, Sendable {

    /// Time window of the history chart. Raw value = minutes.
    public enum HistoryWindow: Int, Codable, CaseIterable, Hashable, Identifiable, Sendable {
        case oneMinute = 1
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30

        public var id: Int { rawValue }
        public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
        /// "1", "5", … (the chips show the number; "min" is in the label next to them).
        public var shortLabel: String { rawValue.formatted() }
    }

    /// The series the widget can show, in display order: CPU (max), GPU (max), SSD
    /// (`TemperatureHistory.defaultKeys`, which the manager always records).
    public static let seriesKeys: [String] = [SensorAggregator.ID.cpu, SensorAggregator.ID.gpu, "TH0x"]

    /// Width in points (5 grid cells × 50 pt, like the double-wide Fan Control widget).
    public static let widthInPoints: CGFloat = 250

    /// Chart window; default 5 min (user decision 2026-10-20).
    public var historyWindow: HistoryWindow = .fiveMinutes
    /// Series shown (subset of `seriesKeys`); an empty selection shows all of them.
    public var visibleKeys: [String] = FanControlTemperatureWidgetSettings.seriesKeys
    /// Highest / lowest value of the window under each current value.
    public var showsMinMax: Bool = true
    /// The high-temperature alert threshold (`SafetyPolicy.highTemperatureAlert`) as a dashed line.
    public var showsAlertThreshold: Bool = true

    public init(historyWindow: HistoryWindow = .fiveMinutes,
         visibleKeys: [String] = FanControlTemperatureWidgetSettings.seriesKeys,
         showsMinMax: Bool = true,
         showsAlertThreshold: Bool = true) {
        self.historyWindow = historyWindow
        self.visibleKeys = visibleKeys
        self.showsMinMax = showsMinMax
        self.showsAlertThreshold = showsAlertThreshold
    }

    enum CodingKeys: String, CodingKey {
        case historyWindow, visibleKeys, showsMinMax, showsAlertThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanControlTemperatureWidgetSettings()
        historyWindow = (try? container.decodeIfPresent(HistoryWindow.self, forKey: .historyWindow)) ?? d.historyWindow
        visibleKeys = try container.decodeIfPresent([String].self, forKey: .visibleKeys) ?? d.visibleKeys
        showsMinMax = try container.decodeIfPresent(Bool.self, forKey: .showsMinMax) ?? d.showsMinMax
        showsAlertThreshold = try container.decodeIfPresent(Bool.self, forKey: .showsAlertThreshold) ?? d.showsAlertThreshold
    }

    /// The series to show, in `seriesKeys` order (all of them when the selection is empty).
    public var shownKeys: [String] {
        let selected = Self.seriesKeys.filter { visibleKeys.contains($0) }
        return selected.isEmpty ? Self.seriesKeys : selected
    }
}
#endif
