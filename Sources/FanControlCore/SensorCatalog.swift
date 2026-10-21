import Foundation

/// What a temperature key measures, as far as the community tables tell
/// (`SensorCatalog.entries`). The groups that feed the sample filter and the
/// aggregates are derived from here (`SensorCatalog.keyPrefixes(of:)`).
public enum SensorGroup: String, CaseIterable, Hashable, Sendable {
    /// CPU performance cores (`Tp*`).
    case cpuPerformanceCore
    /// CPU efficiency cores (`Te*`).
    case cpuEfficiencyCore
    /// Other CPU die sensors (`TC*`; unnamed, `TCMz` follows the hottest P core on Mac14,9).
    case cpuOther
    /// GPU cluster (`Tg*`; on Apple Silicon `TG*` is **not** the GPU).
    case gpu
    case battery
    case airflow
    case storage
    case palmRest
    case wireless
    case memory

    /// Die sensors (CPU and GPU cores): the keys whose near-zero samples
    /// `TemperatureSampleFilter` rejects.
    public var isDie: Bool {
        switch self {
        case .cpuPerformanceCore, .cpuEfficiencyCore, .cpuOther, .gpu: return true
        default: return false
        }
    }
}

/// One row of the sensor table (`SensorCatalog.entries`).
public struct SensorCatalogEntry: Hashable, Sendable {

    /// Which keys a row applies to (case-sensitive).
    public enum Pattern: Hashable, Sendable {
        /// Exactly this 4-character key.
        case exact(String)
        /// Every key that starts with this (non-empty) prefix.
        case prefix(String)

        /// `true` if `key` matches.
        public func matches(_ key: String) -> Bool {
            switch self {
            case .exact(let name): return key == name
            case .prefix(let prefix): return !prefix.isEmpty && key.hasPrefix(prefix)
            }
        }

        /// Exact rows beat prefix rows; longer prefixes beat shorter ones.
        var specificity: Int {
            switch self {
            case .exact: return Int.max
            case .prefix(let prefix): return prefix.count
            }
        }
    }

    public let pattern: Pattern
    /// English label (also the Localizable.strings key), or `nil` when the row
    /// names nothing (the name then comes from a less specific labelled row, or
    /// is the `"Sensor <key>"` fallback).
    public let label: String?
    /// Exact rows only: appended after the label (e.g. `TB1T` → "Battery 1").
    /// Prefix rows append the rest of the key instead (`Tp09` → "… Core 09").
    public let suffix: String?
    /// The group, or `nil` when unknown.
    public let group: SensorGroup?
    /// `true` for non-thermal / unreliable keys (`SensorCatalog.isExcludedFromRanking(_:)`).
    public let isExcludedFromRanking: Bool

    public init(_ pattern: Pattern, label: String? = nil, suffix: String? = nil,
                group: SensorGroup? = nil, excludedFromRanking: Bool = false) {
        self.pattern = pattern
        self.label = label
        self.suffix = suffix
        self.group = group
        self.isExcludedFromRanking = excludedFromRanking
    }
}

/// Temperature sensor naming, grouping, ranking exclusion and discovery.
///
/// IMPORTANT: every name and key pattern in this file comes from public
/// community knowledge (open-source SMC tools, forum posts) or from Mac14,9
/// readings. Apple does not document SMC keys and they differ between models;
/// the mapping must be verified on real hardware before being relied upon.
///
/// Everything is driven by one table, `entries` (key pattern → label → group →
/// excluded). A key is resolved against every matching row:
/// - **name**: the most specific matching row that has a label (exact rows
///   first, then the longest prefix); none → `"Sensor <key>"`;
/// - **group**: the most specific matching row that has a group;
/// - **excluded from ranking**: any matching row says so.
///
/// So an exact row may only flag a key (`TH1a`: excluded, still named
/// "Storage 1a" by the `TH` prefix row). No two prefix rows overlap, so the
/// "longest prefix" rule never has to break a tie (tested).
public enum SensorCatalog {

    // MARK: - The table

    /// The sensor table (Apple Silicon only; Intel dropped 2026-10-20). Rows are
    /// grouped by meaning; their order only defines the order of `labelKeys`.
    ///
    /// Sources, per row:
    /// - **[legacy]** names that originate in Intel-era community lists
    ///   (open-source SMC tools, e.g. the Stats app, smcFanControl, VirtualSMC
    ///   key docs). Kept only where the key also exists on Apple Silicon. The
    ///   Intel-only exact names (`TC0P`, `TC0D`, `TC0E`, `TC0F`, `TCXC`, `TG0P`,
    ///   `TG0D`, `TA0P`, `TM0P`, `TH0P`, `TPCD`) were removed: none exists on
    ///   Mac14,9, and `TG0P`/`TG0D` would mislabel `TG*` battery-area sensors.
    /// - **[AS]** Apple Silicon entries of community tools (Stats app sensor
    ///   table, smctemp). Recorded from those projects' published tables, not
    ///   re-derived; marked **verified on Mac14,9** when the key exists on
    ///   Mac14,9 (M2 Pro) / macOS 26 and its value is consistent with the name
    ///   (`docs/verification/Mac14,9-macOS26-probe.txt`). "Verified" means
    ///   "present and plausible", not confirmed by Apple.
    /// - **[Mac14,9]** exclusions based on Mac14,9 readings only.
    ///
    /// Deliberately left unnamed (no community backing found; behaviour noted in
    /// docs/integration.md §6): `TCMb`/`TCMz`/`TCDX`/`TCHP`, `TVM*`/`TVm*`,
    /// `TPD*`/`TRD*`, `Th0*` (on Apple Silicon not the Intel heat pipe), `TD*`,
    /// `Tf*`, `TG*`, `Ta0*`, `Tz*`, `TS*`, and `Ts*` other than `Ts0P`/`Ts1P`
    /// (on Mac14,9 `Ts0C`…`Ts0g` read ≈ 45-55 °C: SoC-level, not palm rest).
    public static let entries: [SensorCatalogEntry] = [
        // CPU / GPU dies. [AS] Mac14,9: `Tp*` 40-80 °C, `Te*` 45-60 °C, `Tg0*`/`Tg1*`
        // 44-58 °C. Community tools agree `Tp*`/`Te*` are CPU cores but disagree on
        // which `Tp*` keys are P vs E cores per chip generation (e.g. Stats labels M2
        // `Tp1h`/`Tp1t` as efficiency cores), so the labels follow the prefix only.
        .init(.prefix("Tp"), label: "CPU Performance Core", group: .cpuPerformanceCore),
        .init(.prefix("Te"), label: "CPU Efficiency Core", group: .cpuEfficiencyCore),
        .init(.prefix("TC"), group: .cpuOther),
        .init(.prefix("Tg"), label: "GPU", group: .gpu),

        // [legacy] + [AS] battery: TB0T = battery maximum, TB1T/TB2T = individual
        // sensors. Verified on Mac14,9 (all three ≈ 33 °C).
        .init(.exact("TB0T"), label: "Battery", group: .battery),
        .init(.exact("TB1T"), label: "Battery", suffix: "1", group: .battery),
        .init(.exact("TB2T"), label: "Battery", suffix: "2", group: .battery),
        .init(.prefix("TB"), label: "Battery", group: .battery),

        // [AS] Stats ("Airflow left" / "Airflow right"); siblings by prefix.
        // Verified on Mac14,9 (≈ 44 °C).
        .init(.exact("TaLP"), label: "Airflow Left", group: .airflow),
        .init(.prefix("TaL"), label: "Airflow Left", group: .airflow),
        .init(.exact("TaRF"), label: "Airflow Right", group: .airflow),
        .init(.prefix("TaR"), label: "Airflow Right", group: .airflow),

        // [AS] Stats ("NAND"). Verified on Mac14,9 (≈ 38 °C, with TH0a/TH0b).
        .init(.exact("TH0x"), label: "NAND (SSD)", group: .storage),

        // [legacy] palm rest. Verified on Mac14,9 (Ts0P/Ts1P ≈ 30 °C, the coolest
        // sensors besides the battery area). `Ts` is not a prefix row (see above).
        .init(.exact("Ts0P"), label: "Palm Rest", group: .palmRest),
        .init(.exact("Ts1P"), label: "Palm Rest", suffix: "2", group: .palmRest),

        // [legacy] + [AS] (Stats: "Airport"). Verified on Mac14,9 (≈ 45 °C).
        .init(.exact("TW0P"), label: "Wireless", group: .wireless),
        .init(.prefix("TW"), label: "Wireless", group: .wireless),

        // [legacy] memory family; unverified on Apple Silicon (Mac14,9 only has `TMVR`).
        .init(.prefix("TM"), label: "Memory", group: .memory),

        // [legacy]/[AS] storage (`TH0a`/`TH0b` ≈ `TH0x` on Mac14,9). [Mac14,9]
        // `TH1a`/`TH1b` always read 0.00: excluded, still named by the prefix.
        .init(.prefix("TH"), label: "Storage", group: .storage),
        .init(.exact("TH1a"), excludedFromRanking: true),
        .init(.exact("TH1b"), excludedFromRanking: true),

        // [Mac14,9] `Tf*`: meaning unknown (no community naming found). Several keys
        // do not behave like temperatures: `Tf06`/`Tf16`/`Tf26` are constant within a
        // session but differ between sessions (94.50 / 79.42 / 79.42 on 2026-10-19,
        // 105.31 / 93.08 / 88.81 on 2026-10-20, both idle), `Tf02`/`Tf12`/`Tf22` are
        // constant negative (≈ −12), `Tf00`/`Tf10`/`Tf20` ≈ 0, `Tf01`/`Tf11`/`Tf21`
        // and `Tf05`/`Tf15`/`Tf25` constant 5-22. The remaining `Tf*` keys (`Tf04`,
        // `Tf08`…`Tf2E`) vary like temperatures (≈ 50-60 °C) but are excluded with
        // the family: `Tf06` alone ranked first in the widget's "3 hottest" and hid
        // the CPU/GPU aggregates (docs/integration.md §6).
        .init(.prefix("Tf"), excludedFromRanking: true),

        // [Mac14,9] constant readings (`fanfi-probe`, 2026-10-19 and 2026-10-20,
        // several reads each). Exact keys, not prefixes, so that sibling keys on
        // other models are not hidden on the strength of one machine.
        // - always 0.00: `TVMD`, `Ta0C`, `Ta0G`, `Ta0K`, `Tz11`…`Tz18`, `Tz1j`;
        // - constant 9.50: `Ta0D`, `Ta0H`, `Ta0L`;
        // - `Ta0V`: 0.00 on 2026-10-20 but 52.97 on 2026-10-19; listed because it
        //   reads 0 most of the time. `Ta0W` behaves the same (62.47 → 9.50) and is
        //   **not** listed: it can read a plausible value.
        .init(.exact("TVMD"), excludedFromRanking: true),
        .init(.exact("Ta0C"), excludedFromRanking: true),
        .init(.exact("Ta0D"), excludedFromRanking: true),
        .init(.exact("Ta0G"), excludedFromRanking: true),
        .init(.exact("Ta0H"), excludedFromRanking: true),
        .init(.exact("Ta0K"), excludedFromRanking: true),
        .init(.exact("Ta0L"), excludedFromRanking: true),
        .init(.exact("Ta0V"), excludedFromRanking: true),
        .init(.exact("Tz11"), excludedFromRanking: true),
        .init(.exact("Tz12"), excludedFromRanking: true),
        .init(.exact("Tz13"), excludedFromRanking: true),
        .init(.exact("Tz14"), excludedFromRanking: true),
        .init(.exact("Tz15"), excludedFromRanking: true),
        .init(.exact("Tz16"), excludedFromRanking: true),
        .init(.exact("Tz17"), excludedFromRanking: true),
        .init(.exact("Tz18"), excludedFromRanking: true),
        .init(.exact("Tz1j"), excludedFromRanking: true),
    ]

    /// Label key of the fallback name (`"Sensor <key>"`).
    public static let fallbackLabelKey = "Sensor"

    // MARK: - Views of the table

    /// Exact-key names (`"TB1T"` → "Battery 1"): the labelled exact rows of `entries`.
    /// Keys not listed are named by prefix rows, then `"Sensor <key>"`.
    public static let knownNames: [String: String] = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
        guard case .exact(let key) = entry.pattern, let label = entry.label else { return nil }
        return (key, SensorNameComponents(labelKey: label, suffix: entry.suffix).englishName)
    })

    /// English label keys `nameComponents(for:)` can return for SMC keys (the
    /// distinct labels of `entries` in table order, then `fallbackLabelKey`;
    /// aggregates return their aggregate name instead). Every entry is also a
    /// Localizable.strings key in the host app (DynamicNotch ships them).
    public static let labelKeys: [String] = {
        var seen = Set<String>()
        let labels = entries.compactMap(\.label).filter { seen.insert($0).inserted }
        return labels + [fallbackLabelKey]
    }()

    /// Key prefixes excluded from automatic "hottest sensor" selection and
    /// ranking (the excluded prefix rows of `entries`: `Tf`).
    public static let rankingExcludedPrefixes: [String] = entries.compactMap { entry in
        guard entry.isExcludedFromRanking, case .prefix(let prefix) = entry.pattern else { return nil }
        return prefix
    }

    /// Exact keys excluded from automatic "hottest sensor" selection and
    /// ranking (the excluded exact rows of `entries`: constant readings on Mac14,9).
    public static let rankingExcludedKeys: Set<String> = Set(entries.compactMap { entry in
        guard entry.isExcludedFromRanking, case .exact(let key) = entry.pattern else { return nil }
        return key
    })

    /// The prefixes of the prefix rows of `group`, in table order (e.g.
    /// `.cpuPerformanceCore` → `["Tp"]`). Used for `TemperatureSampleFilter`'s
    /// default prefixes and `SensorAggregator`'s members.
    public static func keyPrefixes(of group: SensorGroup) -> [String] {
        entries.compactMap { entry in
            guard entry.group == group, case .prefix(let prefix) = entry.pattern else { return nil }
            return prefix
        }
    }

    /// The group of an SMC key (most specific matching row with a group), or
    /// `nil` (unknown key, aggregate id).
    public static func group(for key: String) -> SensorGroup? {
        guard !SensorAggregator.isAggregate(key) else { return nil }
        return resolve(key).group
    }

    // MARK: - Names

    /// Display name for an SMC temperature key: the most specific labelled row,
    /// then `"Sensor <key>"`. Aggregate ids (`"agg:…"`, `SensorAggregator`) return
    /// the aggregate's name (unknown aggregate ids: `"Sensor <id>"`).
    /// Deterministic; distinct 4-character keys get distinct names (prefix names
    /// keep the key's remaining characters, and no exact name equals a name a
    /// prefix produces for a 4-character key; tested against every key seen on
    /// Mac14,9).
    ///
    /// The result is the stable English name (it is stored in
    /// `SensorReading.name` and used as a legacy key); UIs that localize build
    /// their text from `nameComponents(for:)` instead. Always equal to
    /// `nameComponents(for: key).englishName`.
    public static func displayName(for key: String) -> String {
        nameComponents(for: key).englishName
    }

    /// Structured name for an SMC temperature key (or aggregate id), from which
    /// `displayName(for:)` is derived and a UI builds a localized name:
    /// `localized(labelKey)` followed by `" " + suffix` when `suffix` is set.
    ///
    /// - Exact rows: e.g. `TB1T` → ("Battery", "1"), `TH0x` → ("NAND (SSD)", nil).
    /// - Prefix rows: the rest of the key is the suffix, e.g. `Tp09` →
    ///   ("CPU Performance Core", "09").
    /// - Aggregate ids: (aggregate name, nil), e.g. `agg:cpu` → ("CPU (max)", nil).
    /// - Anything else: (`fallbackLabelKey`, key) with `isFallback == true`.
    public static func nameComponents(for key: String) -> SensorNameComponents {
        if SensorAggregator.isAggregate(key) {
            if let name = SensorAggregator.knownNames[key] {
                return SensorNameComponents(labelKey: name, suffix: nil)
            }
            return SensorNameComponents(labelKey: fallbackLabelKey, suffix: key, isFallback: true)
        }
        guard let named = resolve(key).named, let label = named.label else {
            return SensorNameComponents(labelKey: fallbackLabelKey, suffix: key, isFallback: true)
        }
        switch named.pattern {
        case .exact:
            return SensorNameComponents(labelKey: label, suffix: named.suffix)
        case .prefix(let prefix):
            let suffix = key.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return SensorNameComponents(labelKey: label, suffix: suffix.isEmpty ? nil : suffix)
        }
    }

    // MARK: - Non-thermal / unreliable keys

    /// `true` if `key` is a non-thermal or unreliable SMC key that must not
    /// take part in automatic selection or ranking ("3 hottest sensors",
    /// `SensorAggregator.overview`, the hottest-sensor fallback, sorting by
    /// temperature): any matching row of `entries` is excluded. Discovery is
    /// unaffected: such keys are still read and listed (the Sensors tab shows
    /// them, marked and sorted last), and can still be chosen explicitly.
    /// Aggregate ids are never excluded.
    ///
    /// None of these keys matches `SafetyPolicy.defaultEmergencySensorPrefixes`
    /// or an aggregate's members, so emergency handling and aggregates exclude
    /// them by construction (tested).
    public static func isExcludedFromRanking(_ key: String) -> Bool {
        guard !SensorAggregator.isAggregate(key) else { return false }
        return resolve(key).excluded
    }

    // MARK: - Resolution

    /// Labelled exact rows and exact rows in general, by key.
    private static let exactRows: [String: SensorCatalogEntry] = Dictionary(
        entries.compactMap { entry in
            guard case .exact(let key) = entry.pattern else { return nil }
            return (key, entry)
        }, uniquingKeysWith: { first, _ in first })

    /// Prefix rows, longest prefix first (stable for equal lengths).
    private static let prefixRows: [SensorCatalogEntry] = entries
        .filter { if case .prefix = $0.pattern { return true } else { return false } }
        .enumerated()
        .sorted { ($0.element.pattern.specificity, -$0.offset) > ($1.element.pattern.specificity, -$1.offset) }
        .map(\.element)

    private struct Resolution {
        var named: SensorCatalogEntry?
        var group: SensorGroup?
        var excluded = false
    }

    /// Applies the resolution rules (type documentation) to `key`; no allocation
    /// beyond the dictionary lookup.
    private static func resolve(_ key: String) -> Resolution {
        var result = Resolution()
        if let exact = exactRows[key] {
            if exact.label != nil { result.named = exact }
            result.group = exact.group
            result.excluded = exact.isExcludedFromRanking
        }
        for row in prefixRows where row.pattern.matches(key) {
            if result.named == nil, row.label != nil { result.named = row }
            if result.group == nil { result.group = row.group }
            if row.isExcludedFromRanking { result.excluded = true }
        }
        return result
    }

    // MARK: - Reading

    /// Enumerates every SMC key (`#KEY` / `key(at:)`), keeps keys starting with
    /// `"T"` that have a numeric data type (`sp78`, `flt `, other fixed point or
    /// integers), reads them and keeps the ones whose value lies in
    /// `plausibleRange` (°C). Per-key failures are skipped; only a failure to
    /// read the key count throws. Run once per reader; later polls re-read the
    /// result with `readTemperatures(_:using:)`.
    public static func discoverTemperatureSensors(using reader: SMCReader,
                                                  plausibleRange: ClosedRange<Double> = -20...130) throws -> [SensorReading] {
        let count = try reader.keyCount()
        var readings: [SensorReading] = []
        for index in 0..<max(0, count) {
            guard let key = try? reader.key(at: index) else { continue }
            let name = key.name
            guard name.hasPrefix("T"),
                  let info = try? reader.keyInfo(key),
                  info.dataSize > 0,
                  info.dataType.isNumeric,
                  let value = try? reader.readNumber(key),
                  value.isFinite,
                  plausibleRange.contains(value) else { continue }
            readings.append(SensorReading(id: name, name: displayName(for: name),
                                          temperature: value, sensorType: .smc))
        }
        return readings
    }

    /// Re-reads a fixed list of SMC temperature keys. Invalid keys, failed
    /// reads and non-finite values are skipped. Resolves every key and name on
    /// each call; a poll loop keeps `TemperatureSensorKey`s and calls
    /// `readTemperatures(_:using:)` instead.
    public static func readTemperatures(keys: [String], using reader: SMCReader) -> [SensorReading] {
        readTemperatures(keys.compactMap { TemperatureSensorKey(id: $0) }, using: reader)
    }

    /// Re-reads pre-resolved temperature keys (one SMC read per key, no key
    /// parsing or name lookup). Failed reads and non-finite values are skipped;
    /// the order of `sensors` is kept.
    public static func readTemperatures(_ sensors: [TemperatureSensorKey], using reader: SMCReader) -> [SensorReading] {
        var readings: [SensorReading] = []
        readings.reserveCapacity(sensors.count)
        for sensor in sensors {
            guard let value = try? reader.readNumber(sensor.key), value.isFinite else { continue }
            readings.append(SensorReading(id: sensor.id, name: sensor.name, temperature: value, sensorType: .smc))
        }
        return readings
    }
}

/// An SMC temperature key with its parsed `SMCKey` and display name, resolved
/// once (at discovery) so that every poll can re-read it cheaply
/// (`SensorCatalog.readTemperatures(_:using:)`).
public struct TemperatureSensorKey: Hashable, Sendable {
    /// The parsed key.
    public let key: SMCKey
    /// The key name (`SensorReading.id`).
    public let id: String
    /// `SensorCatalog.displayName(for: id)` unless given explicitly.
    public let name: String

    /// `nil` unless `id` is a 4-character ASCII key.
    public init?(id: String, name: String? = nil) {
        guard let key = SMCKey(id) else { return nil }
        self.key = key
        self.id = id
        self.name = name ?? SensorCatalog.displayName(for: id)
    }
}

public extension SensorReading {
    /// `SensorCatalog.isExcludedFromRanking(id)`: a non-thermal or unreliable
    /// key that automatic "hottest" selection and ranking skip.
    var isExcludedFromRanking: Bool { SensorCatalog.isExcludedFromRanking(id) }
}

/// A sensor name split into a localizable label and a verbatim suffix
/// (`SensorCatalog.nameComponents(for:)`).
public struct SensorNameComponents: Hashable, Sendable {
    /// English label, also the Localizable.strings key (one of
    /// `SensorCatalog.labelKeys`, or an aggregate name such as "CPU (max)").
    public var labelKey: String
    /// Appended verbatim after a space (rest of the SMC key, sensor index, or
    /// the raw key for the fallback), or `nil`.
    public var suffix: String?
    /// `true` for keys without a known name (`"Sensor <key>"`).
    public var isFallback: Bool

    public init(labelKey: String, suffix: String?, isFallback: Bool = false) {
        self.labelKey = labelKey
        self.suffix = suffix
        self.isFallback = isFallback
    }

    /// The unlocalized name (`SensorCatalog.displayName(for:)`).
    public var englishName: String { name(label: labelKey) }

    /// The name with `label` (e.g. the localized `labelKey`) in place of the label key.
    public func name(label: String) -> String {
        guard let suffix, !suffix.isEmpty else { return label }
        return "\(label) \(suffix)"
    }
}
