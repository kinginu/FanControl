import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// `TemperatureHistory` (ring buffer per key) and the manager's history / control-temperature API.
struct TemperatureHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func testDefaultCapacityCoversThirtyMinutesAtTwoSeconds() {
        #expect(TemperatureHistory.defaultCapacityPerKey * 2 >= 30 * 60)
        #expect(TemperatureHistory.defaultKeys == ["agg:cpu", "agg:gpu", "TH0x"])
    }

    @Test func testRingBufferWrapsInOrder() {
        var history = TemperatureHistory(capacityPerKey: 5)
        for i in 0..<12 { history.append(Double(i), for: "agg:cpu", at: at(Double(i) * 2)) }
        let samples = history.history(for: "agg:cpu")
        #expect(samples.map(\.temperature) == [7, 8, 9, 10, 11])
        #expect(samples.map(\.date) == (7..<12).map { at(Double($0) * 2) })
        #expect(history.latest(for: "agg:cpu")?.temperature == 11)
        #expect(history.history(for: "nope").isEmpty)
    }

    @Test func testWindowAndRange() {
        var history = TemperatureHistory()
        let values: [Double] = [50, 72, 61, 58, 66]
        for (i, value) in values.enumerated() { history.append(value, for: "agg:cpu", at: at(Double(i) * 60)) }
        let now = at(240)
        #expect(history.history(for: "agg:cpu", window: 120, now: now).map(\.temperature) == [61, 58, 66])
        #expect(history.range(for: "agg:cpu", window: 120, now: now) == 58...66)
        #expect(history.minimum(for: "agg:cpu", now: now) == 50)
        #expect(history.maximum(for: "agg:cpu", now: now) == 72)
        #expect(history.range(for: "agg:gpu") == nil)
    }

    @Test func testIgnoresBadSamplesAndBoundsKeys() {
        var history = TemperatureHistory(capacityPerKey: 4, maximumKeys: 2)
        history.append(.nan, for: "a", at: at(0))
        #expect(history.keys.isEmpty)
        history.append(50, for: "a", at: at(10))
        history.append(40, for: "a", at: at(5))  // older than the latest: dropped
        #expect(history.history(for: "a").map(\.temperature) == [50])
        history.append(1, for: "b", at: at(0))
        history.append(1, for: "c", at: at(0))  // beyond maximumKeys
        #expect(history.keys == ["a", "b"])
        history.retainOnly(["b"])
        #expect(history.keys == ["b"])
        history.removeAll()
        #expect(history.keys.isEmpty)
    }

    @Test func testRecordFiltersKeys() {
        var history = TemperatureHistory()
        let sensors = [SensorReading(id: "agg:cpu", name: "CPU", temperature: 70, sensorType: .greatest),
                       SensorReading(id: "Tp01", name: "P", temperature: 69)]
        history.record(sensors, keys: ["agg:cpu"], at: at(0))
        #expect(history.keys == ["agg:cpu"])
    }
}

#if os(macOS)
@MainActor
struct TemperatureHistoryManagerTests {
    private func makeManager(_ suite: String) -> FanControlManager {
        FanControlManager(defaults: UserDefaults(suiteName: suite)!,
                          powerSource: MockPowerSource(onBattery: false),
                          conflictDetector: ConflictingControllerDetector(isAppRunning: { _ in false },
                                                                          fileExists: { _ in false }))
    }

    @Test func testHistoryKeySubscriptions() {
        let manager = makeManager("TemperatureHistoryManagerTests.keys")
        #expect(manager.temperatureHistoryKeys == Set(TemperatureHistory.defaultKeys))
        manager.setTemperatureHistoryKeys(["Tp01", "Tg0f"], for: "chart")
        #expect(manager.temperatureHistoryKeys == Set(TemperatureHistory.defaultKeys).union(["Tp01", "Tg0f"]))
        let now = Date()
        manager.recordTemperatureHistory([SensorReading(id: "Tp01", name: "P", temperature: 70),
                                          SensorReading(id: "Tp02", name: "P", temperature: 71),
                                          SensorReading(id: "agg:cpu", name: "CPU", temperature: 72,
                                                        sensorType: .greatest)], at: now)
        #expect(manager.temperatureHistory.keys == ["Tp01", "agg:cpu"])
        // Releasing the subscription drops its buffers, keeps the defaults.
        manager.setTemperatureHistoryKeys([], for: "chart")
        #expect(manager.temperatureHistoryKeys == Set(TemperatureHistory.defaultKeys))
        #expect(manager.temperatureHistory.keys == ["agg:cpu"])
    }

    @Test func testControlTemperatureFallsBackToRaw() {
        let manager = makeManager("TemperatureHistoryManagerTests.control")
        #expect(manager.tuning == .default)
        manager.sensorReadings = [SensorReading(id: "agg:cpu", name: "CPU", temperature: 80, sensorType: .greatest)]
        #expect(manager.controlTemperature(for: "agg:cpu") == 80)
        manager.controlTemperatures = ["agg:cpu": 76.5]
        #expect(manager.controlTemperature(for: "agg:cpu") == 76.5)
        #expect(manager.controlTemperature(for: "nope") == nil)
    }
}
#endif
