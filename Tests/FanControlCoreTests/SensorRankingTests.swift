import Foundation
import Testing
@testable import FanControlCore

/// Non-thermal / unreliable keys (`SensorCatalog.isExcludedFromRanking`) and the
/// automatic "hottest sensors" selection (`SensorAggregator.hottestOverview`).
@Suite("Sensor ranking", .tags(.sensors))
struct SensorRankingTests {

    private let appleSilicon = SensorAggregator.definitions

    private func batch(_ values: [(String, Double)]) -> [SensorReading] {
        values.map { SensorReading(id: $0.0, name: SensorCatalog.displayName(for: $0.0), temperature: $0.1) }
    }

    /// A Mac14,9-like snapshot (values from `fanfi-probe`, 2026-10-20): the
    /// `Tf*` constants are the largest values, then real CPU/GPU sensors.
    private var mac14_9Snapshot: [SensorReading] {
        batch([
            ("Tf06", 105.31), ("Tf16", 93.08), ("Tf26", 88.81), ("Tf04", 57.42), ("Tf02", -12.23),
            ("Ta0D", 9.50), ("Ta0V", 0), ("TH1a", 0), ("TVMD", 0), ("Tz11", 0),
            ("Tp1K", 75.0), ("Tp0C", 66.3), ("Te04", 53.1), ("TCMz", 75.0),
            ("Tg0X", 58.5), ("Tg1g", 56.0),
            ("TG0B", 33.1), ("TB0T", 33.0), ("TH0x", 38.0), ("TW0P", 45.0), ("TaLP", 44.0),
        ])
    }

    @Test func exclusionTable() {
        #expect(SensorCatalog.rankingExcludedPrefixes == ["Tf"])
        for key in ["Tf00", "Tf02", "Tf06", "Tf16", "Tf26", "Tf04", "Tf2E",
                    "TH1a", "TH1b", "TVMD", "Ta0C", "Ta0D", "Ta0G", "Ta0H", "Ta0K", "Ta0L", "Ta0V",
                    "Tz11", "Tz18", "Tz1j"] {
            #expect(SensorCatalog.isExcludedFromRanking(key), "\(key)")
        }
        // Real sensors, near misses and aggregates stay rankable.
        for key in ["Tp1K", "Te04", "TCMz", "Tg0X", "TG0B", "TB0T", "TH0x", "TH0a", "TW0P",
                    "TaLP", "Ta0W", "TVM0", "TVMC", "Ts0P", "TF06", "Tz1k", "TC0P", "TG0D",
                    "agg:cpu", "agg:gpu", "agg:cpu.p", "agg:cpu.e"] {
            #expect(!SensorCatalog.isExcludedFromRanking(key), "\(key)")
        }
        #expect(SensorReading(id: "Tf06", name: "x", temperature: 1).isExcludedFromRanking)
        for key in SensorCatalog.rankingExcludedKeys {
            let smcKey: SMCKey? = SMCKey(key)
            #expect(smcKey != nil, "\(key)")
        }
    }

    @Test func exclusionOnMac14_9Keys() {
        let excluded = SensorCatalogTests.mac14_9Keys.filter(SensorCatalog.isExcludedFromRanking)
        // Every exact key exists on Mac14,9; 33 Tf* + 19 exact keys.
        #expect(SensorCatalog.rankingExcludedKeys.isSubset(of: Set(SensorCatalogTests.mac14_9Keys)))
        #expect(excluded.filter { $0.hasPrefix("Tf") }.count == 33)
        #expect(excluded.count == 33 + SensorCatalog.rankingExcludedKeys.count)
    }

    @Test func aggregatesAndEmergencyExcludeThemByConstruction() {
        let excluded = SensorCatalogTests.mac14_9Keys.filter(SensorCatalog.isExcludedFromRanking)
        for key in excluded {
            #expect(!SafetyPolicy.default.emergencySensorPrefixes.contains { key.hasPrefix($0) }, "\(key)")
            for definition in appleSilicon {
                #expect(!definition.contains(key), "\(definition.id) ∋ \(key)")
            }
        }
        // Unchanged behaviour on the Mac14,9-like snapshot.
        let readings = SensorAggregator.appendingAggregates(to: mac14_9Snapshot, definitions: appleSilicon)
        let aggregates = Dictionary(uniqueKeysWithValues: readings.filter(\.isAggregate).map { ($0.id, $0.temperature) })
        #expect(aggregates == ["agg:cpu": 75.0, "agg:cpu.p": 75.0, "agg:cpu.e": 53.1, "agg:gpu": 58.5])
        let policy = SafetyPolicy.default
        #expect(FanControlEngine.hottestEmergencySensor(readings, policy: policy)?.temperature == 75.0)
        // Tf06 at 105 °C must not trigger the emergency override (threshold 95 °C).
        var evaluator = AlertEvaluator()
        #expect(evaluator.evaluateEmergency(sensors: readings, policy: policy) == false)
    }

    @Test func widgetAutoSelectionOnMac14_9() {
        let readings = SensorAggregator.appendingAggregates(to: mac14_9Snapshot, definitions: appleSilicon)
        let hottest = SensorAggregator.hottestOverview(readings, definitions: appleSilicon)
        #expect(hottest.map(\.id) == ["agg:cpu", "agg:gpu", "TW0P"])
        #expect(!hottest.contains { $0.id == "Tf06" })

        let overview = SensorAggregator.overview(readings, definitions: appleSilicon)
        #expect(overview.allSatisfy { !$0.isExcludedFromRanking })
        #expect(overview.map(\.id) == ["agg:cpu", "agg:gpu", "TG0B", "TB0T", "TH0x", "TW0P", "TaLP"])

        // Without aggregates: plain hottest rankable sensors.
        #expect(SensorAggregator.hottestOverview(mac14_9Snapshot, definitions: appleSilicon).map(\.id)
                == ["Tp1K", "TCMz", "Tp0C"])
    }

    @Test func hottestOverviewLimitsAndTies() {
        let readings = batch([("TB0T", 33), ("TW0P", 45), ("TH0x", 45), ("TaLP", .nan), ("Tf06", 105)])
        #expect(SensorAggregator.hottestOverview(readings, definitions: appleSilicon, limit: 2).map(\.id) == ["TW0P", "TH0x"])
        #expect(SensorAggregator.hottestOverview(readings, definitions: appleSilicon, limit: 10).map(\.id) == ["TW0P", "TH0x", "TB0T"])
        #expect(SensorAggregator.hottestOverview(readings, definitions: appleSilicon, limit: 0).isEmpty)
        #expect(SensorAggregator.hottestOverview(readings, definitions: appleSilicon, limit: -1).isEmpty)
        #expect(SensorAggregator.hottestOverview(batch([("Tf06", 105), ("Ta0D", 9.5)]), definitions: appleSilicon).isEmpty)
    }

    @Test func discoveryStillListsExcludedKeys() {
        // Exclusion is for ranking only; names are unchanged.
        #expect(SensorCatalog.displayName(for: "Tf06") == "Sensor Tf06")
        #expect(SensorCatalog.displayName(for: "TH1a") == "Storage 1a")
    }
}
