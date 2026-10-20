import Testing
@testable import FanControlCore

/// The data-driven sensor table (`SensorCatalog.entries`) and the views derived from it.
@Suite struct SensorCatalogTableTests {

    private var prefixes: [String] {
        SensorCatalog.entries.compactMap { if case .prefix(let p) = $0.pattern { return p } else { return nil } }
    }

    @Test func testTableIsWellFormed() {
        let patterns = SensorCatalog.entries.map(\.pattern)
        #expect(Set(patterns).count == patterns.count, "duplicate rows")
        for entry in SensorCatalog.entries {
            switch entry.pattern {
            case .exact(let key):
                #expect(SMCKey(key) != nil, "\(key) is not a 4-character key")
            case .prefix(let prefix):
                #expect(!prefix.isEmpty)
                #expect(entry.suffix == nil, "prefix row \(prefix) with a suffix")
            }
            if entry.suffix != nil { #expect(entry.label != nil) }
            if let label = entry.label { #expect(SensorCatalog.labelKeys.contains(label)) }
            #expect(entry.label != nil || entry.group != nil || entry.isExcludedFromRanking,
                    "row \(entry.pattern) does nothing")
        }
    }

    /// No prefix row is a prefix of another, so "longest prefix wins" never
    /// depends on table order.
    @Test func testPrefixRowsDoNotOverlap() {
        for a in prefixes {
            for b in prefixes where a != b {
                #expect(!b.hasPrefix(a), "\(a) overlaps \(b)")
            }
        }
    }

    /// The derived views equal the tables they replaced (behaviour unchanged).
    @Test func testDerivedViewsMatchTheFormerTables() {
        #expect(SensorCatalog.knownNames == [
            "TB0T": "Battery", "TB1T": "Battery 1", "TB2T": "Battery 2", "TW0P": "Wireless",
            "Ts0P": "Palm Rest", "Ts1P": "Palm Rest 2", "TaLP": "Airflow Left", "TaRF": "Airflow Right",
            "TH0x": "NAND (SSD)",
        ])
        #expect(SensorCatalog.labelKeys == [
            "CPU Performance Core", "CPU Efficiency Core", "GPU", "Battery", "Airflow Left", "Airflow Right",
            "NAND (SSD)", "Palm Rest", "Wireless", "Memory", "Storage", "Sensor",
        ])
        #expect(SensorCatalog.rankingExcludedPrefixes == ["Tf"])
        #expect(SensorCatalog.rankingExcludedKeys == [
            "TH1a", "TH1b", "TVMD", "Ta0C", "Ta0D", "Ta0G", "Ta0H", "Ta0K", "Ta0L", "Ta0V",
            "Tz11", "Tz12", "Tz13", "Tz14", "Tz15", "Tz16", "Tz17", "Tz18", "Tz1j",
        ])
        #expect(TemperatureSampleFilter.defaultFilteredPrefixes == ["Tp", "Te", "Tg", "TC"])
        #expect(SensorAggregator.definitions.map(\.memberPrefixes) == [["Tp", "Te", "TC"], ["Tp"], ["Te"], ["Tg"]])
    }

    @Test func testGroups() {
        #expect(SensorCatalog.group(for: "Tp09") == .cpuPerformanceCore)
        #expect(SensorCatalog.group(for: "Te05") == .cpuEfficiencyCore)
        #expect(SensorCatalog.group(for: "TCMz") == .cpuOther)
        #expect(SensorCatalog.group(for: "Tg0f") == .gpu)
        #expect(SensorCatalog.group(for: "TG0B") == nil) // battery area on Mac14,9, not the GPU
        #expect(SensorCatalog.group(for: "TB1T") == .battery)
        #expect(SensorCatalog.group(for: "TaLT") == .airflow)
        #expect(SensorCatalog.group(for: "TH0x") == .storage)
        #expect(SensorCatalog.group(for: "TH1a") == .storage) // flagged by an exact row, grouped by `TH`
        #expect(SensorCatalog.group(for: "Ts1P") == .palmRest)
        #expect(SensorCatalog.group(for: "Ts0C") == nil)
        #expect(SensorCatalog.group(for: "Tf06") == nil)
        #expect(SensorCatalog.group(for: "agg:cpu") == nil)
        #expect(SensorCatalog.keyPrefixes(of: .battery) == ["TB"])
        #expect(SensorCatalog.keyPrefixes(of: .palmRest).isEmpty)
        let die = SensorGroup.allCases.filter(\.isDie)
        #expect(Set(die.flatMap(SensorCatalog.keyPrefixes(of:))) == Set(TemperatureSampleFilter.defaultFilteredPrefixes))
    }

    /// Every filtered / aggregated / emergency prefix is a die group.
    @Test func testDiePrefixesAgreeWithSafetyPolicy() {
        let die = Set(SensorGroup.allCases.filter(\.isDie).flatMap(SensorCatalog.keyPrefixes(of:)))
        #expect(die == Set(SafetyPolicy.defaultEmergencySensorPrefixes))
        for definition in SensorAggregator.definitions {
            #expect(Set(definition.memberPrefixes).isSubset(of: die))
        }
    }

    /// Name, group and exclusion resolve independently: an exact row that only
    /// flags a key keeps the prefix row's name.
    @Test func testIndependentResolution() {
        #expect(SensorCatalog.displayName(for: "TH1a") == "Storage 1a")
        #expect(SensorCatalog.isExcludedFromRanking("TH1a"))
        #expect(SensorCatalog.knownNames["TH1a"] == nil)
        #expect(SensorCatalog.displayName(for: "TCMz") == "Sensor TCMz") // grouped, unnamed
        #expect(!SensorCatalog.isExcludedFromRanking("TCMz"))
        #expect(SensorCatalog.displayName(for: "Tf04") == "Sensor Tf04")
        #expect(SensorCatalog.isExcludedFromRanking("Tf04"))
        #expect(!SensorCatalog.isExcludedFromRanking("Ta0W"))
        // Exact rows beat prefix rows: TaLP has no "P" suffix, TaLT keeps its "T".
        #expect(SensorCatalog.nameComponents(for: "TaLP") == SensorNameComponents(labelKey: "Airflow Left", suffix: nil))
        #expect(SensorCatalog.nameComponents(for: "TaLT") == SensorNameComponents(labelKey: "Airflow Left", suffix: "T"))
    }

    @Test func testPatternMatching() {
        #expect(SensorCatalogEntry.Pattern.exact("TB0T").matches("TB0T"))
        #expect(!SensorCatalogEntry.Pattern.exact("TB0T").matches("TB0t"))
        #expect(SensorCatalogEntry.Pattern.prefix("Tp").matches("Tp0X"))
        #expect(!SensorCatalogEntry.Pattern.prefix("Tp").matches("TP0X"))
        #expect(!SensorCatalogEntry.Pattern.prefix("").matches("Tp0X"))
    }
}

/// Pre-resolved temperature keys (`TemperatureSensorKey`) and the per-poll read.
@Suite struct TemperatureSensorKeyTests {

    @Test func testResolvesKeyAndNameOnce() throws {
        let key = try #require(TemperatureSensorKey(id: "Tp09"))
        #expect(key.key == SMCKey("Tp09"))
        #expect(key.name == "CPU Performance Core 09")
        #expect(TemperatureSensorKey(id: "Tp09", name: "Custom")?.name == "Custom")
        #expect(TemperatureSensorKey(id: "agg:cpu") == nil)
        #expect(TemperatureSensorKey(id: "bad") == nil)
    }

    /// Both read overloads return the same readings, in key order, skipping failures.
    @Test func testReadOverloadsAgree() {
        let reader = MockSMCReader([("Tp00", .flt, Fixtures.flt(56)),
                                    ("TB0T", .flt, Fixtures.flt(33)),
                                    ("Tg0f", .flt, [0x00, 0x00, 0xC0, 0x7F]), // NaN (little-endian float)
                                    ("TH0x", .flt, Fixtures.flt(38))])
        reader.failingReads.insert("TH0x")
        let ids = ["TB0T", "NOPE", "Tp00", "Tg0f", "TH0x", "bad"]
        let byName = SensorCatalog.readTemperatures(keys: ids, using: reader)
        let resolved = SensorCatalog.readTemperatures(ids.compactMap { TemperatureSensorKey(id: $0) }, using: reader)
        #expect(byName == resolved)
        #expect(byName.map(\.id) == ["TB0T", "Tp00"])
        #expect(byName.map(\.name) == ["Battery", "CPU Performance Core 00"])
        #expect(byName.allSatisfy { $0.sensorType == .smc })
    }

    /// Discovery → keys → read → filter → aggregate gives the same aggregates as
    /// the discovery batch itself (the poller's first batch).
    @Test func testDiscoveryRoundTrip() throws {
        let reader = MockSMCReader([("Tp00", .flt, Fixtures.flt(60)),
                                    ("Tp01", .flt, Fixtures.flt(6.7)),
                                    ("Te04", .flt, Fixtures.flt(48)),
                                    ("Tg0f", .flt, Fixtures.flt(52)),
                                    ("TB0T", .flt, Fixtures.flt(33))])
        let discovered = try SensorCatalog.discoverTemperatureSensors(using: reader)
        let keys = discovered.compactMap { TemperatureSensorKey(id: $0.id, name: $0.name) }
        #expect(keys.map(\.id) == discovered.map(\.id))
        var filter = TemperatureSampleFilter()
        let first = SensorAggregator.appendingAggregates(to: filter.filter(discovered),
                                                         definitions: SensorAggregator.definitions)
        let second = SensorAggregator.appendingAggregates(
            to: filter.filter(SensorCatalog.readTemperatures(keys, using: reader)),
            definitions: SensorAggregator.definitions)
        #expect(first == second)
        let aggregates = Dictionary(uniqueKeysWithValues: second.filter(\.isAggregate).map { ($0.id, $0.temperature) })
        #expect(aggregates == ["agg:cpu": 60, "agg:cpu.p": 60, "agg:cpu.e": 48, "agg:gpu": 52])
        // Tp01 (6.7) was replaced by its group's maximum in both batches.
        #expect(second.first { $0.id == "Tp01" }?.temperature == 60)
    }
}
