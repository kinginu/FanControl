import Foundation
import Testing
@testable import FanControlCore

/// `ThresholdBounds` / `SafetyThresholds`.
@Suite("Threshold bounds", .tags(.safety))
struct ThresholdBoundsTests {

    private func t(_ alert: Double, _ emergency: Double, _ hysteresis: Double) -> SafetyThresholds {
        SafetyThresholds(highTemperatureAlert: alert, emergencyTemperature: emergency, alertHysteresis: hysteresis)
    }

    @Test func defaultsMatchPolicy() {
        #expect(SafetyThresholds.default == t(90, 95, 5))
        #expect(SafetyPolicy.default.thresholds == .default)
        #expect(ThresholdBounds.clamped(.default) == .default)
    }

    @Test func clampedRanges() {
        #expect(ThresholdBounds.clamped(t(60, 50, 0)) == t(70, 71, 1))
        #expect(ThresholdBounds.clamped(t(120, 130, 20)) == t(100, 105, 10))
        // Emergency must stay above the alert.
        #expect(ThresholdBounds.clamped(t(90, 90, 5)) == t(90, 91, 5))
        #expect(ThresholdBounds.clamped(t(85, 99, 3)) == t(85, 99, 3))
        // Non-finite values fall back to the defaults.
        #expect(ThresholdBounds.clamped(t(.nan, .infinity, -.infinity)) == t(90, 95, 5))
        #expect(ThresholdBounds.emergencyRange(forAlert: 80) == 81...105)
        #expect(ThresholdBounds.emergencyOverallRange == 71...105)
    }

    @Test func settingOneReclampsOthers() {
        // Raising the alert pushes the emergency threshold up.
        #expect(ThresholdBounds.settingHighTemperatureAlert(98, in: .default) == t(98, 99, 5))
        #expect(ThresholdBounds.settingHighTemperatureAlert(150, in: .default) == t(100, 101, 5))
        #expect(ThresholdBounds.settingHighTemperatureAlert(80, in: .default) == t(80, 95, 5))
        // Lowering the emergency threshold pulls the alert down.
        #expect(ThresholdBounds.settingEmergencyTemperature(85, in: .default) == t(84, 85, 5))
        #expect(ThresholdBounds.settingEmergencyTemperature(10, in: .default) == t(70, 71, 5))
        #expect(ThresholdBounds.settingEmergencyTemperature(200, in: .default) == t(90, 105, 5))
        // Hysteresis is independent.
        #expect(ThresholdBounds.settingAlertHysteresis(0, in: .default) == t(90, 95, 1))
        #expect(ThresholdBounds.settingAlertHysteresis(8, in: t(60, 50, 3)) == t(70, 71, 8))
    }

    @Test func policyThresholdsKeepOtherFields() {
        var policy = SafetyPolicy(emergencySensorPrefixes: ["Tp"], enforceHardwareMinimum: false)
        policy.thresholds = t(80, 88, 3)
        #expect(policy.highTemperatureAlert == 80 && policy.emergencyTemperature == 88 && policy.alertHysteresis == 3)
        #expect(policy.emergencySensorPrefixes == ["Tp"])
        #expect(!policy.enforceHardwareMinimum)
        policy.thresholds = t(200, 1, 0)
        #expect(policy.clamped().thresholds == t(100, 101, 1))
        #expect(policy.clamped().emergencySensorPrefixes == ["Tp"])
    }

    @Test func decodingMissingKeysUsesDefaults() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SafetyThresholds.self, from: Data("{}".utf8)) == .default)
        #expect(try decoder.decode(SafetyThresholds.self, from: Data(#"{"emergencyTemperature":99}"#.utf8))
                == t(90, 99, 5))
        let roundTrip = try decoder.decode(SafetyThresholds.self, from: JSONEncoder().encode(t(80, 88, 3)))
        #expect(roundTrip == t(80, 88, 3))
    }

    /// Lower thresholds change what `AlertEvaluator` reports for the same reading.
    @Test func evaluationFollowsThresholds() {
        let cpu = [SensorReading(id: "Tp01", name: "CPU", temperature: 86)]
        var defaultEvaluator = AlertEvaluator()
        #expect(defaultEvaluator.evaluateHighTemperature(sensors: cpu, policy: .default) == false)
        #expect(defaultEvaluator.evaluateEmergency(sensors: cpu, policy: .default) == false)

        var lowered = SafetyPolicy.default
        lowered.thresholds = t(80, 85, 2)
        var evaluator = AlertEvaluator()
        #expect(evaluator.evaluateHighTemperature(sensors: cpu, policy: lowered) == true)
        #expect(evaluator.evaluateEmergency(sensors: cpu, policy: lowered) == true)
        // Hysteresis 2: emergency stays on at 83.5, off at 83.
        #expect(evaluator.evaluateEmergency(sensors: [SensorReading(id: "Tp01", name: "CPU", temperature: 83.5)],
                                            policy: lowered) == true)
        #expect(evaluator.evaluateEmergency(sensors: [SensorReading(id: "Tp01", name: "CPU", temperature: 83)],
                                             policy: lowered) == false)
    }
}
