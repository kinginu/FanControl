import Foundation
import FanControlCore

/// Shared values of the Kit tests (Mac14,9 / M2 Pro, `docs/verification/Mac14,9-macOS26-dump.txt`).
enum Fixtures {
    /// The two fans of the Mac14,9: 2317...6800 RPM.
    static let mac14_9Fans = [FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
                              FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)]
}

/// Fixed wall-clock time for code that takes `now:` / `at:` (never `Date()` in assertions).
enum TestClock {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// `t0` plus `seconds`.
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}
