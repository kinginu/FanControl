import Foundation
import Testing
@testable import FanControlCore

/// Edge cases of `FanCurve`: PCHIP shape preservation on many point sets, normalization,
/// clamping, sampling and the grid helpers.
struct FanCurveEdgeCaseTests {
    let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800)

    /// Deterministic pseudo-random generator (SplitMix64) so failures are reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Random curves with strictly increasing temperatures and RPMs that are
    /// non-decreasing (`increasing == true`) or arbitrary.
    func randomCurves(count: Int, increasing: Bool, seed: UInt64) -> [FanCurve] {
        var rng = SplitMix64(state: seed)
        return (0..<count).map { _ in
            let n = Int.random(in: 2...8, using: &rng)
            var t = Double.random(in: 0...40, using: &rng)
            var rpm = Int.random(in: 0...3000, using: &rng)
            var points: [(temperature: Double, rpm: Int)] = []
            for _ in 0..<n {
                points.append((t, rpm))
                t += Double.random(in: 0.5...20, using: &rng)
                if increasing {
                    // Plateaus included on purpose (where unconstrained splines overshoot).
                    rpm += Bool.random(using: &rng) ? 0 : Int.random(in: 1...2000, using: &rng)
                } else {
                    rpm = Int.random(in: 0...8000, using: &rng)
                }
            }
            return FanCurve(points)
        }
    }

    // MARK: PCHIP

    @Test func testMonotoneDataGivesMonotoneCurve() {
        for curve in randomCurves(count: 100, increasing: true, seed: 1) {
            let samples = curve.sample(count: 200)
            for (a, b) in zip(samples, samples.dropFirst()) {
                #expect(b.rpm >= a.rpm - 1e-9, "curve \(curve.points) decreases at \(b.temperature)")
            }
        }
    }

    @Test func testDecreasingDataGivesNonIncreasingCurve() {
        let curve = FanCurve([(30, 6000), (40, 6000), (55, 3000), (70, 2900), (90, 0)])
        let samples = curve.sample(count: 300)
        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(b.rpm <= a.rpm + 1e-9)
        }
    }

    /// Between two points the curve stays inside their RPMs, for any data (no overshoot).
    @Test func testNoOvershootBetweenPoints() {
        for curve in randomCurves(count: 100, increasing: false, seed: 2) {
            let points = curve.normalized().points
            for (a, b) in zip(points, points.dropFirst()) {
                let low = Double(min(a.rpm, b.rpm)), high = Double(max(a.rpm, b.rpm))
                for step in 1..<10 {
                    let t = a.temperature + (b.temperature - a.temperature) * Double(step) / 10
                    let v = curve.value(at: t, in: nil)
                    #expect(v >= low - 1e-6 && v <= high + 1e-6,
                            "\(v) outside \(low)…\(high) at \(t) for \(points)")
                }
            }
        }
    }

    /// A peak is a local maximum of the curve (interior slope 0 at an extremum).
    @Test func testLocalExtremumIsFlat() {
        let curve = FanCurve([(40, 2000), (60, 5000), (80, 2000)])
        #expect(curve.value(at: 60, in: nil) == 5000)
        #expect(curve.value(at: 59.5, in: nil) < 5000)
        #expect(curve.value(at: 60.5, in: nil) < 5000)
    }

    @Test func testPassesThroughEveryPoint() {
        for curve in randomCurves(count: 50, increasing: false, seed: 3) {
            for point in curve.normalized().points {
                #expect(abs(curve.value(at: point.temperature, in: nil) - Double(point.rpm)) < 1e-6)
            }
        }
    }

    // MARK: Normalization

    @Test func testNormalizationSortsDropsAndClamps() {
        let curve = FanCurve(points: [
            .init(temperature: 80, rpm: 6000),
            .init(temperature: .nan, rpm: 1),
            .init(temperature: -20, rpm: 1000),
            .init(temperature: 200, rpm: 7000),
            .init(temperature: 50, rpm: 3000),
            .init(temperature: 50, rpm: 3500),
            .init(temperature: .infinity, rpm: 2),
        ])
        let points = curve.normalized().points
        #expect(points.map(\.temperature) == [0, 50, 80, 130])
        // Later duplicate wins; clamped temperatures keep their RPM.
        #expect(points.map(\.rpm) == [1000, 3500, 6000, 7000])
        #expect(curve.startTemperature == 0)
        #expect(curve.endTemperature == 130)
        // Normalization is idempotent.
        #expect(curve.normalized().normalized() == curve.normalized())
    }

    @Test func testEmptyAndSinglePoint() {
        let empty = FanCurve(points: [])
        #expect(empty.rpm(at: 60, for: fan) == fan.maxRPM)
        #expect(empty.value(at: 60, in: nil) == Double(FanCurve.fanMaximumRPM))
        #expect(empty.startTemperature == nil && empty.endTemperature == nil)
        #expect(!empty.matches(startTemperature: 0, maxTemperature: 0))

        let single = FanCurve([(60, 4000)])
        #expect(single.rpm(at: 0, for: fan) == 4000)
        #expect(single.rpm(at: 120, for: fan) == 4000)
        #expect(FanCurve([(60, 100)]).rpm(at: 60, for: fan) == fan.minRPM)
        #expect(FanCurve([(60, 99_999)]).rpm(at: 60, for: fan) == fan.maxRPM)
    }

    // MARK: Clamping

    @Test func testResultAlwaysInsideFanRange() {
        for curve in randomCurves(count: 100, increasing: false, seed: 4) {
            for t in stride(from: -10.0, through: 140, by: 2.5) {
                #expect(fan.rpmRange.contains(curve.rpm(at: t, for: fan)))
                let v = curve.value(at: t, in: fan.rpmRange)
                #expect(v >= Double(fan.minRPM) && v <= Double(fan.maxRPM))
            }
        }
        let wild = FanCurve([(40, -5000), (90, 1_000_000)])
        #expect(wild.rpm(at: 0, for: fan) == fan.minRPM)
        #expect(wild.rpm(at: 100, for: fan) == fan.maxRPM)
        #expect(wild.resolved(for: fan).points.map(\.rpm) == [fan.minRPM, fan.maxRPM])
    }

    @Test func testInvertedFanRangeIsNormalized() {
        let inverted = FanDevice(id: 2, name: "Odd", minRPM: 6000, maxRPM: 2000)
        #expect(inverted.rpmRange == 2000...6000)
        #expect(FanCurve.boost.rpm(at: 0, for: inverted) == 2000)
        #expect(FanCurve.boost.rpm(at: 100, for: inverted) == 6000)
    }

    // MARK: Sampling

    /// `sample` evaluates exactly like `value(at:in:)`.
    @Test func testSampleAgreesWithValue() {
        for curve in randomCurves(count: 30, increasing: false, seed: 5) {
            for range in [nil, fan.rpmRange] as [ClosedRange<Int>?] {
                let samples = curve.sample(count: 37, rpmRange: range)
                #expect(samples.count >= 37)
                #expect(samples.map(\.temperature) == samples.map(\.temperature).sorted())
                #expect(Set(samples.map(\.temperature)).count == samples.count)
                for sample in samples {
                    #expect(sample.rpm == curve.value(at: sample.temperature, in: range))
                }
            }
        }
    }

    @Test func testSampleDomainAndMinimumCount() {
        let curve = FanCurve([(40, 2000), (60, 3000), (80, 6000)])
        let samples = curve.sample(count: 0)
        // At least the two domain ends, plus the interior point.
        #expect(samples.map(\.temperature) == [40, 60, 80])
        let wide = curve.sample(count: 3, temperatureDomain: 0...130)
        #expect(wide.first?.temperature == 0 && wide.last?.temperature == 130)
        #expect(wide.first?.rpm == 2000 && wide.last?.rpm == 6000)
        // A one-point curve spans the whole temperature range.
        #expect(FanCurve([(50, 1000)]).sample(count: 2).map(\.temperature) == [0, 50, 130])
    }

    // MARK: Matching and grid

    @Test func testMatchTolerance() {
        let curve = FanCurve([(50, 0), (85, 6800)])
        #expect(curve.matches(startTemperature: 50.05, maxTemperature: 84.95))
        #expect(!curve.matches(startTemperature: 50.06, maxTemperature: 85))
        #expect(!curve.matches(startTemperature: 50, maxTemperature: 85.06))
        // Matching uses the normalized form (unsorted input still matches).
        #expect(FanCurve([(85, 6800), (50, 0)]).matches(startTemperature: 50, maxTemperature: 85))
    }

    @Test func testGridTemperaturesEdgeCases() {
        #expect(FanCurve.gridTemperatures() == [30, 40, 50, 60, 70, 80, 90, 100])
        #expect(FanCurve.gridTemperatures(from: 50, through: 50) == [50])
        #expect(FanCurve.gridTemperatures(from: 60, through: 50).isEmpty)
        #expect(FanCurve.gridTemperatures(step: 0).isEmpty)
        #expect(FanCurve.gridTemperatures(step: -10).isEmpty)
        #expect(FanCurve.gridTemperatures(from: .nan).isEmpty)
    }

    @Test func testResampledRoundsAndClamps() {
        let curve = FanCurve.boost.resampled(at: [100, .nan, 30, 65], rpmRange: fan.rpmRange, rpmStep: 100)
        #expect(curve.points.map(\.temperature) == [30, 65, 100])
        #expect(curve.points.allSatisfy { $0.rpm % 100 == 0 || $0.rpm == fan.minRPM || $0.rpm == fan.maxRPM })
        #expect(curve.points.allSatisfy { fan.rpmRange.contains($0.rpm) })
        #expect(curve.points.first?.rpm == fan.minRPM)
        #expect(curve.points.last?.rpm == fan.maxRPM)
        // A step below 1 is treated as 1.
        let fine = FanCurve.boost.resampled(at: [65], rpmRange: fan.rpmRange, rpmStep: 0)
        #expect(fine.points.first?.rpm == FanCurve.boost.rpm(at: 65, for: fan))
    }

    // MARK: Validation

    @Test func testValidationIssueIndices() {
        let curve = FanCurve(points: [
            .init(temperature: 50, rpm: 3000),
            .init(temperature: .nan, rpm: 3000),
            .init(temperature: 40, rpm: 3000),
            .init(temperature: 140, rpm: 9000),
        ])
        let issues = curve.validationIssues(rpmRange: fan.rpmRange)
        #expect(issues.contains(.nonFiniteTemperature(index: 1)))
        // Index 2 follows a non-finite point, so it is not compared with it.
        #expect(!issues.contains(.notSorted(index: 2)))
        #expect(issues.contains(.temperatureOutOfRange(index: 3)))
        #expect(issues.contains(.rpmOutOfRange(index: 3)))
        #expect(!issues.contains(.tooFewPoints))
        #expect(FanCurve([(50, 3000)]).validationIssues() == [.tooFewPoints])
        #expect(FanCurve(points: []).validationIssues() == [.tooFewPoints])
    }
}
