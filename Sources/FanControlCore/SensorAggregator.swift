import Foundation

/// One aggregate ("virtual") sensor: the maximum of every reading whose key
/// starts with one of `memberPrefixes`.
public struct SensorAggregateDefinition: Hashable, Sendable {
    /// Stable identifier used as `SensorReading.id` (e.g. `"agg:cpu"`). Always
    /// starts with `SensorAggregator.idPrefix`, so it cannot collide with a
    /// 4-character SMC key (and `SMCKey(id)` is `nil`).
    public let id: String
    /// English display name (e.g. "CPU (max)"); also returned by
    /// `SensorCatalog.displayName(for:)`.
    public let name: String
    /// Case-sensitive SMC key prefixes of the members.
    public let memberPrefixes: [String]
    /// `true` for the aggregates meant for an at-a-glance overview
    /// (`SensorAggregator.overview(_:definitions:)`): CPU and GPU. The
    /// per-cluster aggregates (P / E cores) are `false`; they are subsets of CPU.
    public let isOverview: Bool

    public init(id: String, name: String, memberPrefixes: [String], isOverview: Bool) {
        self.id = id
        self.name = name
        self.memberPrefixes = memberPrefixes
        self.isOverview = isOverview
    }

    /// `true` if `key` belongs to this aggregate. Aggregate ids never match.
    public func contains(_ key: String) -> Bool {
        !SensorAggregator.isAggregate(key) && memberPrefixes.contains { !$0.isEmpty && key.hasPrefix($0) }
    }
}

/// Builds aggregate ("virtual") temperature sensors such as "CPU (max)".
///
/// Why: on Apple Silicon there is no single CPU temperature key (Mac14,9 has
/// ~20 `Tp*` P-core keys, `Te*` E-core keys and `Tg*` GPU keys), so a
/// sensor-linked profile (`FanControlMode.sensor`) bound to one concrete key
/// follows one core only. An aggregate is an ordinary `SensorReading` whose
/// `id` is an `agg:` identifier, so `FanControlEngine.plan` resolves
/// `.sensor(sensorKey: "agg:cpu", …)` like any other key once the aggregates
/// are in its `sensors` array.
///
/// - Value: the maximum of the finite member readings (`sensorType` =
///   `.greatest`). An aggregate with no finite member is omitted, so machines
///   without such sensors simply do not get it (and a profile bound to it
///   fails hot: the engine treats a missing sensor as "run at maxRPM").
/// - Input: pass the readings **after** `TemperatureSampleFilter`, so the
///   near-zero samples of gated `Tp*` clusters never reach an aggregate.
/// - Emergency / alert handling is unaffected: aggregate ids do not start
///   with any `SafetyPolicy.emergencySensorPrefixes` entry, and their value
///   equals a member's, which is already considered.
public enum SensorAggregator {

    /// Prefix of every aggregate id.
    public static let idPrefix = "agg:"

    /// Aggregate ids (stable across architectures; members differ).
    public enum ID {
        /// CPU (max): `Tp*` + `Te*` + `TC*`.
        public static let cpu = "agg:cpu"
        /// CPU performance cores (max): `Tp*` (Apple Silicon).
        public static let cpuPerformance = "agg:cpu.p"
        /// CPU efficiency cores (max): `Te*` (Apple Silicon).
        public static let cpuEfficiency = "agg:cpu.e"
        /// GPU (max): `Tg*`, plus `TG*` on Intel only.
        public static let gpu = "agg:gpu"
    }

    /// The aggregate table for the given architecture, in display order.
    ///
    /// | id | name | members (Apple Silicon) | members (Intel) |
    /// |---|---|---|---|
    /// | `agg:cpu` | CPU (max) | `Tp` `Te` `TC` | `Tp` `Te` `TC` |
    /// | `agg:cpu.p` | CPU Performance Cores (max) | `Tp` | `Tp` |
    /// | `agg:cpu.e` | CPU Efficiency Cores (max) | `Te` | `Te` |
    /// | `agg:gpu` | GPU (max) | `Tg` | `Tg` `TG` |
    ///
    /// Members are taken from `SafetyPolicy.defaultEmergencySensorPrefixes(appleSilicon:)`,
    /// so `TG*` (a battery-area `ioft` sensor on Mac14,9, not the GPU) is
    /// excluded on Apple Silicon exactly as in the emergency prefixes.
    /// `Tp`/`Te` normally do not exist on Intel; those aggregates are then omitted.
    public static func definitions(appleSilicon: Bool) -> [SensorAggregateDefinition] {
        let allowed = Set(SafetyPolicy.defaultEmergencySensorPrefixes(appleSilicon: appleSilicon))
        func members(_ prefixes: [String]) -> [String] { prefixes.filter(allowed.contains) }
        return [
            SensorAggregateDefinition(id: ID.cpu, name: "CPU (max)",
                                      memberPrefixes: members(["Tp", "Te", "TC"]), isOverview: true),
            SensorAggregateDefinition(id: ID.cpuPerformance, name: "CPU Performance Cores (max)",
                                      memberPrefixes: members(["Tp"]), isOverview: false),
            SensorAggregateDefinition(id: ID.cpuEfficiency, name: "CPU Efficiency Cores (max)",
                                      memberPrefixes: members(["Te"]), isOverview: false),
            SensorAggregateDefinition(id: ID.gpu, name: "GPU (max)",
                                      memberPrefixes: members(["Tg", "TG"]), isOverview: true),
        ]
    }

    /// Every id that `definitions(appleSilicon:)` can produce, on either
    /// architecture, with its name (used by `SensorCatalog.displayName(for:)`).
    public static let knownNames: [String: String] = {
        var names: [String: String] = [:]
        for definition in definitions(appleSilicon: true) + definitions(appleSilicon: false) {
            names[definition.id] = definition.name
        }
        return names
    }()

    /// `true` if `id` is an aggregate id (starts with `idPrefix`).
    public static func isAggregate(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// The aggregate readings for `readings` (aggregate inputs are ignored), in
    /// `definitions` order. Aggregates without a finite member are omitted.
    public static func aggregates(of readings: [SensorReading],
                                  definitions: [SensorAggregateDefinition]) -> [SensorReading] {
        definitions.compactMap { definition in
            let values = readings
                .filter { definition.contains($0.id) && $0.temperature.isFinite }
                .map(\.temperature)
            guard let maximum = values.max() else { return nil }
            return SensorReading(id: definition.id, name: definition.name,
                                 temperature: maximum, sensorType: .greatest)
        }
    }

    /// `readings` with any previous aggregates removed and fresh ones appended.
    public static func appendingAggregates(to readings: [SensorReading],
                                           definitions: [SensorAggregateDefinition]) -> [SensorReading] {
        let base = readings.filter { !isAggregate($0.id) }
        return base + aggregates(of: base, definitions: definitions)
    }

    /// An at-a-glance subset of `readings`: the overview aggregates present in
    /// `readings` (CPU, GPU) followed by the readings that none of them covers
    /// (e.g. battery, storage). Member keys of a present overview aggregate and
    /// the non-overview aggregates are dropped, so the hottest core does not
    /// appear twice. Keys excluded from ranking
    /// (`SensorCatalog.isExcludedFromRanking(_:)`, e.g. `Tf*`) are dropped too.
    /// Order otherwise follows `readings`.
    public static func overview(_ readings: [SensorReading],
                                definitions: [SensorAggregateDefinition]) -> [SensorReading] {
        let present = Set(readings.map(\.id))
        let overviewDefinitions = definitions.filter { $0.isOverview && present.contains($0.id) }
        let overviewIDs = Set(overviewDefinitions.map(\.id))
        let aggregates = readings.filter { overviewIDs.contains($0.id) }
        let others = readings.filter { reading in
            !isAggregate(reading.id) && !reading.isExcludedFromRanking
                && !overviewDefinitions.contains { $0.contains(reading.id) }
        }
        return aggregates + others
    }

    /// The `limit` hottest finite readings of `overview(_:definitions:)`,
    /// hottest first (ties keep `overview` order). This is the widget's
    /// automatic "3 hottest sensors" selection: CPU (max) / GPU (max) stand in
    /// for their member keys, and non-thermal keys (`Tf*`, …) never compete.
    public static func hottestOverview(_ readings: [SensorReading],
                                       definitions: [SensorAggregateDefinition],
                                       limit: Int = 3) -> [SensorReading] {
        let candidates = overview(readings, definitions: definitions).filter { $0.temperature.isFinite }
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            lhs.element.temperature != rhs.element.temperature
                ? lhs.element.temperature > rhs.element.temperature
                : lhs.offset < rhs.offset
        }
        return ranked.prefix(max(0, limit)).map(\.element)
    }
}

public extension SensorReading {
    /// `true` for an aggregate reading built by `SensorAggregator`.
    var isAggregate: Bool { SensorAggregator.isAggregate(id) }
}
