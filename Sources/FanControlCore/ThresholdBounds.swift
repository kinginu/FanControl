import Foundation

/// Allowed ranges of `SafetyThresholds` (pure):
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
    /// Allowed high-temperature alert values (°C).
    public static let alertRange: ClosedRange<Double> = 70...100
    /// Highest allowed emergency threshold (°C).
    public static let emergencyUpperBound: Double = 105
    /// Minimum distance between the alert and the emergency threshold (°C).
    public static let emergencyMinimumGap: Double = 1
    /// Allowed hysteresis values (°C).
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
