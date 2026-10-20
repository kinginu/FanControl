import Foundation
import Testing
@testable import FanControlCore

/// `FanCurve` (monotone cubic, PCHIP) and its use by `FanProfile` / `FanControlEngine`.
struct FanCurveTests {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800)
    let fan2 = FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)

    @Test func testPassesThroughPointsAndFlatOutside() {
        let curve = FanCurve.boost
        #expect(curve.rpm(at: 0, for: fan) == 2317)
        #expect(curve.rpm(at: 50, for: fan) == 2317)
        #expect(curve.rpm(at: 60, for: fan) == 3500)
        #expect(curve.rpm(at: 70, for: fan) == 5200)
        #expect(curve.rpm(at: 80, for: fan) == 6400)
        #expect(curve.rpm(at: 85, for: fan) == 6800)
        #expect(curve.rpm(at: 120, for: fan) == 6800)
        // Fail loud.
        #expect(curve.rpm(at: .nan, for: fan) == 6800)
        #expect(curve.rpm(at: .infinity, for: fan) == 6800)
    }

    @Test func testMonotoneWithoutOvershoot() {
        // Includes a plateau (60–70 °C flat) where a natural cubic spline would overshoot.
        let curves = [FanCurve.boost,
                      FanCurve([(40, 0), (60, 4000), (70, 4000), (75, 6800)]),
                      FanCurve([(30, 2317), (31, 6800), (90, 6800)])]
        for curve in curves {
            let resolved = curve.resolved(for: fan)
            var previous = -Double.infinity
            for step in 0...1300 {
                let t = Double(step) / 10
                let value = curve.value(at: t, in: fan.rpmRange)
                #expect(value >= previous - 1e-9, "not monotone at \(t) °C")
                previous = value
                // Within the neighbouring points' RPMs.
                if let upper = resolved.points.firstIndex(where: { $0.temperature >= t }), upper > 0 {
                    let lo = Double(min(resolved.points[upper - 1].rpm, resolved.points[upper].rpm))
                    let hi = Double(max(resolved.points[upper - 1].rpm, resolved.points[upper].rpm))
                    #expect(value >= lo - 1e-9 && value <= hi + 1e-9, "overshoot at \(t) °C")
                }
            }
        }
        // The plateau stays flat.
        let plateau = FanCurve([(40, 0), (60, 4000), (70, 4000), (75, 6800)])
        #expect(plateau.rpm(at: 65, for: fan) == 4000)
    }

    @Test func testTwoPointsEqualLegacyRamp() {
        let mode = FanControlMode.sensor(sensorKey: "agg:cpu", startTemperature: 40, maxTemperature: 80)
        let curve = FanCurve.linear(startTemperature: 40, maxTemperature: 80)
        for step in 0...1000 {
            let t = 30 + Double(step) / 16
            let legacy = FanControlEngine.targetRPM(for: mode, fan: fan, sensorTemperature: t)!
            #expect(abs(curve.rpm(at: t, for: fan) - legacy) <= 1, "at \(t) °C")
        }
    }

    @Test func testDegenerateCurves() {
        #expect(FanCurve(points: []).rpm(at: 50, for: fan) == 6800)
        #expect(FanCurve([(50, 3000)]).rpm(at: 10, for: fan) == 3000)
        #expect(FanCurve([(50, 3000)]).rpm(at: 90, for: fan) == 3000)
        // RPMs outside the range are clamped before interpolation.
        #expect(FanCurve([(50, 100), (60, 99_999)]).rpm(at: 55, for: fan) == (2317 + 6800) / 2 + 1)
        // Unsorted / duplicate / non-finite points are normalized.
        let messy = FanCurve([(70, 6800), (.nan, 1), (50, 2317), (50, 3000), (200, 6800)])
        #expect(messy.normalized().points == [FanCurve.Point(temperature: 50, rpm: 3000),
                                              FanCurve.Point(temperature: 70, rpm: 6800),
                                              FanCurve.Point(temperature: 130, rpm: 6800)])
        #expect(messy.startTemperature == 50)
        #expect(messy.endTemperature == 130)
    }

    @Test func testValidation() {
        #expect(FanCurve.boost.isValid())
        #expect(!FanCurve.boost.isValid(rpmRange: fan.rpmRange))  // 0 = "minimum" marker
        #expect(FanCurve.boost.resolved(for: fan).isValid(rpmRange: fan.rpmRange))
        #expect(FanCurve([(50, 3000)]).validationIssues() == [.tooFewPoints])
        let bad = FanCurve([(50, 3000), (40, 3000), (.nan, 1), (140, 7000)])
        #expect(bad.validationIssues(rpmRange: fan.rpmRange)
                == [.notSorted(index: 1), .nonFiniteTemperature(index: 2), .temperatureOutOfRange(index: 3),
                    .rpmOutOfRange(index: 3)])
        #expect(FanCurve([(50, 3000), (50, 4000)]).validationIssues() == [.notSorted(index: 1)])
        #expect(FanCurve([(-1, 3000), (50, 4000)]).validationIssues() == [.temperatureOutOfRange(index: 0)])
    }

    @Test func testSample() {
        let samples = FanCurve.boost.sample(count: 8, rpmRange: fan.rpmRange)
        #expect(samples.first?.temperature == 50)
        #expect(samples.last?.temperature == 85)
        #expect(samples.map(\.temperature) == samples.map(\.temperature).sorted())
        // Every point is included exactly.
        for point in FanCurve.boost.resolved(for: fan).points {
            #expect(samples.contains { $0.temperature == point.temperature && $0.rpm == Double(point.rpm) })
        }
        let wide = FanCurve.boost.sample(count: 101, rpmRange: fan.rpmRange, temperatureDomain: 20...100)
        #expect(wide.count >= 101)
        #expect(wide.first?.rpm == 2317)
        #expect(wide.last?.rpm == 6800)
        #expect(FanCurve(points: []).sample(count: 1).count == 2)
    }

    @Test func testGrid() {
        #expect(FanCurve.gridTemperatures() == [30, 40, 50, 60, 70, 80, 90, 100])
        #expect(FanCurve.gridTemperatures(from: 40, through: 60, step: 10) == [40, 50, 60])
        #expect(FanCurve.gridTemperatures(from: 60, through: 40) == [])
        let grid = FanCurve.boost.resampled(at: FanCurve.gridTemperatures(), rpmRange: fan.rpmRange)
        #expect(grid.points.map(\.temperature) == [30, 40, 50, 60, 70, 80, 90, 100])
        #expect(grid.points.map(\.rpm) == [2317, 2317, 2317, 3500, 5200, 6400, 6800, 6800])
        #expect(grid.isValid(rpmRange: fan.rpmRange))
        for preset in FanCurve.gridPresets {
            let resolved = preset.curve.resolved(for: fan)
            #expect(resolved.isValid(rpmRange: fan.rpmRange), "\(preset)")
            #expect(resolved.points.allSatisfy { $0.temperature.truncatingRemainder(dividingBy: 5) == 0 })
            #expect(resolved.points.map(\.rpm) == resolved.points.map(\.rpm).sorted(), "\(preset) rises")
        }
        #expect(FanCurve.GridPreset.boost.curve == .boost)
    }

    @Test func testMatches() {
        #expect(FanCurve.boost.matches(startTemperature: 50, maxTemperature: 85))
        #expect(FanCurve.boost.matches(startTemperature: 50.04, maxTemperature: 85))
        #expect(!FanCurve.boost.matches(startTemperature: 55, maxTemperature: 85))
        #expect(!FanCurve(points: []).matches(startTemperature: 50, maxTemperature: 85))
    }

    @Test func testCodable() throws {
        let data = try JSONEncoder().encode(FanCurve.boost)
        #expect(try JSONDecoder().decode(FanCurve.self, from: data) == .boost)
    }

    // MARK: FanProfile

    @Test func testProfileCurveSelection() {
        var profile = FanProfile(name: "P", defaultMode: FanProfile.Preset.boostMode,
                                 defaultCurve: FanProfile.Preset.boostCurve)
        #expect(profile.curve(for: fan) == .boost)
        // An explicit mode without a curve entry runs linear (the default curve is for
        // fans without a `modes` entry).
        profile.modes[1] = .sensor(sensorKey: "agg:cpu", startTemperature: 50, maxTemperature: 85)
        #expect(profile.curve(for: fan2) == .linear(startTemperature: 50, maxTemperature: 85))
        // A curve-unaware editor changed the start: the stale curve is ignored.
        profile.curves[1] = .boost
        #expect(profile.curve(for: fan2) == .boost)
        profile.modes[1] = .sensor(sensorKey: "agg:cpu", startTemperature: 55, maxTemperature: 85)
        #expect(profile.curve(for: fan2) == .linear(startTemperature: 55, maxTemperature: 85))
        // Degenerate and non-sensor modes have no curve.
        profile.modes[1] = .sensor(sensorKey: "agg:cpu", startTemperature: 85, maxTemperature: 85)
        #expect(profile.curve(for: fan2) == nil)
        profile.modes[1] = .constant(rpm: 3000)
        #expect(profile.curve(for: fan2) == nil)
        profile.removeStaleCurves()
        #expect(profile.curves.isEmpty)
        #expect(profile.defaultCurve == .boost)
    }

    @Test func testSetCurveAndResolved() {
        var profile = FanProfile(name: "P")
        let curve = FanCurve([(80, 6800), (45, 2400), (60, 4000)])
        profile.setCurve(curve, sensorKey: "agg:gpu", forFan: 1)
        #expect(profile.modes[1] == .sensor(sensorKey: "agg:gpu", startTemperature: 45, maxTemperature: 80))
        #expect(profile.curves[1] == curve.normalized())
        #expect(profile.curve(for: fan2) == curve.normalized())
        profile.setCurve(.boost, sensorKey: "agg:cpu", forFan: nil)
        #expect(profile.defaultMode == FanProfile.Preset.boostMode)
        let resolved = profile.resolved(for: [fan, fan2])
        #expect(resolved.curves == [0: .boost, 1: curve.normalized()])
        #expect(resolved.curve(for: fan) == .boost)
        #expect(FanProfile.automatic().resolved(for: [fan]).curves.isEmpty)
        // Empty curve: ignored.
        var unchanged = profile
        unchanged.setCurve(FanCurve(points: []), sensorKey: "x", forFan: 0)
        #expect(unchanged == profile)
    }

    @Test func testProfileCodableBackwardCompatible() throws {
        var profile = FanProfile.defaultCustom1()
        profile.setCurve(FanCurve([(40, 2500), (70, 6000)]), sensorKey: "agg:gpu", forFan: 1)
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(FanProfile.self, from: data) == profile)
        // JSON written before the curves (no `curves` / `defaultCurve` keys).
        let old = Data("""
        {"id":"6F1A0000-0000-4000-8000-000000000021","name":"Custom 1","isBuiltIn":false,"modes":{}}
        """.utf8)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: old)
        #expect(decoded.curves.isEmpty && decoded.defaultCurve == nil && decoded.modes.isEmpty)
    }

    // MARK: Engine

    @Test func testPlanUsesCurve() {
        var profile = FanProfile(name: "P")
        profile.setCurve(FanCurve([(40, 2317), (60, 3000), (80, 6800)]), sensorKey: "Tp01", forFan: 0)
        profile.modes[1] = .sensor(sensorKey: "Tp01", startTemperature: 40, maxTemperature: 80)
        let sensors = [SensorReading(id: "Tp01", name: "CPU", temperature: 60)]
        let plan = FanControlEngine.plan(profile: profile, fans: [fan, fan2], sensors: sensors, policy: .default,
                                         isEmergency: false)
        #expect(plan[0] == 3000)
        // Fan 2: linear ramp, halfway.
        #expect(plan[1] == 4559)
        #expect(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: 60) == 3000)
        #expect(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: nil) == 6800)
        #expect(FanControlEngine.controlSensorKeys(profile: profile, fans: [fan, fan2]) == ["Tp01"])
        #expect(FanControlEngine.controlSensorKeys(profile: .boost(), fans: []) == ["agg:cpu"])
        #expect(FanControlEngine.controlSensorKeys(profile: .max(), fans: [fan]).isEmpty)
    }
}
