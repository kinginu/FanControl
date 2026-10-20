// `--fan-stats N` sampling: reads actual/target RPM at a fixed interval and
// analyses each fan with `FanStatistics`. Read-only like the rest of the probe.

#if os(macOS)
import Foundation
import FanControlCore

/// The outcome of a `--fan-stats` window.
struct FanStatsResult {
    var windowSeconds: Double
    var intervalSeconds: Double
    var criteria: FanStabilityCriteria
    /// Samples per fan, keyed by `FanDevice.id`.
    var samples: [Int: [FanSample]]
    /// One report per fan, in discovery order.
    var reports: [(fan: FanDevice, report: FanStabilityReport)]

    /// Every fan passed, and there was at least one fan.
    var passed: Bool { !reports.isEmpty && reports.allSatisfy(\.report.passed) }
}

enum FanStatsRunner {
    /// Samples for `seconds` every `interval` seconds; `onSample` is called after each sample.
    static func run(session: ProbeSession, seconds: Double, interval: Double,
                    criteria: FanStabilityCriteria = .default,
                    onSample: (_ elapsed: TimeInterval, _ current: [Int: Int], _ target: [Int: Int]) -> Void) -> FanStatsResult {
        var samples: [Int: [FanSample]] = [:]
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            let (current, target) = session.fanSpeeds()
            for fan in session.fans {
                samples[fan.id, default: []].append(FanSample(time: elapsed, actualRPM: current[fan.id], targetRPM: target[fan.id]))
            }
            onSample(elapsed, current, target)
            if elapsed + interval > seconds + 0.001 { break }
            Thread.sleep(forTimeInterval: interval)
        }
        let reports = session.fans.map { fan in
            (fan: fan, report: FanStatistics.analyze(samples[fan.id] ?? [], criteria: criteria))
        }
        return FanStatsResult(windowSeconds: seconds, intervalSeconds: interval, criteria: criteria,
                              samples: samples, reports: reports)
    }
}
#endif
