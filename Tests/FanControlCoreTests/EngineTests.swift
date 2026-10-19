import XCTest
@testable import FanControlCore

final class FanControlEngineTests: XCTestCase {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 1000, maxRPM: 5000)
    let fan2 = FanDevice(id: 1, name: "Fan 2", minRPM: 1200, maxRPM: 6000)
    let sensorMode = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: 40, maxTemperature: 80)

    func testAutomaticIsNil() {
        XCTAssertNil(FanControlEngine.targetRPM(for: .automatic, fan: fan, sensorTemperature: 99))
        XCTAssertFalse(FanControlMode.automatic.isManual)
        XCTAssertTrue(FanControlMode.constant(rpm: 1).isManual)
        XCTAssertTrue(sensorMode.isManual)
    }

    func testConstantClamped() {
        XCTAssertEqual(FanControlEngine.targetRPM(for: .constant(rpm: 3000), fan: fan, sensorTemperature: nil), 3000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: .constant(rpm: 10), fan: fan, sensorTemperature: nil), 1000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: .constant(rpm: 9000), fan: fan, sensorTemperature: nil), 5000)
        XCTAssertEqual(FanControlEngine.clamp(-5, to: fan), 1000)
    }

    func testSensorInterpolation() {
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 20), 1000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 40), 1000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 60), 3000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 70), 4000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 80), 5000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: 120), 5000)
    }

    func testSensorMissingFailsLoud() {
        XCTAssertEqual(FanControlEngine.targetRPM(for: sensorMode, fan: fan, sensorTemperature: nil), 5000)
    }

    func testSensorStepFunction() {
        let step = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: 70, maxTemperature: 70)
        XCTAssertEqual(FanControlEngine.targetRPM(for: step, fan: fan, sensorTemperature: 69.9), 1000)
        XCTAssertEqual(FanControlEngine.targetRPM(for: step, fan: fan, sensorTemperature: 70), 5000)
    }

    func testPlan() {
        let profile = FanProfile(name: "Custom", modes: [0: sensorMode])
        let sensors = [SensorReading(id: "Tp09", name: "P", temperature: 60, sensorType: .smc)]
        let plan = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: sensors, policy: .default)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0], .some(3000))
        XCTAssertEqual(plan[1], .some(nil))
    }

    func testPlanSensorMissingGoesToMax() {
        let profile = FanProfile(name: "Custom", modes: [0: sensorMode])
        let plan = FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: .default)
        XCTAssertEqual(plan[0], .some(5000))
    }

    func testEmergencyOverride() {
        let profile = FanProfile(name: "Custom", modes: [0: .constant(rpm: 1000)])
        let sensors = [
            SensorReading(id: "TB0T", name: "Battery", temperature: 99, sensorType: .smc), // not an emergency prefix
            SensorReading(id: "Tp01", name: "P", temperature: 96, sensorType: .smc),
        ]
        let plan = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: sensors, policy: .default)
        XCTAssertEqual(plan[0], .some(5000))
        XCTAssertEqual(plan[1], .some(6000))
        XCTAssertEqual(FanControlEngine.hottestEmergencySensor(sensors, policy: .default)?.id, "Tp01")

        let cool = [SensorReading(id: "TB0T", name: "Battery", temperature: 99, sensorType: .smc)]
        let normal = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: cool, policy: .default)
        XCTAssertEqual(normal[0], .some(1000))
        XCTAssertEqual(normal[1], .some(nil))
    }

    func testEnforceHardwareMinimumOff() {
        var policy = SafetyPolicy.default
        policy.enforceHardwareMinimum = false
        let profile = FanProfile(name: "Zero", modes: [0: .constant(rpm: 0)])
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: policy)[0], .some(0))
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: [], policy: .default)[0], .some(1000))
    }
}

final class AlertEvaluatorTests: XCTestCase {
    func reading(_ t: Double) -> [SensorReading] {
        [SensorReading(id: "TC0P", name: "CPU", temperature: t, sensorType: .smc)]
    }

    func testHysteresis() {
        var evaluator = AlertEvaluator()
        let policy = SafetyPolicy.default // alert 90, hysteresis 5
        XCTAssertFalse(evaluator.evaluateHighTemperature(sensors: reading(80), policy: policy))
        XCTAssertFalse(evaluator.evaluateHighTemperature(sensors: reading(89.9), policy: policy))
        XCTAssertTrue(evaluator.evaluateHighTemperature(sensors: reading(90), policy: policy))
        XCTAssertTrue(evaluator.evaluateHighTemperature(sensors: reading(87), policy: policy))
        XCTAssertTrue(evaluator.evaluateHighTemperature(sensors: [], policy: policy))
        XCTAssertFalse(evaluator.evaluateHighTemperature(sensors: reading(85), policy: policy))
        XCTAssertFalse(evaluator.evaluateHighTemperature(sensors: reading(88), policy: policy))
    }

    func testFanAnomaly() {
        var evaluator = AlertEvaluator()
        let fans = [FanDevice(id: 0, name: "A", minRPM: 1000, maxRPM: 5000),
                    FanDevice(id: 1, name: "B", minRPM: 1000, maxRPM: 5000)]
        let stalled = [0: 0, 1: 2000]
        let targets = [0: 2000, 1: 2000]
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets), [])
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets), [])
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets), [0])
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets), [0])
        // Recovery resets the counter.
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: [0: 1500, 1: 2000], targetRPMs: targets), [])
        XCTAssertEqual(evaluator.evaluateFanAnomaly(fans: fans, currentRPMs: stalled, targetRPMs: targets), [])
        // Target 0 is not an anomaly.
        var other = AlertEvaluator()
        for _ in 0..<5 {
            XCTAssertEqual(other.evaluateFanAnomaly(fans: fans, currentRPMs: [0: 0, 1: 0], targetRPMs: [0: 0],
                                                    consecutiveLimit: 1), [])
        }
    }
}

final class PersistenceTests: XCTestCase {
    let fans = [FanDevice(id: 0, name: "A", minRPM: 1200, maxRPM: 6000),
                FanDevice(id: 1, name: "B", minRPM: 1300, maxRPM: 5500)]

    func testModeCodableRoundtrip() throws {
        let modes: [FanControlMode] = [
            .automatic, .constant(rpm: 2500),
            .sensor(sensorKey: "Tp09", startTemperature: 45.5, maxTemperature: 85),
        ]
        let data = try JSONEncoder().encode(modes)
        XCTAssertEqual(try JSONDecoder().decode([FanControlMode].self, from: data), modes)
    }

    func testBuiltInProfiles() {
        XCTAssertEqual(FanProfile.automatic().id, FanProfile.automatic().id)
        XCTAssertEqual(FanProfile.silent(for: fans).modes, [0: .constant(rpm: 1200), 1: .constant(rpm: 1300)])
        XCTAssertEqual(FanProfile.maximum(for: fans).modes, [0: .constant(rpm: 6000), 1: .constant(rpm: 5500)])
        XCTAssertEqual(FanProfile.silent(for: []).id, FanProfile.silent(for: fans).id)
        XCTAssertTrue(FanProfile.maximum(for: fans).isBuiltIn)
        XCTAssertEqual(FanProfile.automatic().mode(for: fans[0]), .automatic)
        XCTAssertEqual(Set([FanProfile.automatic().id, FanProfile.silent(for: fans).id,
                            FanProfile.maximum(for: fans).id]).count, 3)
    }

    func testProfileStore() throws {
        let custom = FanProfile(name: "Custom", modes: [
            0: .sensor(sensorKey: "TC0P", startTemperature: 50, maxTemperature: 90),
            1: .constant(rpm: 3000),
        ])
        var store = ProfileStore(profiles: [.automatic(), .silent(for: fans)])
        store.upsert(custom)
        store.activeProfileID = custom.id
        XCTAssertEqual(store.activeProfile, custom)

        var renamed = custom
        renamed.name = "Renamed"
        store.upsert(renamed)
        XCTAssertEqual(store.profiles.count, 3)
        XCTAssertEqual(store.activeProfile?.name, "Renamed")

        let data = try ProfileStore.encodeJSON(store)
        XCTAssertEqual(try ProfileStore.decodeJSON(data), store)

        XCTAssertFalse(store.delete(id: FanProfile.BuiltInID.automatic))
        XCTAssertTrue(store.delete(id: custom.id))
        XCTAssertNil(store.activeProfileID)
        XCTAssertNil(store.activeProfile)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertFalse(store.delete(id: UUID()))
    }

    func testSnapshotRoundtrip() throws {
        let snapshot = FanControlSnapshot(fans: fans, currentRPMs: [0: 1210], targetRPMs: [0: 1200],
                                          sensors: [SensorReading(id: "TC0P", name: "CPU", temperature: 50)],
                                          timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(FanControlSnapshot.self, from: data), snapshot)
    }

    func testErrorDescriptions() {
        XCTAssertEqual(FanControlError.keyNotFound("F0Ac").errorDescription, "SMC key \"F0Ac\" was not found.")
        XCTAssertEqual(FanControlError.rpmOutOfRange(fan: 0, rpm: 9000, allowed: 1200...6000).localizedDescription,
                       "9000 RPM is outside the allowed range 1200-6000 RPM for fan 0.")
    }
}
