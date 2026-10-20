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
/// State: one `KeyState` per key ever seen by `filter(_:)` (last accepted
/// value, current run of rejections), plus the keys substituted by the latest
/// call. Only `filter(_:)` and `reset()` change it. It is a value type, so the
/// owner's isolation protects it (`FanControlPoller` keeps one on its queue).
public struct TemperatureSampleFilter: Hashable, Sendable {

    /// Default `floor` (°C). A running CPU/GPU die is not below 10 °C in
    /// practice; every bogus value observed on Mac14,9 is below 8.5 °C.
    public static let defaultFloor: Double = 10
    /// Default `filteredPrefixes`: the prefix rows of the die groups in
    /// `SensorCatalog.entries` (`SensorGroup.isDie`: P/E cores, GPU, `TC*` CPU),
    /// in the order `Tp`, `Te`, `Tg`, `TC`.
    public static let defaultFilteredPrefixes: [String] =
        [SensorGroup.cpuPerformanceCore, .cpuEfficiencyCore, .gpu, .cpuOther].flatMap(SensorCatalog.keyPrefixes(of:))
    /// Default `maxConsecutiveSubstitutions` (5 polls = 10 s at the default 2 s interval).
    public static let defaultMaxConsecutiveSubstitutions = 5

    /// What the filter remembers about one key.
    public struct KeyState: Hashable, Sendable {
        /// The key's last accepted temperature, `nil` until one was accepted.
        public var lastAccepted: Double?
        /// Consecutive rejections since the last accepted sample (0 after an accepted one).
        public var consecutiveRejections: Int

        public init(lastAccepted: Double? = nil, consecutiveRejections: Int = 0) {
            self.lastAccepted = lastAccepted
            self.consecutiveRejections = consecutiveRejections
        }
    }

    /// How `filter(_:)` treated one sample (`decide(_:state:groupMaximum:)`).
    public enum Decision: Hashable, Sendable {
        /// Not a filtered key, or non-finite: returned unchanged, state untouched.
        case ignored
        /// Finite and `>= floor`: returned unchanged and remembered.
        case accepted
        /// Below `floor`, replaced by the key's last accepted value (short dropout).
        case substitutedLastAccepted(Double)
        /// Below `floor`, replaced by the hottest accepted sample of its group in this batch.
        case substitutedGroupMaximum(Double)
        /// Below `floor` with no substitute (whole group implausible): returned unchanged.
        case rejectedUnreplaced

        /// The replacement temperature, if the sample was substituted.
        public var substitute: Double? {
            switch self {
            case .substitutedLastAccepted(let value), .substitutedGroupMaximum(let value): return value
            case .ignored, .accepted, .rejectedUnreplaced: return nil
            }
        }
    }

    /// Samples below this temperature (°C) are implausible for filtered keys.
    public var floor: Double
    /// Key prefixes (case-sensitive) the filter applies to. When several match,
    /// the longest defines the key's group.
    public var filteredPrefixes: [String]
    /// How many consecutive rejections of one key may be replaced by that
    /// key's last accepted value before the group maximum (or the raw sample)
    /// is used instead.
    public var maxConsecutiveSubstitutions: Int

    /// Per-key state (keys never seen, or ignored, are absent).
    public private(set) var states: [String: KeyState] = [:]
    /// Keys whose temperature was replaced in the most recent `filter(_:)` call.
    public private(set) var substitutedKeys: Set<String> = []

    /// Last accepted temperature per key (view of `states`).
    public var lastAccepted: [String: Double] { states.compactMapValues(\.lastAccepted) }
    /// Current run of consecutive rejections per key; keys at 0 are absent (view of `states`).
    public var consecutiveRejections: [String: Int] {
        states.compactMapValues { $0.consecutiveRejections > 0 ? $0.consecutiveRejections : nil }
    }

    public init(floor: Double = TemperatureSampleFilter.defaultFloor,
                filteredPrefixes: [String] = TemperatureSampleFilter.defaultFilteredPrefixes,
                maxConsecutiveSubstitutions: Int = TemperatureSampleFilter.defaultMaxConsecutiveSubstitutions) {
        self.floor = floor
        self.filteredPrefixes = filteredPrefixes
        self.maxConsecutiveSubstitutions = maxConsecutiveSubstitutions
    }

    /// The prefix group of `key` (longest matching prefix; the first listed on
    /// a tie), or `nil` if the filter does not apply to it.
    public func group(of key: String) -> String? {
        var best: String?
        for prefix in filteredPrefixes where !prefix.isEmpty && key.hasPrefix(prefix) {
            if prefix.count > (best?.count ?? 0) { best = prefix }
        }
        return best
    }

    /// `true` if `reading` is a finite sample below `floor` of a filtered key.
    public func isImplausible(_ reading: SensorReading) -> Bool {
        group(of: reading.id) != nil && reading.temperature.isFinite && reading.temperature < floor
    }

    /// The rule of the type documentation for one finite sample of a filtered
    /// key, and the key's state after it. Pure: `filter(_:)` applies it to
    /// every sample of a batch.
    ///
    /// - Parameters:
    ///   - temperature: the sample (finite).
    ///   - state: the key's state before the sample.
    ///   - groupMaximum: the hottest accepted sample of the key's group in the
    ///     same batch, if any.
    public func decide(_ temperature: Double, state: KeyState,
                       groupMaximum: Double?) -> (decision: Decision, state: KeyState) {
        if temperature >= floor {
            return (.accepted, KeyState(lastAccepted: temperature, consecutiveRejections: 0))
        }
        var next = state
        next.consecutiveRejections += 1
        if next.consecutiveRejections <= maxConsecutiveSubstitutions, let last = state.lastAccepted {
            return (.substitutedLastAccepted(last), next)
        }
        if let groupMaximum {
            return (.substitutedGroupMaximum(groupMaximum), next)
        }
        return (.rejectedUnreplaced, next)
    }

    /// Filters one batch of samples (one poll). Order, ids, names and sensor
    /// types are preserved; only `temperature` may change. Two passes: the
    /// group maxima of the accepted samples, then `decide` per sample. The
    /// result shares storage with `readings` when nothing is substituted.
    public mutating func filter(_ readings: [SensorReading]) -> [SensorReading] {
        // Pass 1: each sample's group (once) and the per-group maximum of accepted samples.
        let groups = readings.map { $0.temperature.isFinite ? group(of: $0.id) : nil }
        var groupMaximum: [String: Double] = [:]
        for (reading, group) in zip(readings, groups) {
            guard let group, reading.temperature >= floor else { continue }
            groupMaximum[group] = Swift.max(groupMaximum[group] ?? -.infinity, reading.temperature)
        }

        // Pass 2: decide per sample, update the state, substitute.
        var result = readings
        var substituted: Set<String> = []
        for index in readings.indices {
            guard let group = groups[index] else { continue }
            let key = readings[index].id
            let (decision, state) = decide(readings[index].temperature, state: states[key] ?? KeyState(),
                                           groupMaximum: groupMaximum[group])
            states[key] = state
            if let substitute = decision.substitute {
                result[index].temperature = substitute
                substituted.insert(key)
            }
        }
        substitutedKeys = substituted
        return result
    }

    /// Forgets all per-key history (call when the sensor set is rediscovered).
    public mutating func reset() {
        states = [:]
        substitutedKeys = []
    }
}
