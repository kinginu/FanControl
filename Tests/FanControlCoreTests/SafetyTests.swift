import XCTest
@testable import FanControlCore

final class NonFiniteGuardTests: XCTestCase {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 1000, maxRPM: 5000)

    func testNonFiniteThresholdsOrReadingFailLoud() {
        let cases: [(Double, Double, Double?)] = [
            (.nan, 80, 50), (40, .nan, 50), (.infinity, 80, 50), (40, -.infinity, 50),
            (40, 80, .nan), (40, 80, .infinity), (40, 80, -.infinity),
            (.nan, .nan, nil),
        ]
        for (start, maxTemp, reading) in cases {
            let mode = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: start, maxTemperature: maxTemp)
            XCTAssertEqual(FanControlEngine.targetRPM(for: mode, fan: fan, sensorTemperature: reading), 5000,
                           "start=\(start) max=\(maxTemp) reading=\(String(describing: reading))")
        }
        // Finite values are unaffected.
        let ok = FanControlMode.sensor(sensorKey: "Tp09", startTemperature: 40, maxTemperature: 80)
        XCTAssertEqual(FanControlEngine.targetRPM(for: ok, fan: fan, sensorTemperature: 60), 3000)
    }
}

final class EmergencyLatchTests: XCTestCase {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 1000, maxRPM: 5000)
    let policy = SafetyPolicy(emergencyTemperature: 95, alertHysteresis: 5)

    private func cpu(_ t: Double) -> [SensorReading] { [SensorReading(id: "Tp01", name: "CPU", temperature: t)] }

    func testLatchOnOffWithHysteresis() {
        var evaluator = AlertEvaluator()
        XCTAssertFalse(evaluator.isEmergencyActive)
        XCTAssertFalse(evaluator.evaluateEmergency(sensors: cpu(94.9), policy: policy))
        XCTAssertTrue(evaluator.evaluateEmergency(sensors: cpu(95), policy: policy))
        XCTAssertTrue(evaluator.isEmergencyActive)
        // Inside the band: stays on.
        XCTAssertTrue(evaluator.evaluateEmergency(sensors: cpu(92), policy: policy))
        XCTAssertTrue(evaluator.evaluateEmergency(sensors: cpu(90.1), policy: policy))
        // No relevant sensor: state kept.
        XCTAssertTrue(evaluator.evaluateEmergency(sensors: [], policy: policy))
        XCTAssertTrue(evaluator.evaluateEmergency(sensors: [SensorReading(id: "Tp01", name: "CPU", temperature: .nan)],
                                                  policy: policy))
        // Off at threshold - hysteresis.
        XCTAssertFalse(evaluator.evaluateEmergency(sensors: cpu(90), policy: policy))
        XCTAssertFalse(evaluator.isEmergencyActive)
        // Inside the band from below: stays off.
        XCTAssertFalse(evaluator.evaluateEmergency(sensors: cpu(94), policy: policy))
    }

    func testLatchIndependentOfHighTemperatureAlert() {
        var evaluator = AlertEvaluator()
        XCTAssertTrue(evaluator.evaluateHighTemperature(sensors: cpu(91), policy: policy))
        XCTAssertFalse(evaluator.evaluateEmergency(sensors: cpu(91), policy: policy))
    }

    func testPlanUsesLatchedState() {
        let profile = FanProfile(name: "auto")
        // Below threshold but latched on: all fans max.
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: cpu(92), policy: policy,
                                             isEmergency: true)[0], .some(5000))
        // Above threshold but caller says off: profile applies (automatic = nil).
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: cpu(99), policy: policy,
                                             isEmergency: false)[0], .some(nil))
        // nil keeps the stateless behaviour.
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: cpu(99), policy: policy)[0],
                       .some(5000))
        XCTAssertEqual(FanControlEngine.plan(profile: profile, fans: [fan], sensors: cpu(92), policy: policy)[0],
                       .some(nil))
    }
}
