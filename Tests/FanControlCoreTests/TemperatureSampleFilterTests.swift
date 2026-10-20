import Foundation
import Testing
@testable import FanControlCore

struct TemperatureSampleFilterTests {

    private func batch(_ values: [(String, Double)]) -> [SensorReading] {
        values.map { SensorReading(id: $0.0, name: SensorCatalog.displayName(for: $0.0), temperature: $0.1) }
    }

    private func temps(_ readings: [SensorReading]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0.temperature) })
    }

    /// The Mac14,9 pattern: each Tp triplet alternates between real values and
    /// a fixed `0.00 / 6.70 / 8.43` (or `0.00 / 4.63 / 5.32`) pattern.
    @Test func testMac14_9AlternatingPatternIsHeld() {
        var filter = TemperatureSampleFilter()
        let real = batch([("Tp00", 56.31), ("Tp01", 63.01), ("Tp02", 77.13),
                          ("Tp0C", 55.92), ("Tp0D", 60.56), ("Tp0E", 69.20), ("Te04", 53.13)])
        let bogus = batch([("Tp00", 0.00), ("Tp01", 6.70), ("Tp02", 8.43),
                           ("Tp0C", 0.00), ("Tp0D", 4.63), ("Tp0E", 5.32), ("Te04", 53.0)])
        #expect(temps(filter.filter(real)) == temps(real))
        #expect(filter.substitutedKeys.isEmpty)
        for _ in 0..<3 {
            let held = temps(filter.filter(bogus))
            #expect(held["Tp00"] == 56.31)
            #expect(held["Tp01"] == 63.01)
            #expect(held["Tp02"] == 77.13)
            #expect(held["Tp0D"] == 60.56)
            #expect(held["Tp0E"] == 69.20)
            #expect(held["Te04"] == 53.0) // plausible: untouched
            #expect(filter.substitutedKeys == ["Tp00", "Tp01", "Tp02", "Tp0C", "Tp0D", "Tp0E"])
            #expect(temps(filter.filter(real)) == temps(real))
            #expect(filter.substitutedKeys.isEmpty)
        }
    }

    @Test func testPreservesOrderNamesAndNonFilteredKeys() {
        var filter = TemperatureSampleFilter()
        _ = filter.filter(batch([("Tp00", 50)]))
        let input = batch([("TH1a", 0), ("Tp00", 0), ("Tz11", 0), ("TB0T", 33)])
        let output = filter.filter(input)
        #expect(output.map(\.id) == input.map(\.id))
        #expect(output.map(\.name) == input.map(\.name))
        #expect(output.map(\.temperature) == [0, 50, 0, 33])
    }

    @Test func testNonFiniteSamplesPassThrough() {
        var filter = TemperatureSampleFilter()
        _ = filter.filter(batch([("Tp00", 50)]))
        let out = filter.filter(batch([("Tp00", .nan), ("Tp01", .infinity)]))
        #expect(out[0].temperature.isNaN)
        #expect(out[1].temperature == .infinity)
        #expect(filter.substitutedKeys.isEmpty)
    }

    @Test func testFallsBackToGroupMaximumWithoutHistory() {
        // Persistent pattern seen on Mac14,9: one gated cluster from the first read.
        var filter = TemperatureSampleFilter()
        let out = temps(filter.filter(batch([("Tp00", 0), ("Tp01", 6.70), ("Tp02", 8.43),
                                             ("Tp1A", 46.24), ("Tp1C", 66.36),
                                             ("Te04", 44.4), ("Tg0f", 49.9)])))
        #expect(out["Tp00"] == 66.36)
        #expect(out["Tp01"] == 66.36)
        #expect(out["Tp02"] == 66.36)
        #expect(out["Tp1A"] == 46.24)
        #expect(out["Te04"] == 44.4)
    }

    @Test func testWholeGroupImplausiblePassesRaw() {
        var filter = TemperatureSampleFilter()
        let input = batch([("Tp00", 0), ("Tp01", 6.70), ("Te04", 45)])
        let out = temps(filter.filter(input))
        #expect(out["Tp00"] == 0)
        #expect(out["Tp01"] == 6.70)
        #expect(filter.substitutedKeys.isEmpty)
    }

    @Test func testStopsHoldingLastValueAfterMaxConsecutiveRejections() {
        var filter = TemperatureSampleFilter(maxConsecutiveSubstitutions: 5)
        _ = filter.filter(batch([("Tp00", 60), ("Tp1A", 45)]))
        for _ in 0..<5 {
            #expect(temps(filter.filter(batch([("Tp00", 0), ("Tp1A", 44)])))["Tp00"] == 60)
        }
        // 6th rejection in a row: last value is stale, use the live group maximum.
        #expect(temps(filter.filter(batch([("Tp00", 0), ("Tp1A", 44)])))["Tp00"] == 44)
        #expect(filter.consecutiveRejections["Tp00"] == 6)
        // ... or the raw sample if nothing in the group is plausible.
        #expect(temps(filter.filter(batch([("Tp00", 0), ("Tp1A", 3)])))["Tp00"] == 0)
        // A plausible sample resets the run.
        _ = filter.filter(batch([("Tp00", 58)]))
        #expect(filter.consecutiveRejections["Tp00"] == nil)
        #expect(temps(filter.filter(batch([("Tp00", 0)])))["Tp00"] == 58)
    }

    @Test func testFloorAndPrefixesAreConfigurable() {
        var filter = TemperatureSampleFilter(floor: 20, filteredPrefixes: ["TH"])
        _ = filter.filter(batch([("TH0a", 38), ("Tp00", 50)]))
        let out = temps(filter.filter(batch([("TH0a", 15), ("Tp00", 0)])))
        #expect(out["TH0a"] == 38)
        #expect(out["Tp00"] == 0)
        #expect(filter.group(of: "TH0a") == "TH")
        #expect(filter.group(of: "Tp00") == nil)
        #expect(TemperatureSampleFilter(filteredPrefixes: ["T", "Tp"]).group(of: "Tp00") == "Tp")
    }

    @Test func testDropsAboveFloorAreNotRejected() {
        var filter = TemperatureSampleFilter()
        _ = filter.filter(batch([("Tp00", 80)]))
        #expect(temps(filter.filter(batch([("Tp00", 40)])))["Tp00"] == 40)
        #expect(temps(filter.filter(batch([("Tp00", 10)])))["Tp00"] == 10)
    }

    @Test func testReset() {
        var filter = TemperatureSampleFilter()
        _ = filter.filter(batch([("Tp00", 60)]))
        _ = filter.filter(batch([("Tp00", 0)]))
        filter.reset()
        #expect(filter.lastAccepted.isEmpty)
        #expect(filter.consecutiveRejections.isEmpty)
        #expect(filter.substitutedKeys.isEmpty)
        #expect(temps(filter.filter(batch([("Tp00", 0)])))["Tp00"] == 0)
    }

    /// End to end with a mock SMC: the sensor-linked mode bound to a flickering
    /// `Tp*` key keeps its speed instead of dropping to the fan minimum.
    @Test func testSensorModeDoesNotDropOnBogusSample() {
        let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800)
        let profile = FanProfile(name: "Sensor",
                                 modes: [0: .sensor(sensorKey: "Tp01", startTemperature: 40, maxTemperature: 80)])
        func reader(_ tp01: Double) -> MockSMCReader {
            MockSMCReader([("Tp00", .flt, Fixtures.flt(56)),
                           ("Tp01", .flt, Fixtures.flt(tp01))])
        }
        var filter = TemperatureSampleFilter()
        let policy = SafetyPolicy.default
        func plan(_ tp01: Double) -> Int? {
            let sensors = filter.filter(SensorCatalog.readTemperatures(keys: ["Tp00", "Tp01"], using: reader(tp01)))
            return FanControlEngine.plan(profile: profile, fans: [fan], sensors: sensors, policy: policy)[0] ?? nil
        }
        let normal = plan(63)
        #expect(normal != nil && normal! > fan.minRPM)
        #expect(plan(6.70) == normal)
        // Unfiltered, the same sample would drive the fan to its minimum.
        let raw = SensorCatalog.readTemperatures(keys: ["Tp01"], using: reader(6.70))
        #expect(FanControlEngine.plan(profile: profile, fans: [fan], sensors: raw, policy: policy)[0] == .some(fan.minRPM))
    }
}

struct SafetyPolicyDefaultsTests {
    /// Apple Silicon only (Intel dropped 2026-10-20): one default list, without `TG`.
    @Test func testDefaultIsTheAppleSiliconList() {
        #expect(SafetyPolicy.defaultEmergencySensorPrefixes == ["Tp", "Te", "TC", "Tg"])
        #expect(SafetyPolicy.default.emergencySensorPrefixes == ["Tp", "Te", "TC", "Tg"])
        #expect(SafetyPolicy().emergencySensorPrefixes == SafetyPolicy.defaultEmergencySensorPrefixes)
        #expect(!SafetyPolicy.default.emergencySensorPrefixes.contains("TG"))
        #expect(SafetyPolicy.default.emergencyTemperature == 95)
        #expect(SafetyPolicy.default.highTemperatureAlert == 90)
        #expect(SafetyPolicy.default.alertHysteresis == 5)
    }

    @Test func testTGBatterySensorsIgnored() {
        let sensors = [SensorReading(id: "TG0B", name: "", temperature: 96),
                       SensorReading(id: "Tg0f", name: "", temperature: 50)]
        #expect(FanControlEngine.hottestEmergencySensor(sensors, policy: .default)?.id == "Tg0f")
    }

    @Test func testCodableRoundTripIncludingLegacyPayload() throws {
        let policy = SafetyPolicy.default
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(SafetyPolicy.self, from: data) == policy)
        // A payload encoded with the old architecture-neutral default (with TG)
        // still decodes, keeping its stored prefixes.
        let legacy = Data("""
            {"emergencyTemperature":95,"emergencySensorPrefixes":["Tp","Te","TC","Tg","TG"],
             "highTemperatureAlert":90,"alertHysteresis":5,"enforceHardwareMinimum":true}
            """.utf8)
        var expected = SafetyPolicy.default
        expected.emergencySensorPrefixes = ["Tp", "Te", "TC", "Tg", "TG"]
        #expect(try JSONDecoder().decode(SafetyPolicy.self, from: legacy) == expected)
    }
}
