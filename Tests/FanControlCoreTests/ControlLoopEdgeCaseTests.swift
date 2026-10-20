import Foundation
import Testing
@testable import FanControlCore

/// Edge cases of the control-loop stages (`TemperatureSmoother`, `FanTargetStabilizer`),
/// the threshold bounds / hysteresis and the temperature-unit helpers.
struct ControlLoopEdgeCaseTests {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800)
    let fan2 = FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Smoother

    @Test func testSmootherResetsWhenClockGoesBackwards() {
        var smoother = TemperatureSmoother()
        smoother.update(key: "k", temperature: 60, at: at(10), tuning: .default)
        #expect(smoother.update(key: "k", temperature: 80, at: at(5), tuning: .default) == 80)
        #expect(smoother.value(for: "k") == 80)
    }

    @Test func testSmootherIgnoresNonFiniteSamples() {
        var smoother = TemperatureSmoother()
        #expect(smoother.update(key: "k", temperature: .nan, at: at(0), tuning: .default) == nil)
        #expect(smoother.value(for: "k") == nil)
        smoother.update(key: "k", temperature: 60, at: at(1), tuning: .default)
        #expect(smoother.update(key: "k", temperature: .infinity, at: at(2), tuning: .default) == 60)
        #expect(smoother.value(for: "k") == 60)
        // A non-finite reading passes through `smooth` unchanged (fail loud downstream).
        let readings = smoother.smooth([SensorReading(id: "k", name: "k", temperature: .nan)], keys: ["k"],
                                       at: at(3), tuning: .default)
        #expect(readings[0].temperature.isNaN)
        #expect(smoother.value(for: "k") == 60)
    }

    @Test func testSmootherWithZeroTimeConstantsPassesThrough() {
        var smoother = TemperatureSmoother()
        for (i, value) in [50.0, 90, 40, 70].enumerated() {
            #expect(smoother.update(key: "k", temperature: value, at: at(Double(i)), tuning: .disabled) == value)
        }
        smoother.reset()
        #expect(smoother.values.isEmpty)
    }

    @Test func testSmootherConvergesAndStaysBetweenValues() {
        var smoother = TemperatureSmoother()
        smoother.update(key: "k", temperature: 40, at: at(0), tuning: .default)
        var previous = 40.0
        for second in 1...200 {
            let value = smoother.update(key: "k", temperature: 80, at: at(Double(second)), tuning: .default)!
            #expect(value >= previous && value <= 80)
            previous = value
        }
        #expect(abs(previous - 80) < 1e-6)
    }

    // MARK: Stabilizer

    @Test func testStabilizerTreatsNonPositiveStepAsOneRPM() {
        var tuning = FanControlTuning.disabled
        tuning.maximumStepRPM = 0
        var stabilizer = FanTargetStabilizer()
        _ = stabilizer.stabilize([0: 3000], fans: [fan], at: at(0), tuning: tuning)
        #expect(stabilizer.stabilize([0: 4000], fans: [fan], at: at(1), tuning: tuning) == [0: 3001])
    }

    @Test func testStabilizerAutomaticDropsStateAndFirstTargetIsTakenAsIs() {
        var stabilizer = FanTargetStabilizer()
        _ = stabilizer.stabilize([0: 3000, 1: 3000], fans: [fan, fan2], at: at(0), tuning: .default)
        let result = stabilizer.stabilize([0: nil, 1: 6000], fans: [fan, fan2], at: at(1), tuning: .default)
        #expect(result[0] == .some(nil))
        #expect(result[1] == 3500)
        #expect(stabilizer.states[0] == nil)
        // Back from automatic: the first target is not limited.
        #expect(stabilizer.stabilize([0: 6000], fans: [fan], at: at(2), tuning: .default) == [0: 6000])
        #expect(stabilizer.states[0]?.direction == 0)
    }

    @Test func testSeedKeepsDwellOfUnchangedTargets() {
        var stabilizer = FanTargetStabilizer()
        stabilizer.seed([0: 4000], fans: [fan], at: at(0))
        stabilizer.seed([0: 4000], fans: [fan], at: at(50))
        #expect(stabilizer.states[0]?.changedAt == at(0))
        stabilizer.seed([0: 3000], fans: [fan], at: at(60))
        #expect(stabilizer.states[0] == .init(rpm: 3000, changedAt: at(60), direction: -1))
        stabilizer.reset()
        #expect(stabilizer.states.isEmpty)
    }

    /// Targets never leave the planned range and the per-poll change never exceeds the
    /// slew limit, for arbitrary plans.
    @Test func testStabilizerOutputIsBounded() throws {
        var stabilizer = FanTargetStabilizer()
        let tuning = FanControlTuning.default
        var last: Int?
        var rng = FanCurveEdgeCaseTests.SplitMix64(state: 7)
        for second in 0..<500 {
            let planned = Int.random(in: fan.minRPM...fan.maxRPM, using: &rng)
            let result = stabilizer.stabilize([0: planned], fans: [fan], at: at(Double(second)), tuning: tuning)
            let rpm = try #require(result[0] ?? nil)
            #expect(fan.rpmRange.contains(rpm))
            if let last { #expect(abs(rpm - last) <= tuning.maximumStepRPM) }
            last = rpm
        }
    }

    @Test func testStabilizerToleratesDuplicateFanIDs() {
        var stabilizer = FanTargetStabilizer()
        let duplicate = FanDevice(id: 0, name: "Dup", minRPM: 1000, maxRPM: 2000)
        #expect(stabilizer.stabilize([0: 3000], fans: [fan, duplicate], at: at(0), tuning: .default) == [0: 3000])
    }

    // MARK: Threshold bounds and hysteresis

    @Test func testClampedThresholdsAlwaysSatisfyBounds() {
        let values: [Double] = [-.infinity, -10, 0, 1, 5, 10, 11, 69, 70, 85, 99, 100, 101, 104.5, 105, 200,
                                .infinity, .nan]
        for alert in values {
            for emergency in values {
                for hysteresis in [Double.nan, -1, 0, 1, 5, 10, 50] {
                    let raw = SafetyThresholds(highTemperatureAlert: alert, emergencyTemperature: emergency,
                                               alertHysteresis: hysteresis)
                    let c = ThresholdBounds.clamped(raw)
                    #expect(ThresholdBounds.alertRange.contains(c.highTemperatureAlert))
                    #expect(ThresholdBounds.emergencyRange(forAlert: c.highTemperatureAlert)
                        .contains(c.emergencyTemperature))
                    #expect(c.emergencyTemperature - c.highTemperatureAlert >= ThresholdBounds.emergencyMinimumGap)
                    #expect(ThresholdBounds.hysteresisRange.contains(c.alertHysteresis))
                    #expect(ThresholdBounds.clamped(c) == c)
                }
            }
        }
        let nan = SafetyThresholds(highTemperatureAlert: .nan, emergencyTemperature: .nan, alertHysteresis: .nan)
        #expect(ThresholdBounds.clamped(nan) == .default)
    }

    @Test func testSettersKeepTheGap() {
        var t = SafetyThresholds.default
        t = ThresholdBounds.settingHighTemperatureAlert(100, in: t)
        #expect(t.highTemperatureAlert == 100 && t.emergencyTemperature == 101)
        t = ThresholdBounds.settingEmergencyTemperature(71, in: t)
        #expect(t.emergencyTemperature == 71 && t.highTemperatureAlert == 70)
        t = ThresholdBounds.settingEmergencyTemperature(0, in: t)
        #expect(t.emergencyTemperature == ThresholdBounds.emergencyOverallRange.lowerBound)
        t = ThresholdBounds.settingAlertHysteresis(.nan, in: t)
        #expect(t.alertHysteresis == SafetyThresholds.default.alertHysteresis)
        #expect(ThresholdBounds.emergencyOverallRange == 71...105)
        #expect(ThresholdBounds.emergencyRange(forAlert: .nan) == 91...105)
    }

    /// The alert latches at the threshold and releases only `alertHysteresis` below it;
    /// a reading inside the band, or no relevant reading, keeps the state.
    @Test func testHysteresisBand() {
        var policy = SafetyPolicy.default
        policy.thresholds = SafetyThresholds(highTemperatureAlert: 80, emergencyTemperature: 90, alertHysteresis: 4)
        func reading(_ t: Double) -> [SensorReading] { [SensorReading(id: "Tp01", name: "CPU", temperature: t)] }
        var evaluator = AlertEvaluator()
        let sequence: [(Double, Bool, Bool)] = [
            (79.9, false, false), (80, true, false), (77, true, false), (76.01, true, false),
            (76, false, false), (79, false, false), (90, true, true), (86.5, true, true),
            (86, true, false), (95, true, true),
        ]
        for (temperature, alert, emergency) in sequence {
            #expect(evaluator.evaluateHighTemperature(sensors: reading(temperature), policy: policy) == alert,
                    "alert at \(temperature)")
            #expect(evaluator.evaluateEmergency(sensors: reading(temperature), policy: policy) == emergency,
                    "emergency at \(temperature)")
        }
        // No emergency-class sensor (or only non-finite ones): state kept.
        let unrelated = [SensorReading(id: "TB1T", name: "Battery", temperature: 20),
                         SensorReading(id: "Tp02", name: "CPU", temperature: .nan)]
        #expect(evaluator.evaluateEmergency(sensors: unrelated, policy: policy) == true)
        #expect(evaluator.evaluateHighTemperature(sensors: unrelated, policy: policy) == true)
    }

    // MARK: Temperature units

    @Test func testSensorReadingConversionMatchesHelper() {
        for celsius in [-40.0, 0, 37, 100] {
            let reading = SensorReading(id: "k", name: "k", temperature: celsius)
            #expect(reading.temperature(in: .fahrenheit)
                == TemperatureUnitConversion.displayValue(celsius: celsius, kind: .absolute, unit: .fahrenheit))
            #expect(reading.temperature(in: .celsius) == celsius)
        }
        #expect(SensorReading(id: "k", name: "k", temperature: -40).temperature(in: .fahrenheit) == -40)
    }

    /// Repeated °F steps always land on whole °F, and stepping up then down returns home.
    @Test func testFahrenheitSteppingRoundTrips() {
        typealias C = TemperatureUnitConversion
        var celsius = 90.0
        for _ in 0..<30 {
            celsius = C.stepped(celsius: celsius, kind: .absolute, unit: .fahrenheit, up: true)
            let shown = C.displayValue(celsius: celsius, kind: .absolute, unit: .fahrenheit)
            #expect(abs(shown - shown.rounded()) < 1e-9)
        }
        for _ in 0..<30 {
            celsius = C.stepped(celsius: celsius, kind: .absolute, unit: .fahrenheit, up: false)
        }
        #expect(abs(celsius - 90) < 1e-9)
        #expect(C.label(celsius: .nan, kind: .absolute, unit: .celsius) == "-- °C")
        #expect(C.label(celsius: 5, kind: .delta, unit: .fahrenheit) == "9 °F")
        #expect(!C.canStep(celsius: 100, up: true, within: 70...100))
        #expect(C.canStep(celsius: 100, up: false, within: 70...100))
        #expect(!C.canStep(celsius: 70 + 1e-7, up: false, within: 70...100))
    }
}
