import Foundation

/// Celsius ↔ display-unit conversion for user-edited temperatures (pure).
///
/// Values are always *stored* in °C; only the displayed number and the step
/// follow the selected `TemperatureUnit`. Stepping moves to the next whole
/// number in the displayed unit (1 °C or 1 °F), so a value entered in °F stays
/// a whole °F after converting back and forth, while the stored °C may be
/// fractional (e.g. 193 °F = 89.44… °C). Clamping is the caller's job and is
/// done in °C (`ThresholdBounds`).
public enum TemperatureUnitConversion {

    /// Whether a value is an absolute temperature (°F = °C × 9/5 + 32) or a
    /// temperature difference such as a hysteresis (°F = °C × 9/5, no offset).
    public enum Kind: Sendable {
        case absolute, delta
    }

    /// Tolerance for treating a converted value as a whole number
    /// (°C → °F → °C round trips are not exact in binary floating point).
    static let wholeNumberTolerance = 1e-6

    /// `celsius` in `unit`.
    public static func displayValue(celsius: Double, kind: Kind, unit: TemperatureUnit) -> Double {
        switch (unit, kind) {
        case (.celsius, _): return celsius
        case (.fahrenheit, .absolute): return celsius * 9 / 5 + 32
        case (.fahrenheit, .delta): return celsius * 9 / 5
        }
    }

    /// A value given in `unit` converted to °C.
    public static func celsius(displayValue value: Double, kind: Kind, unit: TemperatureUnit) -> Double {
        switch (unit, kind) {
        case (.celsius, _): return value
        case (.fahrenheit, .absolute): return (value - 32) * 5 / 9
        case (.fahrenheit, .delta): return value * 5 / 9
        }
    }

    /// The stored °C value after one step up (`up == true`) or down in `unit`:
    /// the next whole number above / below the displayed value (a value already
    /// on a whole number moves by exactly 1). Not clamped.
    public static func stepped(celsius: Double, kind: Kind, unit: TemperatureUnit, up: Bool) -> Double {
        let shown = displayValue(celsius: celsius, kind: kind, unit: unit)
        let next = up ? (shown + wholeNumberTolerance).rounded(.down) + 1
                      : (shown - wholeNumberTolerance).rounded(.up) - 1
        return self.celsius(displayValue: next, kind: kind, unit: unit)
    }

    /// The displayed number, rounded to one decimal; a value within the
    /// tolerance of a whole number is returned as that whole number.
    public static func roundedDisplayValue(celsius: Double, kind: Kind, unit: TemperatureUnit) -> Double {
        let shown = displayValue(celsius: celsius, kind: kind, unit: unit)
        let whole = shown.rounded()
        if abs(shown - whole) < 0.05 { return whole }
        return (shown * 10).rounded() / 10
    }

    /// "90 °C", "194 °F", "1.8 °F": the displayed number (one decimal only when
    /// it is not whole; "." as the separator) followed by the unit symbol.
    public static func label(celsius: Double, kind: Kind, unit: TemperatureUnit) -> String {
        guard celsius.isFinite else { return "-- \(symbol(unit))" }
        let value = roundedDisplayValue(celsius: celsius, kind: kind, unit: unit)
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(symbol(unit))"
    }

    /// "°C" / "°F" (not localized).
    public static func symbol(_ unit: TemperatureUnit) -> String {
        unit == .celsius ? "°C" : "°F"
    }

    /// Whether a step up / down from `celsius` can still change the value inside
    /// `range` (°C): false once the value sits on (or within the tolerance of)
    /// that end of the range.
    public static func canStep(celsius: Double, up: Bool, within range: ClosedRange<Double>) -> Bool {
        up ? celsius < range.upperBound - wholeNumberTolerance
           : celsius > range.lowerBound + wholeNumberTolerance
    }
}
