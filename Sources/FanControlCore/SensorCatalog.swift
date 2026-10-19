import Foundation

/// Temperature sensor naming and discovery.
///
/// IMPORTANT: every name and key pattern in this file comes from public
/// community knowledge (open-source SMC tools, forum posts). Apple does not
/// document SMC keys and they differ between models; the mapping must be
/// verified on real hardware before being relied upon (design doc §5.7).
public enum SensorCatalog {

    /// Human-readable names for well-known (mostly Intel-era) SMC temperature keys.
    /// Community-sourced; verify on hardware (design doc §5.7).
    public static let knownNames: [String: String] = [
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
        "TB0T": "Battery",
        "TW0P": "Wireless",
        "Ts0P": "Palm Rest",
        "TPCD": "Platform Controller Hub Die",
    ]

    /// Prefix patterns (mostly Apple Silicon style), checked in order after an
    /// exact `knownNames` match. The remaining characters of the key are
    /// appended so that names stay unique (e.g. `"Tp09"` → "CPU Performance Core 09").
    /// Community-sourced; verify on hardware (design doc §5.7).
    private static let prefixNames: [(prefix: String, label: String)] = [
        ("TaL", "Airflow Left"),
        ("TaR", "Airflow Right"),
        ("Tp", "CPU Performance Core"),
        ("Te", "CPU Efficiency Core"),
        ("Tg", "GPU"),
        ("TB", "Battery"),
        ("Ts", "Skin/Palm Rest"),
        ("TH", "Storage"),
        ("TW", "Wireless"),
        ("TM", "Memory"),
    ]

    /// Display name for an SMC temperature key: exact `knownNames` match, then
    /// prefix patterns, then `"Sensor <key>"`.
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
