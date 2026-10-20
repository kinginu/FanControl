import Foundation

/// The three user-adjustable temperature thresholds of `SafetyPolicy`
/// (design doc §5.6). Kept separate from the policy so that a settings UI can
/// persist and edit them without touching `emergencySensorPrefixes` or
/// `enforceHardwareMinimum`.
public struct SafetyThresholds: Codable, Hashable, Sendable {
    /// High-temperature alert on (°C). Default 90.
    public var highTemperatureAlert: Double
    /// Emergency override (every fan at maximum) on (°C). Default 95.
    public var emergencyTemperature: Double
    /// Both the alert and the emergency latch turn off this many °C below
    /// their threshold. Default 5.
    public var alertHysteresis: Double

    public init(highTemperatureAlert: Double = 90, emergencyTemperature: Double = 95, alertHysteresis: Double = 5) {
        self.highTemperatureAlert = highTemperatureAlert
        self.emergencyTemperature = emergencyTemperature
        self.alertHysteresis = alertHysteresis
    }

    /// 90 °C alert, 95 °C emergency, 5 °C hysteresis (= `SafetyPolicy.default`).
    public static let `default` = SafetyThresholds()

    /// Missing keys decode to the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SafetyThresholds.default
        highTemperatureAlert = try container.decodeIfPresent(Double.self, forKey: .highTemperatureAlert)
            ?? defaults.highTemperatureAlert
        emergencyTemperature = try container.decodeIfPresent(Double.self, forKey: .emergencyTemperature)
            ?? defaults.emergencyTemperature
        alertHysteresis = try container.decodeIfPresent(Double.self, forKey: .alertHysteresis)
            ?? defaults.alertHysteresis
    }

    private enum CodingKeys: String, CodingKey {
        case highTemperatureAlert, emergencyTemperature, alertHysteresis
    }
}

public extension SafetyPolicy {
    /// The policy's alert / emergency / hysteresis values. Setting it changes
    /// only those three fields (`emergencySensorPrefixes` and
    /// `enforceHardwareMinimum` are kept) and does not clamp; use `clamped()`
    /// or `ThresholdBounds` for user input.
    var thresholds: SafetyThresholds {
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

    /// The policy with its thresholds clamped by `ThresholdBounds.clamped(_:)`.
    func clamped() -> SafetyPolicy {
        var policy = self
        policy.thresholds = ThresholdBounds.clamped(thresholds)
        return policy
    }
}
