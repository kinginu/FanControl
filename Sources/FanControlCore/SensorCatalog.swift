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
    /// Sources, per entry:
    /// - **[Intel]** Intel-era community lists (open-source SMC tools, e.g. the
    ///   Stats app, smcFanControl, VirtualSMC key docs). Not verified on hardware here.
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
    /// `TD*`, `Tf*`, `TG*`, `Ta0*`, `Tz*`, `TS*`.
    public static let knownNames: [String: String] = [
        // [Intel]
        "TC0P": "CPU Proximity",
        "TC0D": "CPU Die",
        "TC0E": "CPU Die (Virtual)",
        "TC0F": "CPU Die (Filtered)",
        "TCXC": "CPU PECI",
        "TG0P": "GPU Proximity",
        "TG0D": "GPU Die",
        "TA0P": "Ambient",
        "TM0P": "Memory Proximity",
        "TH0P": "Drive 0",
        "TPCD": "Platform Controller Hub Die",
        // [Intel] + [AS] battery: TB0T = battery maximum, TB1T/TB2T = individual
        // battery sensors. Verified on Mac14,9 (all three ≈ 33 °C).
        "TB0T": "Battery",
        "TB1T": "Battery 1",
        "TB2T": "Battery 2",
        // [Intel] + [AS] (Stats: "Airport"). Verified on Mac14,9 (≈ 45 °C).
        "TW0P": "Wireless",
        // [Intel] palm rest. Verified on Mac14,9 (Ts0P/Ts1P ≈ 30 °C, the coolest
        // sensors besides the battery area, as expected for the palm rest).
        "Ts0P": "Palm Rest",
        "Ts1P": "Palm Rest 2",
        // [AS] Stats ("Airflow left" / "Airflow right"). Verified on Mac14,9 (≈ 44 °C).
        "TaLP": "Airflow Left",
        "TaRF": "Airflow Right",
        // [AS] Stats ("NAND"). Verified on Mac14,9 (≈ 38 °C, with TH0a/TH0b).
        "TH0x": "NAND (SSD)",
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
    /// - `TB`, `TW`, `TM`: [Intel] battery / wireless / memory families.
    /// - `TH`: [Intel]/[AS] storage (`TH0a`/`TH0b` ≈ `TH0x` on Mac14,9).
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
    /// prefix patterns, then `"Sensor <key>"`. Deterministic; distinct 4-character
    /// keys get distinct names (prefix names keep the key's remaining
    /// characters, and no exact name equals a name a prefix produces for a
    /// 4-character key; tested against every key seen on Mac14,9).
    public static func displayName(for key: String) -> String {
        if let known = knownNames[key] { return known }
        for entry in prefixNames where key.hasPrefix(entry.prefix) {
            let suffix = key.dropFirst(entry.prefix.count).trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? entry.label : "\(entry.label) \(suffix)"
        }
        return "Sensor \(key)"
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
