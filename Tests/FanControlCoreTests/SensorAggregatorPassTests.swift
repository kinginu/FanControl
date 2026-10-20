import Testing
@testable import FanControlCore

/// The single-pass `SensorAggregator.aggregates(of:definitions:)` and `appendingAggregates`.
@Suite struct SensorAggregatorPassTests {

    private func reading(_ id: String, _ t: Double) -> SensorReading {
        SensorReading(id: id, name: SensorCatalog.displayName(for: id), temperature: t)
    }

    /// Reference implementation (the former one: filter + max per definition).
    private func reference(_ readings: [SensorReading], _ definitions: [SensorAggregateDefinition]) -> [SensorReading] {
        definitions.compactMap { d in
            let values = readings.filter { d.contains($0.id) && $0.temperature.isFinite }.map(\.temperature)
            guard let m = values.max() else { return nil }
            return SensorReading(id: d.id, name: d.name, temperature: m, sensorType: .greatest)
        }
    }

    @Test func testMatchesReferenceOnMixedInput() {
        let keys = ["Tp00", "Tp01", "Te04", "TCMz", "Tg0f", "Tg1k", "TG0B", "TB0T", "Tf06"]
        var seed: UInt64 = 42
        for round in 0..<200 {
            var readings: [SensorReading] = []
            for key in keys {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r = Double(seed >> 11) / Double(1 << 53)
                if r < 0.1 { continue }
                let t: Double = r < 0.15 ? .nan : r < 0.2 ? -.infinity : r < 0.25 ? .infinity : r * 100
                readings.append(reading(key, t))
            }
            if round % 3 == 0 { readings.append(SensorReading(id: "agg:cpu", name: "x", temperature: 999)) }
            #expect(SensorAggregator.aggregates(of: readings, definitions: SensorAggregator.definitions)
                    == reference(readings, SensorAggregator.definitions), "round \(round)")
        }
    }

    @Test func testEmptyDefinitionsAndEmptyPrefixes() {
        let readings = [reading("Tp00", 50)]
        #expect(SensorAggregator.aggregates(of: readings, definitions: []).isEmpty)
        let odd = SensorAggregateDefinition(id: "agg:odd", name: "Odd", memberPrefixes: ["", "TB"], isOverview: false)
        #expect(SensorAggregator.aggregates(of: readings, definitions: [odd]).isEmpty)
        #expect(SensorAggregator.aggregates(of: readings + [reading("TB0T", 33)], definitions: [odd]).map(\.temperature) == [33])
    }

    @Test func testGroupsInitializer() {
        let byGroups = SensorAggregateDefinition(id: "agg:x", name: "X", groups: [.gpu, .cpuOther], isOverview: true)
        #expect(byGroups == SensorAggregateDefinition(id: "agg:x", name: "X", memberPrefixes: ["Tg", "TC"], isOverview: true))
    }

    @Test func testAppendingReplacesOldAggregatesInPlaceOfOrder() {
        let base = [reading("Tp00", 70), reading("TB0T", 33)]
        let once = SensorAggregator.appendingAggregates(to: base, definitions: SensorAggregator.definitions)
        #expect(once.map(\.id) == ["Tp00", "TB0T", "agg:cpu", "agg:cpu.p"])
        // Aggregates in the input (anywhere) are dropped before recomputing.
        let shuffled = [once[2], once[0], once[3], once[1]]
        #expect(SensorAggregator.appendingAggregates(to: shuffled, definitions: SensorAggregator.definitions) == once)
        #expect(SensorAggregator.appendingAggregates(to: [], definitions: SensorAggregator.definitions).isEmpty)
    }
}
