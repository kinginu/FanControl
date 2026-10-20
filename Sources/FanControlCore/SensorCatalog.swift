import Foundation

/// Temperature sensor naming and discovery.
///
/// IMPORTANT: every name and key pattern in this file comes from public
/// community knowledge (open-source SMC tools, forum posts). Apple does not
/// document SMC keys and they differ between models; the mapping must be
/// verified on real hardware before being relied upon (design doc §5.7).
public enum SensorCatalog {

    /// Human-readable names for SMC temperature keys (exact match).
    ///
    /// Apple Silicon only (Intel dropped 2026-10-20): the Intel-only exact names
    /// (`TC0P`, `TC0D`, `TC0E`, `TC0F`, `TCXC`, `TG0P`, `TG0D`, `TA0P`, `TM0P`,
    /// `TH0P`, `TPCD`) were removed; none exists on Mac14,9, and `TG0P`/`TG0D`
    /// would mislabel `TG*` keys, which are battery-area sensors on Apple Silicon.
    ///
    /// Sources, per entry:
    /// - **[legacy]** names that originate in Intel-era community lists
    ///   (open-source SMC tools, e.g. the Stats app, smcFanControl, VirtualSMC
    ///   key docs). Kept only where the key also exists on Apple Silicon.
    /// - **[AS]** Apple Silicon entries of community tools (Stats app sensor
    ///   table, smctemp). Recorded from those projects' published tables, not
    ///   re-derived; marked **verified on Mac14,9** when the key exists on
    ///   Mac14,9 (M2 Pro) / macOS 26 and its value is consistent with the name
    ///   (`docs/verification/Mac14,9-macOS26-probe.txt`). "Verified" means
    ///   "present and plausible", not confirmed by Apple.
    ///
    /// Keys not listed fall back to `prefixNames`, then to `"Sensor <key>"`.
    /// Deliberately left unnamed (no community backing found; behaviour noted
    /// in docs/integration.md §6): `TCMb`/`TCMz`/`TCDX`/`TCHP`, `TVM*`/`TVm*`,
    /// `TPD*`/`TRD*`, `Th0*` (on Apple Silicon not the Intel heat pipe),
    /// `TD*`, `Tf*`, `TG*`, `Ta0*`, `Tz*`, `TS*`. Several of these are also
    /// excluded from ranking (`isExcludedFromRanking(_:)`).
    public static let knownNames: [String: String] = knownComponents.mapValues { known in
        SensorNameComponents(labelKey: known.label, suffix: known.suffix).englishName
    }

    /// `knownNames` as (label key, suffix), so that the label can be localized.
    private static let knownComponents: [String: (label: String, suffix: String?)] = [
        // [legacy] + [AS] battery: TB0T = battery maximum, TB1T/TB2T = individual
        // battery sensors. Verified on Mac14,9 (all three ≈ 33 °C).
        "TB0T": ("Battery", nil),
        "TB1T": ("Battery", "1"),
        "TB2T": ("Battery", "2"),
        // [legacy] + [AS] (Stats: "Airport"). Verified on Mac14,9 (≈ 45 °C).
        "TW0P": ("Wireless", nil),
        // [legacy] palm rest. Verified on Mac14,9 (Ts0P/Ts1P ≈ 30 °C, the coolest
        // sensors besides the battery area, as expected for the palm rest).
        "Ts0P": ("Palm Rest", nil),
        "Ts1P": ("Palm Rest", "2"),
        // [AS] Stats ("Airflow left" / "Airflow right"). Verified on Mac14,9 (≈ 44 °C).
        "TaLP": ("Airflow Left", nil),
        "TaRF": ("Airflow Right", nil),
        // [AS] Stats ("NAND"). Verified on Mac14,9 (≈ 38 °C, with TH0a/TH0b).
        "TH0x": ("NAND (SSD)", nil),
    ]

    /// Prefix patterns, checked in order after an exact `knownNames` match. The
    /// remaining characters of the key are appended so that names stay unique
    /// (e.g. `"Tp09"` → "CPU Performance Core 09").
    ///
    /// - `TaL`/`TaR`: [AS] airflow sensors (siblings of `TaLP`/`TaRF`), Mac14,9.
    /// - `Tp`/`Te`: [AS] CPU core clusters, Mac14,9 (`Tp*` 40-80 °C, `Te*` 45-60 °C).
    ///   Community tools agree `Tp*`/`Te*` are CPU cores but disagree on which
    ///   `Tp*` keys are P vs E cores per chip generation (e.g. Stats labels M2
    ///   `Tp1h`/`Tp1t` as efficiency cores), so the labels follow the prefix only.
    /// - `Tg`: [AS] GPU cluster, Mac14,9 (`Tg0*`/`Tg1*` 44-58 °C).
    /// - `TB`, `TW`: [legacy] battery / wireless families (`TB0T`, `TW0P` verified on Mac14,9).
    /// - `TM`: [legacy] memory family; legacy name, unverified on Apple Silicon
    ///   (Mac14,9 only has `TMVR`).
    /// - `TH`: [legacy]/[AS] storage (`TH0a`/`TH0b` ≈ `TH0x` on Mac14,9).
    ///
    /// `Ts` is intentionally not a prefix any more: on Mac14,9 `Ts0C`…`Ts0g`
    /// read ≈ 45-55 °C (SoC-level, not skin/palm rest), so they render as
    /// "Sensor Ts0C" until their meaning is known.
    private static let prefixNames: [(prefix: String, label: String)] = [
        ("TaL", "Airflow Left"),
        ("TaR", "Airflow Right"),
        ("Tp", "CPU Performance Core"),
        ("Te", "CPU Efficiency Core"),
        ("Tg", "GPU"),
        ("TB", "Battery"),
        ("TH", "Storage"),
        ("TW", "Wireless"),
        ("TM", "Memory"),
    ]

    /// Display name for an SMC temperature key: exact `knownNames` match, then
    /// prefix patterns, then `"Sensor <key>"`. Aggregate ids (`"agg:…"`,
    /// `SensorAggregator`) return the aggregate's name (unknown aggregate ids:
    /// `"Sensor <id>"`). Deterministic; distinct 4-character
    /// keys get distinct names (prefix names keep the key's remaining
    /// characters, and no exact name equals a name a prefix produces for a
    /// 4-character key; tested against every key seen on Mac14,9).
    ///
    /// The result is the stable English name (it is stored in
    /// `SensorReading.name` and used as a legacy key); UIs that localize build
    /// their text from `nameComponents(for:)` instead. Always equal to
    /// `nameComponents(for: key).englishName`.
    public static func displayName(for key: String) -> String {
        nameComponents(for: key).englishName
    }

    // MARK: - Localizable name components (design doc §5.7)

    /// English label keys `nameComponents(for:)` can return for SMC keys
    /// (aggregates return their aggregate name instead). Every entry is also a
    /// Localizable.strings key in the DynamicNotch drop-ins.
    public static let labelKeys: [String] = [
        "CPU Performance Core", "CPU Efficiency Core", "GPU", "Battery", "Airflow Left", "Airflow Right",
        "NAND (SSD)", "Palm Rest", "Wireless", "Memory", "Storage", fallbackLabelKey,
    ]

    /// Label key of the fallback name (`"Sensor <key>"`).
    public static let fallbackLabelKey = "Sensor"

    /// Structured name for an SMC temperature key (or aggregate id), from which
    /// `displayName(for:)` is derived and a UI builds a localized name:
    /// `localized(labelKey)` followed by `" " + suffix` when `suffix` is set.
    ///
    /// - Exact `knownNames` entries: e.g. `TB1T` → ("Battery", "1"), `TH0x` →
    ///   ("NAND (SSD)", nil).
    /// - Prefix patterns: the rest of the key is the suffix, e.g. `Tp09` →
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
        if let known = knownComponents[key] {
            return SensorNameComponents(labelKey: known.label, suffix: known.suffix)
        }
        for entry in prefixNames where key.hasPrefix(entry.prefix) {
            let suffix = key.dropFirst(entry.prefix.count).trimmingCharacters(in: .whitespaces)
            return SensorNameComponents(labelKey: entry.label, suffix: suffix.isEmpty ? nil : suffix)
        }
        return SensorNameComponents(labelKey: fallbackLabelKey, suffix: key, isFallback: true)
    }

    // MARK: - Non-thermal / unreliable keys

    /// Key prefixes excluded from automatic "hottest sensor" selection and
    /// ranking (`isExcludedFromRanking(_:)`). Applied on every machine.
    ///
    /// - `Tf`: meaning unknown (no community naming found, see `knownNames`);
    ///   the exclusion rests on Mac14,9 evidence only. On Mac14,9 (M2 Pro) / macOS 26 several `Tf*` keys hold
    ///   values that do not behave like temperatures: `Tf06`/`Tf16`/`Tf26` are
    ///   constant within a session but differ between sessions (94.50 / 79.42 /
    ///   79.42 on 2026-10-19, 105.31 / 93.08 / 88.81 on 2026-10-20, both idle),
    ///   `Tf02`/`Tf12`/`Tf22` are constant negative (≈ −12), `Tf00`/`Tf10`/`Tf20`
    ///   ≈ 0, `Tf01`/`Tf11`/`Tf21` and `Tf05`/`Tf15`/`Tf25` constant 5-22. The
    ///   remaining `Tf*` keys (`Tf04`, `Tf08`…`Tf2E`) vary like temperatures
    ///   (≈ 50-60 °C) but are excluded with the family: `Tf06` alone ranked
    ///   first in the widget's "3 hottest" and hid the CPU/GPU aggregates
    ///   (docs/integration.md §6).
    public static let rankingExcludedPrefixes: [String] = ["Tf"]

    /// Exact keys excluded from automatic "hottest sensor" selection and
    /// ranking, because they read a constant (often 0) value on Mac14,9 /
    /// macOS 26 (`fanfi-probe`, 2026-10-19 and 2026-10-20, several reads each):
    ///
    /// - always 0.00: `TH1a`, `TH1b`, `TVMD`, `Ta0C`, `Ta0G`, `Ta0K`,
    ///   `Tz11`…`Tz18`, `Tz1j`.
    /// - constant 9.50: `Ta0D`, `Ta0H`, `Ta0L`.
    /// - `Ta0V`: 0.00 on 2026-10-20, but 52.97 on 2026-10-19 (`Ta0W` behaves
    ///   the same, 62.47 → 9.50, and is **not** listed: it can read a
    ///   plausible value). Listed because it reads 0 most of the time.
    ///
    /// Kept as exact keys (not prefixes) so that sibling keys on other models
    /// are not hidden on the strength of one machine.
    public static let rankingExcludedKeys: Set<String> = [
        "TH1a", "TH1b", "TVMD",
        "Ta0C", "Ta0D", "Ta0G", "Ta0H", "Ta0K", "Ta0L", "Ta0V",
        "Tz11", "Tz12", "Tz13", "Tz14", "Tz15", "Tz16", "Tz17", "Tz18", "Tz1j",
    ]

    /// `true` if `key` is a non-thermal or unreliable SMC key that must not
    /// take part in automatic selection or ranking ("3 hottest sensors",
    /// `SensorAggregator.overview`, the hottest-sensor fallback, sorting by
    /// temperature). Discovery is unaffected: such keys are still read and
    /// listed (the Sensors tab shows them, marked and sorted last), and can
    /// still be chosen explicitly. Aggregate ids are never excluded.
    ///
    /// None of these keys matches `SafetyPolicy.defaultEmergencySensorPrefixes`
    /// or an aggregate's members, so emergency handling and aggregates exclude
    /// them by construction (tested).
    public static func isExcludedFromRanking(_ key: String) -> Bool {
        guard !SensorAggregator.isAggregate(key) else { return false }
        return rankingExcludedKeys.contains(key) || rankingExcludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Enumerates every SMC key (`#KEY` / `key(at:)`), keeps keys starting with
    /// `"T"` that have a numeric data type (`sp78`, `flt `, other fixed point or
    /// integers), reads them and keeps the ones whose value lies in
    /// `plausibleRange` (°C). Per-key failures are skipped; only a failure to
    /// read the key count throws.
    public static func discoverTemperatureSensors(using reader: SMCReader,
                                                  plausibleRange: ClosedRange<Double> = -20...130) throws -> [SensorReading] {
        let count = try reader.keyCount()
        var readings: [SensorReading] = []
        for index in 0..<max(0, count) {
            guard let key = try? reader.key(at: index),
                  key.name.hasPrefix("T"),
                  let info = try? reader.keyInfo(key),
                  info.dataSize > 0,
                  info.dataType.isNumeric,
                  let value = try? reader.readNumber(key),
                  value.isFinite,
                  plausibleRange.contains(value) else { continue }
            readings.append(SensorReading(id: key.name, name: displayName(for: key.name),
                                          temperature: value, sensorType: .smc))
        }
        return readings
    }

    /// Re-reads a fixed list of SMC temperature keys. Invalid keys, failed
    /// reads and non-finite values are skipped.
    public static func readTemperatures(keys: [String], using reader: SMCReader) -> [SensorReading] {
        keys.compactMap { name in
            guard let key = SMCKey(name),
                  let value = try? reader.readNumber(key),
                  value.isFinite else { return nil }
            return SensorReading(id: name, name: displayName(for: name), temperature: value, sensorType: .smc)
        }
    }
}

public extension SensorReading {
    /// `SensorCatalog.isExcludedFromRanking(id)`: a non-thermal or unreliable
    /// key that automatic "hottest" selection and ranking skip.
    var isExcludedFromRanking: Bool { SensorCatalog.isExcludedFromRanking(id) }
}

/// A sensor name split into a localizable label and a verbatim suffix
/// (`SensorCatalog.nameComponents(for:)`, design doc §5.7).
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
