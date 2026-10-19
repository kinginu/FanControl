import Foundation
import Testing
@testable import FanControlCore

struct SensorAggregatorTests {

    private let appleSilicon = SensorAggregator.definitions(appleSilicon: true)
    private let intel = SensorAggregator.definitions(appleSilicon: false)

    private func batch(_ values: [(String, Double)]) -> [SensorReading] {
        values.map { SensorReading(id: $0.0, name: SensorCatalog.displayName(for: $0.0), temperature: $0.1) }
    }

    private func temps(_ readings: [SensorReading]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0.temperature) })
    }

    @Test func testTables() {
        #expect(appleSilicon.map(\.id) == ["agg:cpu", "agg:cpu.p", "agg:cpu.e", "agg:gpu"])
        #expect(intel.map(\.id) == appleSilicon.map(\.id))
        #expect(appleSilicon.map(\.memberPrefixes) == [["Tp", "Te", "TC"], ["Tp"], ["Te"], ["Tg"]])
        #expect(intel.map(\.memberPrefixes) == [["Tp", "Te", "TC"], ["Tp"], ["Te"], ["Tg", "TG"]])
        #expect(appleSilicon.filter(\.isOverview).map(\.id) == ["agg:cpu", "agg:gpu"])
        // Members are a subset of the emergency prefixes (same TG split).
        for arch in [true, false] {
            let emergency = Set(SafetyPolicy.defaultEmergencySensorPrefixes(appleSilicon: arch))
            for definition in SensorAggregator.definitions(appleSilicon: arch) {
                #expect(Set(definition.memberPrefixes).isSubset(of: emergency))
                #expect(SMCKey(definition.id) == nil)
                #expect(definition.id.count > 4)
                #expect(SensorAggregator.isAggregate(definition.id))
            }
        }
    }

    /// Mac14,9 shape: TG* is a battery-area sensor (~33 °C) and must not feed GPU.
    @Test func testAppleSiliconValues() {
        let readings = batch([("Tp00", 56.3), ("Tp02", 77.1), ("Te04", 53.1), ("Te06", 62.0),
                              ("TCMz", 70.0), ("Tg0X", 58.5), ("Tg1l", 57.8), ("TG0B", 90.0),
                              ("TB0T", 33.0)])
        let aggregates = SensorAggregator.aggregates(of: readings, definitions: appleSilicon)
        #expect(aggregates.map(\.id) == ["agg:cpu", "agg:cpu.p", "agg:cpu.e", "agg:gpu"])
        #expect(temps(aggregates) == ["agg:cpu": 77.1, "agg:cpu.p": 77.1, "agg:cpu.e": 62.0, "agg:gpu": 58.5])
        #expect(aggregates.allSatisfy { $0.sensorType == .greatest && $0.isAggregate })
        #expect(aggregates.map(\.name) == ["CPU (max)", "CPU Performance Cores (max)",
                                           "CPU Efficiency Cores (max)", "GPU (max)"])
    }

    @Test func testIntelValuesAndEmptyGroupsOmitted() {
        let readings = batch([("TC0P", 61), ("TC0D", 72.5), ("TG0P", 55), ("TG0D", 66), ("TA0P", 30)])
        let aggregates = SensorAggregator.aggregates(of: readings, definitions: intel)
        // No Tp/Te keys on Intel: the P/E aggregates are omitted.
        #expect(temps(aggregates) == ["agg:cpu": 72.5, "agg:gpu": 66])
        // The same readings on the Apple Silicon table: TG is not GPU there.
        #expect(temps(SensorAggregator.aggregates(of: readings, definitions: appleSilicon)) == ["agg:cpu": 72.5])
        // Fanless / no CPU-GPU sensors: nothing.
        #expect(SensorAggregator.aggregates(of: batch([("TB0T", 33)]), definitions: appleSilicon).isEmpty)
        #expect(SensorAggregator.aggregates(of: [], definitions: intel).isEmpty)
    }

    @Test func testNonFiniteMembersIgnored() {
        let readings = batch([("Tp00", .nan), ("Tp01", 50), ("Te04", .infinity), ("Tg0X", .nan)])
        let result = temps(SensorAggregator.aggregates(of: readings, definitions: appleSilicon))
        #expect(result == ["agg:cpu": 50, "agg:cpu.p": 50])
    }

    @Test func testAppendingReplacesStaleAggregatesAndIgnoresThemAsInput() {
        let first = SensorAggregator.appendingAggregates(to: batch([("Tp00", 60)]), definitions: appleSilicon)
        #expect(first.map(\.id) == ["Tp00", "agg:cpu", "agg:cpu.p"])
        var changed = first
        changed[0].temperature = 40
        let second = SensorAggregator.appendingAggregates(to: changed, definitions: appleSilicon)
        #expect(second.map(\.id) == ["Tp00", "agg:cpu", "agg:cpu.p"])
        #expect(temps(second) == ["Tp00": 40, "agg:cpu": 40, "agg:cpu.p": 40])
    }

    /// Aggregates fed from `TemperatureSampleFilter` never see the Mac14,9
    /// gated-cluster pattern, even when every Tp key is bogus for one poll.
    @Test func testFilteredMac14_9PatternDoesNotReachAggregate() {
        var filter = TemperatureSampleFilter()
        let real = batch([("Tp00", 56.31), ("Tp01", 63.01), ("Tp02", 77.13), ("Te04", 53.13)])
        let bogus = batch([("Tp00", 0.00), ("Tp01", 6.70), ("Tp02", 8.43), ("Te04", 53.0)])
        _ = filter.filter(real)
        let unfiltered = temps(SensorAggregator.aggregates(of: bogus, definitions: appleSilicon))
        #expect(unfiltered["agg:cpu.p"] == 8.43) // why filtering first matters
        let filtered = temps(SensorAggregator.aggregates(of: filter.filter(bogus), definitions: appleSilicon))
        #expect(filtered["agg:cpu.p"] == 77.13)
        #expect(filtered["agg:cpu"] == 77.13)

        // Persistent gating without history: the live cluster's maximum wins.
        var fresh = TemperatureSampleFilter()
        let mixed = batch([("Tp00", 0.00), ("Tp01", 6.70), ("Tp02", 8.43),
                           ("Tp0C", 55.9), ("Tp0D", 60.6), ("Tp0E", 69.2)])
        let result = temps(SensorAggregator.aggregates(of: fresh.filter(mixed), definitions: appleSilicon))
        #expect(result["agg:cpu.p"] == 69.2)
    }

    @Test func testOverviewReplacesCoveredKeys() {
        let readings = SensorAggregator.appendingAggregates(
            to: batch([("Tp02", 77.1), ("Te04", 53.1), ("TCMz", 70), ("Tg0X", 58.5),
                       ("TG0B", 33.1), ("TB0T", 33.0), ("TH0x", 38)]),
            definitions: appleSilicon)
        let overview = SensorAggregator.overview(readings, definitions: appleSilicon)
        #expect(overview.map(\.id) == ["agg:cpu", "agg:gpu", "TG0B", "TB0T", "TH0x"])
        // Without aggregates in the input, the overview is the input unchanged.
        let plain = batch([("Tp02", 77.1), ("TB0T", 33.0)])
        #expect(SensorAggregator.overview(plain, definitions: appleSilicon) == plain)
    }

    @Test func testCatalogNames() {
        #expect(SensorCatalog.displayName(for: "agg:cpu") == "CPU (max)")
        #expect(SensorCatalog.displayName(for: "agg:cpu.p") == "CPU Performance Cores (max)")
        #expect(SensorCatalog.displayName(for: "agg:cpu.e") == "CPU Efficiency Cores (max)")
        #expect(SensorCatalog.displayName(for: "agg:gpu") == "GPU (max)")
        #expect(SensorCatalog.displayName(for: "agg:nope") == "Sensor agg:nope")
        // Aggregate names never equal a name an SMC key gets.
        for key in ["Tp00", "Te04", "Tg0X", "TC0P", "TG0D", "TCMz"] {
            #expect(!SensorAggregator.knownNames.values.contains(SensorCatalog.displayName(for: key)))
        }
    }

    @Test func testAggregateReadingCodableRoundTrip() throws {
        let reading = SensorReading(id: "agg:cpu", name: "CPU (max)", temperature: 61.5, sensorType: .greatest)
        let data = try JSONEncoder().encode(reading)
        #expect(String(decoding: data, as: UTF8.self).contains("\"greatest\""))
        #expect(try JSONDecoder().decode(SensorReading.self, from: data) == reading)
    }

    @Test func testEnginePlanWithAggregateKey() {
        let fan = FanDevice(id: 0, name: "Fan 1", minRPM: 1000, maxRPM: 5000)
        let profile = FanProfile(name: "CPU", modes: [
            0: .sensor(sensorKey: SensorAggregator.ID.cpu, startTemperature: 40, maxTemperature: 80),
        ])
        let sensors = SensorAggregator.appendingAggregates(
            to: batch([("Tp00", 45), ("Tp02", 60), ("Te04", 50)]), definitions: appleSilicon)
        let plan = FanControlEngine.plan(profile: profile, fans: [fan], sensors: sensors, policy: .default(appleSilicon: true))
        #expect(plan[0] == .some(3000)) // 60 °C = max member

        // Aggregate missing (no CPU keys): fail hot.
        let missing = FanControlEngine.plan(profile: profile, fans: [fan], sensors: batch([("TB0T", 33)]),
                                            policy: .default(appleSilicon: true))
        #expect(missing[0] == .some(5000))

        // Aggregates do not affect the emergency maximum (ids are not emergency-prefixed).
        let hottest = FanControlEngine.hottestEmergencySensor(sensors, policy: .default(appleSilicon: true))
        #expect(hottest?.id == "Tp02")
    }
}
