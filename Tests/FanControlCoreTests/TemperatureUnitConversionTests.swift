import Foundation
import Testing
@testable import FanControlCore

/// `TemperatureUnitConversion`: stored °C, displayed / stepped in °C or °F.
struct TemperatureUnitConversionTests {

    private typealias C = TemperatureUnitConversion

    @Test func testAbsoluteAndDeltaConversion() {
        #expect(C.displayValue(celsius: 90, kind: .absolute, unit: .fahrenheit) == 194)
        #expect(C.displayValue(celsius: 100, kind: .absolute, unit: .fahrenheit) == 212)
        #expect(C.displayValue(celsius: 5, kind: .delta, unit: .fahrenheit) == 9)
        #expect(C.displayValue(celsius: 90, kind: .absolute, unit: .celsius) == 90)
        #expect(C.celsius(displayValue: 212, kind: .absolute, unit: .fahrenheit) == 100)
        #expect(C.celsius(displayValue: 9, kind: .delta, unit: .fahrenheit) == 5)
        #expect(C.celsius(displayValue: 42, kind: .delta, unit: .celsius) == 42)
    }

    @Test func testSteppingCelsiusIsOneDegree() {
        #expect(C.stepped(celsius: 90, kind: .absolute, unit: .celsius, up: true) == 91)
        #expect(C.stepped(celsius: 90, kind: .absolute, unit: .celsius, up: false) == 89)
        // A fractional stored value (set in °F) snaps to the next whole °C.
        #expect(C.stepped(celsius: 89.4, kind: .absolute, unit: .celsius, up: true) == 90)
        #expect(C.stepped(celsius: 89.4, kind: .absolute, unit: .celsius, up: false) == 89)
    }

    @Test func testSteppingFahrenheitIsOneDegreeF() {
        let up = C.stepped(celsius: 90, kind: .absolute, unit: .fahrenheit, up: true)
        #expect(abs(C.displayValue(celsius: up, kind: .absolute, unit: .fahrenheit) - 195) < 1e-9)
        let down = C.stepped(celsius: 90, kind: .absolute, unit: .fahrenheit, up: false)
        #expect(abs(C.displayValue(celsius: down, kind: .absolute, unit: .fahrenheit) - 193) < 1e-9)
        // Repeated steps never drift off whole °F despite the fractional °C.
        var value = 70.0
        for _ in 0..<54 { value = C.stepped(celsius: value, kind: .absolute, unit: .fahrenheit, up: true) }
        #expect(abs(value - 100) < 1e-9)   // 158 °F + 54 = 212 °F
        #expect(C.label(celsius: value, kind: .absolute, unit: .fahrenheit) == "212 °F")
        // Hysteresis: 5 °C = 9 °F → 10 °F = 5.56 °C.
        let h = C.stepped(celsius: 5, kind: .delta, unit: .fahrenheit, up: true)
        #expect(abs(h - 50.0 / 9) < 1e-9)
        // From the 1.8 °F floor, a step up goes to 2 °F.
        let fromFloor = C.stepped(celsius: 1, kind: .delta, unit: .fahrenheit, up: true)
        #expect(abs(C.displayValue(celsius: fromFloor, kind: .delta, unit: .fahrenheit) - 2) < 1e-9)
    }

    @Test func testSteppedValuesClampInCelsius() {
        // 1 °C hysteresis floor = 1.8 °F: a step down converts to 0.8 °F and clamps back to 1 °C.
        let down = C.stepped(celsius: 1, kind: .delta, unit: .fahrenheit, up: false)
        let t = ThresholdBounds.settingAlertHysteresis(down, in: .default)
        #expect(t.alertHysteresis == 1)
        #expect(!C.canStep(celsius: 1, up: false, within: ThresholdBounds.hysteresisRange))
        #expect(C.canStep(celsius: 1, up: true, within: ThresholdBounds.hysteresisRange))
        #expect(!C.canStep(celsius: 100, up: true, within: ThresholdBounds.alertRange))
        // Emergency above 105 °C (221 °F) clamps.
        let over = C.stepped(celsius: 105, kind: .absolute, unit: .fahrenheit, up: true)
        #expect(ThresholdBounds.settingEmergencyTemperature(over, in: .default).emergencyTemperature == 105)
    }

    @Test func testLabels() {
        #expect(C.label(celsius: 90, kind: .absolute, unit: .celsius) == "90 °C")
        #expect(C.label(celsius: 90, kind: .absolute, unit: .fahrenheit) == "194 °F")
        #expect(C.label(celsius: 1, kind: .delta, unit: .fahrenheit) == "1.8 °F")
        #expect(C.label(celsius: 5, kind: .delta, unit: .fahrenheit) == "9 °F")
        // 193 °F stored as 89.44… °C shows one decimal in °C.
        let c = C.celsius(displayValue: 193, kind: .absolute, unit: .fahrenheit)
        #expect(C.label(celsius: c, kind: .absolute, unit: .celsius) == "89.4 °C")
        #expect(C.label(celsius: c, kind: .absolute, unit: .fahrenheit) == "193 °F")
        #expect(C.label(celsius: .nan, kind: .absolute, unit: .celsius) == "-- °C")
    }
}
