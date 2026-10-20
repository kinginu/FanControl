import Foundation
import Testing
@testable import FanControlCore

@Suite("Fan control engine", .tags(.control))
struct FanControlEngineTests {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 1000, maxRPM: 5000)
    let fan2 = FanDevice(id: 1, name: "Fan 2", minRPM: 1200, maxRPM: 6000)
    let sensorMode = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: 40, maxTemperature: 80)

    @Test func automaticIsNil() {
        #expect(FanControlEngine.targetRPM(for: .automatic, fan: fan, sensorTemperature: 99) == nil)
        #expect(!FanControlMode.automatic.isManual)
        #expect(FanControlMode.constant(rpm: 1).isManual)
        #expect(sensorMode.isManual)
    }

    @Test func constantClamped() {
        #expect(FanControlEngine.targetRPM(for: .constant(rpm: 3000), fan: fan, sensorTemperature: nil) == 3000)
        #expect(FanControlEngine.targetRPM(for: .constant(rpm: 10), fan: fan, sensorTemperature: nil) == 1000)
        #expect(FanControlEngine.targetRPM(for: .constant(rpm: 9000), fan: fan, sensorTemperature: nil) == 5000)
        #expect(FanControlEngine.clamp(-5, to: fan) == 1000)
    }

    @Test func sensorInterpolation() {
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 20) == 1000)
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 40) == 1000)
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 60) == 3000)
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 70) == 4000)
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 80) == 5000)
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 120) == 5000)
    }

    @Test func sensorMissingFailsLoud() {
        #expect(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: nil) == 5000)
    }

    @Test func sensorStepFunction() {
        let step = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: 70, maxTemperature: 70)
        #expect(FanControlEngine.targetRPM(for: step, fan: fan, sensorTemperature: 69.9) == 1000)
        #expect(FanControlEngine.targetRPM(for: step, fan: fan, sensorTemperature: 70) == 5000)
    }

    @Test func planCoversEveryFan() {
        let profile = FanProfile(name: "Custom", modes: [0: sensorMode])
        let sensors = [SensorReading(id: "Tp09", name: "P", temperature: 60, sensorType: .smc)]
        let plan = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: sensors, policy: .default)
        #expect(plan.count == 2)
        #expect(plan[0] == .some(3000))
        #expect(plan[1] == .some(nil))
    }

    @Test func planSensorMissingGoesToMax() {
        let profile = FanProfile(name: "Custom", modes: [0: sensorMode])
        let plan = FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: .default)
        #expect(plan[0] == .some(5000))
    }

    @Test func emergencyOverride() {
        let profile = FanProfile(name: "Custom", modes: [0: .constant(rpm: 1000)])
        let sensors = [
            SensorReading(id: "TB0T", name: "Battery", temperature: 99, sensorType: .smc), // not an emergency prefix
            SensorReading(id: "Tp01", name: "P", temperature: 96, sensorType: .smc),
        ]
        let plan = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: sensors, policy: .default)
        #expect(plan[0] == .some(5000))
        #expect(plan[1] == .some(6000))
        #expect(FanControlEngine.hottestEmergencySensor(sensors, policy: .default)?.id == "Tp01")

        let cool = [SensorReading(id: "TB0T", name: "Battery", temperature: 99, sensorType: .smc)]
        let normal = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: cool, policy: .default)
        #expect(normal[0] == .some(1000))
        #expect(normal[1] == .some(nil))
    }

    @Test func enforceHardwareMinimumOff() {
        var policy = SafetyPolicy.default
        policy.enforceHardwareMinimum = false
        let profile = FanProfile(name: "Zero", modes: [0: .constant(rpm: 0)])
        #expect(FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: policy)[0] == .some(0))
        #expect(FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: .default)[0] == .some(1000))
    }
}

@Suite("Alert evaluator", .tags(.safety))
struct AlertEvaluatorTests {
    func reading(_ t: Double) -> [SensorReading] {
        [SensorReading(id: "TC0P", name: "CPU", temperature: t, sensorType: .smc)]
    }

    @Test func hysteresis() {
        var evaluator = AlertEvaluator()
        let policy = SafetyPolicy.default // alert 90, hysteresis 5
        #expect(evaluator.evaluateHighTemperature(sensors: reading(80), policy: policy) == false)
        #expect(evaluator.evaluateHighTemperature(sensors: reading(89.9), policy: policy) == false)
        #expect(evaluator.evaluateHighTemperature(sensors: reading(90), policy: policy) == true)
        #expect(evaluator.evaluateHighTemperature(sensors: reading(87), policy: policy) == true)
        #expect(evaluator.evaluateHighTemperature(sensors: [], policy: policy) == true)
        #expect(evaluator.evaluateHighTemperature(sensors: reading(85), policy: policy) == false)
        #expect(evaluator.evaluateHighTemperature(sensors: reading(88), policy: policy) == false)
    }

    @Test func fanAnomaly() {
        var evaluator = AlertEvaluator()
        let fans = [FanDevice(id: 0, name: "A", minRPM: 1000, maxRPM: 5000),
                    FanDevice(id: 1, name: "B", minRPM: 1000, maxRPM: 5000)]
        let stalled = [0: 0, 1: 2000]
        let targets = [0: 2000, 1: 2000]
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets) == [])
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets) == [])
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets) == [0])
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets) == [0])
        // Recovery resets the counter.
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: [0: 1500, 1: 2000], targetRPMs: targets) == [])
        #expect(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets) == [])
        // Target 0 is not an anomaly.
        var other = AlertEvaluator()
        for _ in 0..<5 {
            #expect(other.evaluateFanAnomaly(fans: fans, currentRPMs: [0: 0, 1: 0], targetRPMs: [0: 0],
                                                    consecutiveLimit: 1) == [])
        }
    }
}

@Suite("Codable persistence", .tags(.profiles))
struct PersistenceTests {
    let fans = [FanDevice(id: 0, name: "A", minRPM: 1200, maxRPM: 6000),
                FanDevice(id: 1, name: "B", minRPM: 1300, maxRPM: 5500)]

    @Test func modeCodableRoundtrip() throws {
        let modes: [FanControlMode] = [
            .automatic, .constant(rpm: 2500),
            .sensor(sensorKey: "Tp09", startTemperature: 45.5, maxTemperature: 85),
        ]
        let data = try JSONEncoder().encode(modes)
        #expect(try JSONDecoder().decode([FanControlMode].self, from: data) == modes)
    }

    @Test func builtInProfiles() {
        #expect(FanProfile.automatic().id == FanProfile.automatic().id)
        #expect(FanProfile.silent(for: fans).modes == [0: .constant(rpm: 1200), 1: .constant(rpm: 1300)])
        #expect(FanProfile.maximum(for: fans).modes == [0: .constant(rpm: 6000), 1: .constant(rpm: 5500)])
        #expect(FanProfile.silent(for: []).id == FanProfile.silent(for: fans).id)
        #expect(FanProfile.maximum(for: fans).isBuiltIn)
        #expect(FanProfile.automatic().mode(for: fans[0]) == .automatic)
        #expect(Set([FanProfile.automatic().id, FanProfile.silent(for: fans).id,
                            FanProfile.maximum(for: fans).id]).count == 3)
    }

    @Test func snapshotRoundtrip() throws {
        let snapshot = FanControlSnapshot(fans: fans, currentRPMs: [0: 1210], targetRPMs: [0: 1200],
                                          sensors: [SensorReading(id: "TC0P", name: "CPU", temperature: 50)],
                                          timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(FanControlSnapshot.self, from: data) == snapshot)
    }

    @Test func errorDescriptions() {
        #expect(FanControlError.keyNotFound("F0Ac").errorDescription == "SMC key \"F0Ac\" was not found.")
        #expect(FanControlError.rpmOutOfRange(fan: 0, rpm: 9000, allowed: 1200...6000).localizedDescription == "9000 RPM is outside the allowed range 1200-6000 RPM for fan 0.")
    }
}
