import Foundation

/// Replaces implausibly low samples of die sensors (CPU/GPU cores) before they
/// reach the UI and `FanControlEngine.plan`.
///
/// Why: on Mac14,9 (M2 Pro) / macOS 26 the CPU performance-core keys `Tp*`
/// read, per 3-key group, either their real value (40-80 °C) or a fixed
/// pattern such as `0.00 / 6.70 / 8.43`, `0.00 / 4.63 / 5.32` or
/// `0.00 / 6.03 / 7.43` (most likely while that core cluster is power-gated).
/// The pattern can alternate on every read or persist for many reads (one
/// cluster stayed on it for a whole idle `--watch` run). A sensor-linked mode
/// (`FanControlMode.sensor`) bound to such a key would see ~0 °C and drop the
/// fan to its minimum.
///
/// Rule, per sample of a key that starts with one of `filteredPrefixes`:
/// - Finite and `>= floor` → accepted as-is and remembered as the key's last
///   accepted value; the key's rejection counter is reset.
/// - Finite and `< floor` → rejected. The substitute is, in order:
///   1. the key's last accepted value, while the key has been rejected at most
///      `maxConsecutiveSubstitutions` times in a row (short dropouts);
///   2. otherwise (no history, or the run of rejections is longer) the hottest
///      accepted sample of the same prefix group in this same batch (e.g. the
///      hottest live `Tp*` key while one cluster is gated) — a live value, so it
///      is not limited in time;
///   3. otherwise (the whole group is implausible) the raw sample is passed
///      through unchanged.
/// - Non-finite samples and keys outside `filteredPrefixes` pass through
///   untouched (the engine's "fail hot" handling of non-finite values is
///   unaffected).
///
/// A substitute is always hotter than the rejected sample, so filtering can
/// only raise temperatures: it never lowers the emergency maximum and never
/// makes a sensor-linked fan slower than unfiltered input would.
///
/// Sudden drops relative to the previous value are deliberately **not**
/// rejected: genuine core temperatures on Apple Silicon fall by 10-20 °C
/// within a poll when load stops, all observed bogus samples are below 10 °C,
/// and a drop detector would need tuning per model. The floor alone fixes the
/// observed failure (near-zero samples driving the fan down).
///
/// Not thread-safe; use it from the queue that reads the sensors.
public struct TemperatureSampleFilter: Hashable, Sendable {

    /// Default `floor` (°C). A running CPU/GPU die is not below 10 °C in
    /// practice; every bogus value observed on Mac14,9 is below 8.5 °C.
    public static let defaultFloor: Double = 10
    /// Default `filteredPrefixes`: die-type sensors (P/E cores, GPU, Intel CPU).
    public static let defaultFilteredPrefixes = ["Tp", "Te", "Tg", "TC"]
    /// Default `maxConsecutiveSubstitutions` (5 polls = 10 s at the default 2 s interval).
    public static let defaultMaxConsecutiveSubstitutions = 5

    /// Samples below this temperature (°C) are implausible for filtered keys.
    public var floor: Double
    /// Key prefixes (case-sensitive) the filter applies to. When several match,
    /// the longest defines the key's group.
    public var filteredPrefixes: [String]
    /// How many consecutive rejections of one key may be replaced by that
    /// key's last accepted value before the group maximum (or the raw sample)
    /// is used instead.
    public var maxConsecutiveSubstitutions: Int

    /// Last accepted temperature per key.
    public private(set) var lastAccepted: [String: Double] = [:]
    /// Current run of consecutive rejections per key (absent = 0).
    public private(set) var consecutiveRejections: [String: Int] = [:]
    /// Keys whose temperature was replaced in the most recent `filter(_:)` call.
    public private(set) var substitutedKeys: Set<String> = []

    public init(floor: Double = TemperatureSampleFilter.defaultFloor,
                filteredPrefixes: [String] = TemperatureSampleFilter.defaultFilteredPrefixes,
                maxConsecutiveSubstitutions: Int = TemperatureSampleFilter.defaultMaxConsecutiveSubstitutions) {
        self.floor = floor
        self.filteredPrefixes = filteredPrefixes
        self.maxConsecutiveSubstitutions = maxConsecutiveSubstitutions
    }

    /// The prefix group of `key` (longest matching prefix), or `nil` if the
    /// filter does not apply to it.
    public func group(of key: String) -> String? {
        filteredPrefixes
            .filter { !$0.isEmpty && key.hasPrefix($0) }
            .max { $0.count < $1.count }
    }

    /// `true` if `reading` is a finite sample below `floor` of a filtered key.
    public func isImplausible(_ reading: SensorReading) -> Bool {
        group(of: reading.id) != nil && reading.temperature.isFinite && reading.temperature < floor
    }

    /// Filters one batch of samples (one poll). Order, ids, names and sensor
    /// types are preserved; only `temperature` may change.
    public mutating func filter(_ readings: [SensorReading]) -> [SensorReading] {
        var groupMax: [String: Double] = [:]
        for reading in readings {
            guard let group = group(of: reading.id), reading.temperature.isFinite,
                  reading.temperature >= floor else { continue }
            groupMax[group] = Swift.max(groupMax[group] ?? -.infinity, reading.temperature)
        }

        var substituted: Set<String> = []
        let result = readings.map { reading -> SensorReading in
            guard let group = group(of: reading.id), reading.temperature.isFinite else { return reading }
            let key = reading.id
            if reading.temperature >= floor {
                lastAccepted[key] = reading.temperature
                consecutiveRejections[key] = nil
                return reading
            }
            let rejections = (consecutiveRejections[key] ?? 0) + 1
            consecutiveRejections[key] = rejections
            let replacement: Double?
            if rejections <= maxConsecutiveSubstitutions, let last = lastAccepted[key] {
                replacement = last
            } else {
                replacement = groupMax[group]
            }
            guard let replacement else { return reading }
            substituted.insert(key)
            var copy = reading
            copy.temperature = replacement
            return copy
        }
        substitutedKeys = substituted
        return result
    }

    /// Forgets all per-key history (call when the sensor set is rediscovered).
    public mutating func reset() {
        lastAccepted = [:]
        consecutiveRejections = [:]
        substitutedKeys = []
    }
}
