import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// Windowed queries of `TemperatureHistory` (binary search over the ring) agree
/// with a plain filter over every sample, before and after the ring wraps.
@Suite struct TemperatureHistoryQueryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func testWindowedQueriesMatchLinearScan() {
        for capacity in [1, 2, 7, 16] {
            var history = TemperatureHistory(capacityPerKey: capacity)
            var kept: [TemperatureHistory.Sample] = []
            for step in 0..<40 {
                // Repeated timestamps every 5th step (equal dates are kept).
                let date = t0.addingTimeInterval(Double(step - step / 5))
                let temperature = 40 + Double((step * 37) % 23)
                history.append(temperature, for: "agg:cpu", at: date)
                kept.append(.init(date: date, temperature: temperature))
                kept = Array(kept.suffix(capacity))
                #expect(history.history(for: "agg:cpu") == kept)
                let now = date.addingTimeInterval(0.5)
                for window in [0.0, 0.5, 1, 2.5, 3, 10, 1000] {
                    let expected = kept.filter { $0.date >= now.addingTimeInterval(-window) }
                    #expect(history.history(for: "agg:cpu", window: window, now: now) == expected,
                            "capacity \(capacity) step \(step) window \(window)")
                    let temps = expected.map(\.temperature)
                    let range = history.range(for: "agg:cpu", window: window, now: now)
                    #expect(range == (temps.isEmpty ? nil : temps.min()!...temps.max()!))
                    #expect(history.minimum(for: "agg:cpu", window: window, now: now) == temps.min())
                    #expect(history.maximum(for: "agg:cpu", window: window, now: now) == temps.max())
                }
                #expect(history.latest(for: "agg:cpu") == kept.last)
            }
        }
    }

    @Test func testOlderAndNonFiniteSamplesAreDropped() {
        var history = TemperatureHistory(capacityPerKey: 4)
        history.append(50, for: "TH0x", at: t0)
        history.append(51, for: "TH0x", at: t0.addingTimeInterval(-1))
        history.append(.nan, for: "TH0x", at: t0.addingTimeInterval(1))
        history.append(52, for: "TH0x", at: t0)
        #expect(history.history(for: "TH0x").map(\.temperature) == [50, 52])
        #expect(history.range(for: "missing") == nil)
        #expect(history.history(for: "TH0x", window: 10, now: t0.addingTimeInterval(100)).isEmpty)
        #expect(history.range(for: "TH0x", window: 10, now: t0.addingTimeInterval(100)) == nil)
    }

    @Test func testRecordWithNoKeysIsANoOp() {
        var history = TemperatureHistory()
        history.record([SensorReading(id: "agg:cpu", name: "CPU (max)", temperature: 60)], keys: [], at: t0)
        #expect(history.keys.isEmpty)
        history.record([SensorReading(id: "agg:cpu", name: "CPU (max)", temperature: 60)], keys: ["agg:cpu"], at: t0)
        #expect(history.keys == ["agg:cpu"])
    }
}
