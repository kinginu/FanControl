import Foundation

/// One fan reading for `FanStatistics`: time since the window started and the
/// actual (`F<n>Ac`) / target (`F<n>Tg`) RPM, `nil` when that read failed.
public struct FanSample: Hashable, Sendable {
    public var time: TimeInterval
    public var actualRPM: Int?
    public var targetRPM: Int?

    public init(time: TimeInterval, actualRPM: Int?, targetRPM: Int?) {
        self.time = time
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
    }
}

/// PASS/FAIL criteria of the hunting test (`fanfi-probe --fan-stats`).
public struct FanStabilityCriteria: Hashable, Sendable {
    /// Target changes smaller than this are ignored when counting reversals (RPM).
    public var reversalDeadBandRPM: Int = 50
    /// Allowed target reversals per 60 s (at least this many are allowed in any window).
    public var maxReversalsPerMinute: Double = 1
    /// Samples in the first `settleSeconds` are excluded from the tracking check.
    public var settleSeconds: TimeInterval = 5
    /// Maximum |actual − target| for a sample to count as tracking (RPM).
    public var trackingToleranceRPM: Int = 150
    /// Fraction of post-settle samples that must be within the tolerance.
    public var requiredTrackingFraction: Double = 0.95

    public init() {}

    public static let `default` = FanStabilityCriteria()
}

/// Result of `FanStatistics.analyze`.
public struct FanStabilityReport: Hashable, Sendable {
    public var sampleCount: Int
    /// Window length (last sample time − first sample time), seconds.
    public var duration: TimeInterval
    public var actualMin: Int?
    public var actualMax: Int?
    public var actualMean: Double?
    public var targetMin: Int?
    public var targetMax: Int?
    /// Direction changes of the target sequence (dead band `reversalDeadBandRPM`).
    public var targetReversals: Int
    /// Reversals allowed in this window: `max(maxReversalsPerMinute, rate × duration / 60)`.
    public var allowedReversals: Double
    /// Samples after the settle time with both actual and target.
    public var postSettleCount: Int
    /// Largest |actual − target| after the settle time.
    public var maxDeviationAfterSettle: Int?
    /// Fraction of `postSettleCount` within `trackingToleranceRPM`.
    public var trackingFraction: Double?
    /// Why the test failed; empty = PASS.
    public var failureReasons: [String]

    public var passed: Bool { failureReasons.isEmpty }
}

/// Pure statistics for the fan hunting test: is the target stable, and does
/// the actual speed follow it?
public enum FanStatistics {

    /// Number of direction changes in `values`, ignoring moves smaller than
    /// `deadBand`: a reversal is counted when the sequence, after rising (falling)
    /// by at least `deadBand`, falls (rises) by at least `deadBand` from its peak
    /// (trough). Monotonic drift and noise inside the dead band count as 0.
    public static func reversals(_ values: [Int], deadBand: Int) -> Int {
        guard var reference = values.first else { return 0 }
        let band = max(deadBand, 1)
        var direction = 0
        var count = 0
        for value in values.dropFirst() {
            switch direction {
            case 0:
                if abs(value - reference) >= band {
                    direction = value > reference ? 1 : -1
                    reference = value
                }
            case 1:
                if value > reference {
                    reference = value
                } else if reference - value >= band {
                    count += 1
                    direction = -1
                    reference = value
                }
            default:
                if value < reference {
                    reference = value
                } else if value - reference >= band {
                    count += 1
                    direction = 1
                    reference = value
                }
            }
        }
        return count
    }

    /// Statistics and verdict for one fan's samples (in time order).
    public static func analyze(_ samples: [FanSample],
                               criteria: FanStabilityCriteria = .default) -> FanStabilityReport {
        let start = samples.first?.time ?? 0
        let duration = max((samples.last?.time ?? 0) - start, 0)
        let actuals = samples.compactMap(\.actualRPM)
        let targets = samples.compactMap(\.targetRPM)
        let reversalCount = reversals(targets, deadBand: criteria.reversalDeadBandRPM)
        let allowed = max(criteria.maxReversalsPerMinute, criteria.maxReversalsPerMinute * duration / 60)

        let deviations = samples
            .filter { $0.time - start >= criteria.settleSeconds }
            .compactMap { sample -> Int? in
                guard let actual = sample.actualRPM, let target = sample.targetRPM else { return nil }
                return abs(actual - target)
            }
        let within = deviations.filter { $0 <= criteria.trackingToleranceRPM }.count
        let fraction = deviations.isEmpty ? nil : Double(within) / Double(deviations.count)

        var reasons: [String] = []
        if Double(reversalCount) > allowed {
            reasons.append("target hunting: \(reversalCount) reversals in \(Int(duration.rounded())) s "
                           + "(allowed \(formatted(allowed)); dead band \(criteria.reversalDeadBandRPM) RPM)")
        }
        if let fraction {
            if fraction < criteria.requiredTrackingFraction {
                reasons.append("actual does not track target: \(formatted(fraction * 100))% of samples within "
                               + "±\(criteria.trackingToleranceRPM) RPM after \(formatted(criteria.settleSeconds)) s "
                               + "(required \(formatted(criteria.requiredTrackingFraction * 100))%)")
            }
        } else {
            reasons.append("no samples with both actual and target RPM after the \(formatted(criteria.settleSeconds)) s settle time")
        }

        return FanStabilityReport(
            sampleCount: samples.count,
            duration: duration,
            actualMin: actuals.min(),
            actualMax: actuals.max(),
            actualMean: actuals.isEmpty ? nil : Double(actuals.reduce(0, +)) / Double(actuals.count),
            targetMin: targets.min(),
            targetMax: targets.max(),
            targetReversals: reversalCount,
            allowedReversals: allowed,
            postSettleCount: deviations.count,
            maxDeviationAfterSettle: deviations.max(),
            trackingFraction: fraction,
            failureReasons: reasons)
    }

    /// "1", "1.5", "97.3" (at most one decimal, "." separator).
    public static func formatted(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
