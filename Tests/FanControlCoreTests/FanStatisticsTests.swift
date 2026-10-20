import Foundation
import Testing
@testable import FanControlCore

/// `FanStatistics` (hunting test of `fanfi-probe --fan-stats`), synthetic 1-Hz sequences.
@Suite("Fan statistics", .tags(.control))
struct FanStatisticsTests {

    private func samples(_ seconds: Int, actual: (Int) -> Int?, target: (Int) -> Int?) -> [FanSample] {
        (0..<seconds).map { FanSample(time: TimeInterval($0), actualRPM: actual($0), targetRPM: target($0)) }
    }

    @Test func reversalsIgnoreDeadBandAndDrift() {
        #expect(FanStatistics.reversals([], deadBand: 50) == 0)
        #expect(FanStatistics.reversals([3000, 3020, 2990, 3040, 3000], deadBand: 50) == 0)   // noise
        #expect(FanStatistics.reversals(Array(stride(from: 2400, through: 4000, by: 20)), deadBand: 50) == 0)  // drift
        #expect(FanStatistics.reversals([3000, 3100, 3000, 3100, 3000], deadBand: 50) == 3)
        #expect(FanStatistics.reversals([3000, 3100, 3060, 3200], deadBand: 50) == 0)   // dip < dead band
        #expect(FanStatistics.reversals([3000, 3100, 3050, 3200], deadBand: 50) == 2)   // dip = dead band
    }

    @Test func steadyPasses() {
        let report = FanStatistics.analyze(samples(120, actual: { 3000 + ($0 % 3) * 20 - 20 }, target: { _ in 3000 }))
        #expect(report.passed)
        #expect(report.targetReversals == 0)
        #expect(report.targetMin == 3000 && report.targetMax == 3000)
        #expect(report.actualMin == 2980 && report.actualMax == 3020)
        #expect(abs((report.actualMean ?? 0) - 3000) < 1)
        #expect(report.maxDeviationAfterSettle == 20)
        #expect(report.postSettleCount == 115)
        #expect(report.duration == 119)
    }

    @Test func settleTimeIsExcluded() {
        // Spinning up from 0 during the first 5 s does not count against tracking.
        let report = FanStatistics.analyze(samples(60, actual: { $0 < 5 ? $0 * 600 : 3000 }, target: { _ in 3000 }))
        #expect(report.passed)
        #expect(report.maxDeviationAfterSettle == 0)
    }

    @Test func huntingFails() {
        // Target oscillates 2800 ↔ 3400 with a 20-s period: 11 level changes = 10 reversals in 119 s (allowed ~2).
        let target: (Int) -> Int? = { ($0 / 10) % 2 == 0 ? 2800 : 3400 }
        let report = FanStatistics.analyze(samples(120, actual: target, target: target))
        #expect(!report.passed)
        #expect(report.targetReversals == 10)
        #expect(report.failureReasons.count == 1)
        #expect(report.failureReasons.first?.hasPrefix("target hunting") == true)
    }

    @Test func oneReversalPerMinuteIsAllowed() {
        // A single step is not a reversal; a short window (20 s) still allows 1 reversal.
        let report = FanStatistics.analyze(samples(121, actual: { _ in nil }, target: { $0 < 60 ? 3000 : 3300 }))
        #expect(report.targetReversals == 0)
        let one = FanStatistics.analyze(samples(20, actual: { _ in 3000 }, target: { $0 < 3 ? 3000 : ($0 < 10 ? 3300 : 3000) }))
        #expect(one.targetReversals == 1)
        #expect(one.allowedReversals == 1)
        #expect(one.failureReasons.allSatisfy { !$0.hasPrefix("target hunting") })
    }

    @Test func driftingActualFails() {
        // Stable target, actual drifts 10 RPM/s away from it: beyond ±150 after ~15 s.
        let report = FanStatistics.analyze(samples(120, actual: { 3000 + $0 * 10 }, target: { _ in 3000 }))
        #expect(report.targetReversals == 0)
        #expect(!report.passed)
        #expect(report.maxDeviationAfterSettle == 1190)
        #expect(report.failureReasons.first?.hasPrefix("actual does not track target") == true)
        #expect((report.trackingFraction ?? 1) < 0.95)
    }

    @Test func noUsableSamplesFails() {
        let report = FanStatistics.analyze(samples(10, actual: { _ in nil }, target: { _ in 3000 }))
        #expect(!report.passed)
        #expect(report.actualMean == nil)
        #expect(report.trackingFraction == nil)
        #expect(FanStatistics.analyze([]).passed == false)
    }
}
