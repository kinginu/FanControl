#if os(macOS)
import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// `FanControlManager.applySafetyThresholds(_:)` (design doc §5.6): the app's
/// threshold setting reaches `safetyPolicy`, which every poll evaluates.
@Suite("Safety thresholds (manager)", .tags(.safety, .manager))
@MainActor
struct SafetyThresholdsManagerTests {
    private let defaults = ScratchDefaults()

    @Test func thresholdsChangeEvaluation() {
        let manager = Isolated.manager(defaults: defaults)
        let reading = [SensorReading(id: "Tg0f", name: "GPU 0f", temperature: 87)]
        var before = AlertEvaluator()
        #expect(before.evaluateHighTemperature(sensors: reading, policy: manager.safetyPolicy) == false,
                "87 °C is below the default 90 °C alert")
        #expect(before.evaluateEmergency(sensors: reading, policy: manager.safetyPolicy) == false,
                "87 °C is below the default 95 °C emergency")

        manager.applySafetyThresholds(SafetyThresholds(highTemperatureAlert: 80, emergencyTemperature: 86,
                                                       alertHysteresis: 3))
        #expect(manager.safetyPolicy.thresholds == SafetyThresholds(highTemperatureAlert: 80,
                                                                    emergencyTemperature: 86, alertHysteresis: 3))
        var after = AlertEvaluator()
        #expect(after.evaluateHighTemperature(sensors: reading, policy: manager.safetyPolicy) == true)
        #expect(after.evaluateEmergency(sensors: reading, policy: manager.safetyPolicy) == true)
    }

    @Test func keepsPrefixesAndHardwareMinimumAndClamps() {
        let manager = Isolated.manager(defaults: defaults)
        manager.safetyPolicy.emergencySensorPrefixes = ["Tp", "Tg"]
        manager.safetyPolicy.enforceHardwareMinimum = false
        manager.applySafetyThresholds(SafetyThresholds(highTemperatureAlert: 150, emergencyTemperature: 20,
                                                       alertHysteresis: 0))
        #expect(manager.safetyPolicy.thresholds == SafetyThresholds(highTemperatureAlert: 100,
                                                                    emergencyTemperature: 101, alertHysteresis: 1))
        #expect(manager.safetyPolicy.emergencySensorPrefixes == ["Tp", "Tg"])
        #expect(!manager.safetyPolicy.enforceHardwareMinimum)

        manager.applySafetyThresholds(.default)
        #expect(manager.safetyPolicy == SafetyPolicy(emergencySensorPrefixes: ["Tp", "Tg"],
                                                     enforceHardwareMinimum: false))
    }
}
#endif
