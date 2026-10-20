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

/// Allowed ranges of `SafetyThresholds` (pure; design doc §5.6):
///
/// - alert: `alertRange` = 70…100 °C
/// - emergency: `emergencyRange(forAlert:)` = (alert + 1)…105 °C
/// - hysteresis: `hysteresisRange` = 1…10 °C
///
/// Non-finite values are replaced by the default before clamping. Changing one
/// value with `setting…` re-clamps the others: raising the alert pushes the
/// emergency threshold up (to at least alert + 1), lowering the emergency
/// threshold pulls the alert down (to at most emergency − 1).
public enum ThresholdBounds {
    public static let alertRange: ClosedRange<Double> = 70...100
    public static let emergencyUpperBound: Double = 105
    /// Minimum distance between the alert and the emergency threshold (°C).
    public static let emergencyMinimumGap: Double = 1
    public static let hysteresisRange: ClosedRange<Double> = 1...10

    /// Every emergency value that is valid for some alert value: 71…105 °C.
    public static var emergencyOverallRange: ClosedRange<Double> {
        (alertRange.lowerBound + emergencyMinimumGap)...emergencyUpperBound
    }

    /// Emergency values valid for `alert` (clamped first): (alert + 1)…105 °C.
    public static func emergencyRange(forAlert alert: Double) -> ClosedRange<Double> {
        (clamp(alert, to: alertRange, fallback: SafetyThresholds.default.highTemperatureAlert)
            + emergencyMinimumGap)...emergencyUpperBound
    }

    /// `thresholds` with every value inside its range (alert first, then the
    /// emergency threshold against the clamped alert).
    public static func clamped(_ thresholds: SafetyThresholds) -> SafetyThresholds {
        let defaults = SafetyThresholds.default
        let alert = clamp(thresholds.highTemperatureAlert, to: alertRange, fallback: defaults.highTemperatureAlert)
        return SafetyThresholds(
            highTemperatureAlert: alert,
            emergencyTemperature: clamp(thresholds.emergencyTemperature, to: emergencyRange(forAlert: alert),
                                        fallback: defaults.emergencyTemperature),
            alertHysteresis: clamp(thresholds.alertHysteresis, to: hysteresisRange,
                                   fallback: defaults.alertHysteresis))
    }

    /// Sets the alert threshold (clamped); the emergency threshold moves up if needed.
    public static func settingHighTemperatureAlert(_ value: Double, in thresholds: SafetyThresholds) -> SafetyThresholds {
        var result = clamped(thresholds)
        result.highTemperatureAlert = clamp(value, to: alertRange, fallback: result.highTemperatureAlert)
        result.emergencyTemperature = max(result.emergencyTemperature,
                                          result.highTemperatureAlert + emergencyMinimumGap)
        return clamped(result)
    }

    /// Sets the emergency threshold (clamped to 71…105); the alert moves down if needed.
    public static func settingEmergencyTemperature(_ value: Double, in thresholds: SafetyThresholds) -> SafetyThresholds {
        var result = clamped(thresholds)
        result.emergencyTemperature = clamp(value, to: emergencyOverallRange, fallback: result.emergencyTemperature)
        result.highTemperatureAlert = min(result.highTemperatureAlert,
                                          result.emergencyTemperature - emergencyMinimumGap)
        return clamped(result)
    }

    /// Sets the hysteresis (clamped); the thresholds are only re-clamped.
    public static func settingAlertHysteresis(_ value: Double, in thresholds: SafetyThresholds) -> SafetyThresholds {
        var result = clamped(thresholds)
        result.alertHysteresis = clamp(value, to: hysteresisRange, fallback: result.alertHysteresis)
        return result
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        let finite = value.isFinite ? value : fallback
        return min(max(finite, range.lowerBound), range.upperBound)
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
