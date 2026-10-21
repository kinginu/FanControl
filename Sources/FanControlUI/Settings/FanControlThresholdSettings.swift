#if os(macOS)
import Foundation
import FanControlCore

// MARK: - Temperature thresholds

/// User-set alert / emergency / hysteresis thresholds, persisted under their own
/// stored-setting key (`FanControlSettingKey.thresholds`, "fanControlThresholdSettings", separate from
/// `FanControlGeneralSettings`). Values are whole °C in practice; they are
/// clamped by `ThresholdBounds` when edited and again when mirrored into
/// `FanControlManager.safetyPolicy` (`applySafetyThresholds`). Missing keys
/// decode to the defaults (90 / 95 / 5 °C = `SafetyThresholds.default`).
public struct FanControlThresholdSettings: Codable, CodableStoredValue, Equatable, Hashable, Sendable {
    public var highTemperatureAlert: Double = SafetyThresholds.default.highTemperatureAlert
    public var emergencyTemperature: Double = SafetyThresholds.default.emergencyTemperature
    public var alertHysteresis: Double = SafetyThresholds.default.alertHysteresis

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FanControlThresholdSettings()
        highTemperatureAlert = try container.decodeIfPresent(Double.self, forKey: .highTemperatureAlert)
            ?? defaults.highTemperatureAlert
        emergencyTemperature = try container.decodeIfPresent(Double.self, forKey: .emergencyTemperature)
            ?? defaults.emergencyTemperature
        alertHysteresis = try container.decodeIfPresent(Double.self, forKey: .alertHysteresis)
            ?? defaults.alertHysteresis
    }

    enum CodingKeys: String, CodingKey {
        case highTemperatureAlert, emergencyTemperature, alertHysteresis
    }

    /// The stored values as `SafetyThresholds` (unclamped).
    public var thresholds: SafetyThresholds {
        get {
            SafetyThresholds(highTemperatureAlert: highTemperatureAlert, emergencyTemperature: emergencyTemperature,
                             alertHysteresis: alertHysteresis)
        }
        set {
            highTemperatureAlert = newValue.highTemperatureAlert
            emergencyTemperature = newValue.emergencyTemperature
            alertHysteresis = newValue.alertHysteresis
        }
    }
}
#endif
