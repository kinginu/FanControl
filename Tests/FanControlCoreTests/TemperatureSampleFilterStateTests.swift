import Testing
@testable import FanControlCore

/// `TemperatureSampleFilter`'s per-key state (`states`, `decide`) and its views.
@Suite struct TemperatureSampleFilterStateTests {

    private func batch(_ values: [(String, Double)]) -> [SensorReading] {
        values.map { SensorReading(id: $0.0, name: SensorCatalog.displayName(for: $0.0), temperature: $0.1) }
    }

    @Test func testDecideCoversEveryCase() {
        let filter = TemperatureSampleFilter(maxConsecutiveSubstitutions: 2)
        typealias State = TemperatureSampleFilter.KeyState
        // Accepted: remembered, rejection run reset.
        var (d, s) = filter.decide(55, state: State(lastAccepted: 40, consecutiveRejections: 4), groupMaximum: nil)
        #expect(d == .accepted && s == State(lastAccepted: 55, consecutiveRejections: 0))
        // The floor itself is accepted.
        (d, s) = filter.decide(10, state: State(), groupMaximum: nil)
        #expect(d == .accepted && s.lastAccepted == 10)
        // Short dropout: last accepted value, even if the group is hotter.
        (d, s) = filter.decide(6.7, state: State(lastAccepted: 55, consecutiveRejections: 1), groupMaximum: 70)
        #expect(d == .substitutedLastAccepted(55) && s == State(lastAccepted: 55, consecutiveRejections: 2))
        // Longer run: the group maximum.
        (d, s) = filter.decide(6.7, state: s, groupMaximum: 70)
        #expect(d == .substitutedGroupMaximum(70) && s.consecutiveRejections == 3 && s.lastAccepted == 55)
        // No history: the group maximum straight away.
        (d, s) = filter.decide(0, state: State(), groupMaximum: 61)
        #expect(d == .substitutedGroupMaximum(61) && s == State(lastAccepted: nil, consecutiveRejections: 1))
        // Whole group implausible, run too long: passed through.
        (d, s) = filter.decide(0, state: State(lastAccepted: 55, consecutiveRejections: 2), groupMaximum: nil)
        #expect(d == .rejectedUnreplaced && d.substitute == nil && s.consecutiveRejections == 3)
        #expect(TemperatureSampleFilter.Decision.substitutedLastAccepted(1).substitute == 1)
        #expect(TemperatureSampleFilter.Decision.ignored.substitute == nil)
    }

    @Test func testViewsMirrorStates() {
        var filter = TemperatureSampleFilter()
        _ = filter.filter(batch([("Tp00", 60), ("Tp01", 0), ("TB0T", 33), ("Tg0f", .nan)]))
        #expect(filter.states["Tp00"] == .init(lastAccepted: 60, consecutiveRejections: 0))
        #expect(filter.states["Tp01"] == .init(lastAccepted: nil, consecutiveRejections: 1))
        // Unfiltered and non-finite samples leave no state.
        #expect(filter.states["TB0T"] == nil && filter.states["Tg0f"] == nil)
        #expect(filter.lastAccepted == ["Tp00": 60])
        #expect(filter.consecutiveRejections == ["Tp01": 1])
        #expect(filter.substitutedKeys == ["Tp01"])
    }

    /// Every batch goes through `decide` per sample: the filter equals folding
    /// `decide` over the batch by hand.
    @Test func testFilterEqualsFoldedDecide() {
        var filter = TemperatureSampleFilter(maxConsecutiveSubstitutions: 1)
        var states: [String: TemperatureSampleFilter.KeyState] = [:]
        let batches: [[(String, Double)]] = [
            [("Tp00", 60), ("Tp01", 62), ("Tg0f", 50)],
            [("Tp00", 6.7), ("Tp01", 63), ("Tg0f", 4)],
            [("Tp00", 6.7), ("Tp01", 8.4), ("Tg0f", 5)],
            [("Tp00", 0), ("Tp01", 0), ("Tg0f", 51)],
            [("Tp00", 58), ("Tp01", .infinity), ("Tg0f", 3)],
        ]
        for values in batches {
            let readings = batch(values)
            let output = filter.filter(readings)
            var maxima: [String: Double] = [:]
            for r in readings {
                if let g = filter.group(of: r.id), r.temperature.isFinite, r.temperature >= filter.floor {
                    maxima[g] = max(maxima[g] ?? -.infinity, r.temperature)
                }
            }
            for (r, out) in zip(readings, output) {
                guard let g = filter.group(of: r.id), r.temperature.isFinite else {
                    #expect(out == r)
                    continue
                }
                let (decision, state) = filter.decide(r.temperature, state: states[r.id] ?? .init(),
                                                      groupMaximum: maxima[g])
                states[r.id] = state
                #expect(out.temperature == decision.substitute ?? r.temperature)
            }
            #expect(filter.states == states)
        }
    }

    /// Two filters fed the same batches are equal (Hashable over the state).
    @Test func testEqualityFollowsState() {
        var a = TemperatureSampleFilter()
        var b = TemperatureSampleFilter()
        #expect(a == b)
        _ = a.filter(batch([("Tp00", 60)]))
        #expect(a != b)
        _ = b.filter(batch([("Tp00", 60)]))
        #expect(a == b)
        a.reset()
        #expect(a == TemperatureSampleFilter())
    }

    @Test func testGroupTieKeepsFirstListedPrefix() {
        let filter = TemperatureSampleFilter(filteredPrefixes: ["Tp", "", "Tp", "T"])
        #expect(filter.group(of: "Tp00") == "Tp")
        #expect(filter.group(of: "TB0T") == "T")
        #expect(filter.group(of: "XB0T") == nil)
    }
}
