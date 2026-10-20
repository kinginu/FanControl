import Foundation
import FanControlCore

/// Recent temperatures per sensor key, for a temperature chart (future Temperature widget).
///
/// One fixed-capacity ring buffer per key (`capacityPerKey` samples, default 1024 =
/// 34 min at the 2 s poll; older samples are overwritten) and at most `maximumKeys` keys,
/// so memory is bounded (≈ 16 bytes × 1024 × 32 keys ≈ 0.5 MB worst case). Values are the
/// filtered readings of `FanControlManager.sensorReadings` (not smoothed).
///
/// `FanControlManager.temperatureHistory` records `defaultKeys` plus the keys requested
/// with `FanControlManager.setTemperatureHistoryKeys(_:for:)` on every published poll
/// (the last step of the read path: discovery → read → filter → aggregate → history).
///
/// Samples of a key are kept in date order (an older sample than the key's latest is
/// dropped), so windowed queries binary-search the start of the window instead of
/// scanning, and `range`/`minimum`/`maximum` do not copy the samples.
public struct TemperatureHistory: Hashable, Sendable {

    /// One sample.
    public struct Sample: Hashable, Sendable {
        public var date: Date
        /// °C.
        public var temperature: Double

        public init(date: Date, temperature: Double) {
            self.date = date
            self.temperature = temperature
        }
    }

    /// CPU (max), GPU (max) and the SSD: `agg:cpu`, `agg:gpu`, `TH0x`.
    public static let defaultKeys: [String] = [SensorAggregator.ID.cpu, SensorAggregator.ID.gpu, "TH0x"]
    /// 34 min at a 2 s poll.
    public static let defaultCapacityPerKey = 1024
    /// Default `maximumKeys`.
    public static let defaultMaximumKeys = 32

    /// Samples kept per key (at least 1); the oldest is overwritten when full.
    public let capacityPerKey: Int
    /// Keys kept (at least 1); samples of further keys are ignored.
    public let maximumKeys: Int
    private var buffers: [String: Ring] = [:]

    public init(capacityPerKey: Int = TemperatureHistory.defaultCapacityPerKey,
                maximumKeys: Int = TemperatureHistory.defaultMaximumKeys) {
        self.capacityPerKey = max(capacityPerKey, 1)
        self.maximumKeys = max(maximumKeys, 1)
    }

    /// Keys with at least one sample.
    public var keys: Set<String> { Set(buffers.keys) }

    /// Appends `temperature` for `key` at `date` (non-finite values and samples older than
    /// the key's latest are ignored; a new key beyond `maximumKeys` is ignored).
    public mutating func append(_ temperature: Double, for key: String, at date: Date) {
        guard temperature.isFinite else { return }
        if buffers[key] == nil {
            guard buffers.count < maximumKeys else { return }
            buffers[key] = Ring(capacity: capacityPerKey)
        }
        buffers[key]?.append(Sample(date: date, temperature: temperature))
    }

    /// Appends the readings of `sensors` whose id is in `keys` (a poll's batch).
    public mutating func record(_ sensors: [SensorReading], keys: Set<String>, at date: Date) {
        guard !keys.isEmpty else { return }
        for reading in sensors where keys.contains(reading.id) {
            append(reading.temperature, for: reading.id, at: date)
        }
    }

    /// Samples of `key`, oldest first; with `window`, only those not older than
    /// `window` seconds before `now`.
    public func history(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> [Sample] {
        guard let ring = buffers[key] else { return [] }
        let first = window.map { ring.firstIndex(notBefore: now.addingTimeInterval(-$0)) } ?? 0
        return (first..<ring.count).map { ring[$0] }
    }

    /// The latest sample of `key`.
    public func latest(for key: String) -> Sample? { buffers[key]?.last }

    /// Lowest and highest temperature of `key` in `history(for:window:now:)`.
    public func range(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> ClosedRange<Double>? {
        guard let ring = buffers[key] else { return nil }
        let first = window.map { ring.firstIndex(notBefore: now.addingTimeInterval(-$0)) } ?? 0
        guard first < ring.count else { return nil }
        var low = Double.infinity
        var high = -Double.infinity
        for index in first..<ring.count {
            let temperature = ring[index].temperature
            low = Swift.min(low, temperature)
            high = Swift.max(high, temperature)
        }
        return low...high
    }

    /// Lowest temperature of `key` in the window.
    public func minimum(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> Double? {
        range(for: key, window: window, now: now)?.lowerBound
    }

    /// Highest temperature of `key` in the window.
    public func maximum(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> Double? {
        range(for: key, window: window, now: now)?.upperBound
    }

    /// Drops every key not in `keys`.
    public mutating func retainOnly(_ keys: Set<String>) {
        buffers = buffers.filter { keys.contains($0.key) }
    }

    /// Drops everything.
    public mutating func removeAll() { buffers = [:] }

    /// Fixed-capacity ring buffer of date-ordered samples. Logical index 0 is the
    /// oldest sample.
    private struct Ring: Hashable, Sendable {
        let capacity: Int
        var storage: [Sample] = []
        /// Index of the oldest sample once `storage` is full.
        var head = 0

        init(capacity: Int) {
            self.capacity = capacity
            storage.reserveCapacity(min(capacity, 64))
        }

        var count: Int { storage.count }

        /// The sample at logical `index` (0 = oldest).
        subscript(index: Int) -> Sample {
            storage.count < capacity ? storage[index] : storage[(head + index) % capacity]
        }

        var last: Sample? {
            storage.isEmpty ? nil : self[storage.count - 1]
        }

        /// Appends `sample` unless it is older than the latest one (keeps the order).
        mutating func append(_ sample: Sample) {
            if let last, sample.date < last.date { return }
            if storage.count < capacity {
                storage.append(sample)
            } else {
                storage[head] = sample
                head = (head + 1) % capacity
            }
        }

        /// Logical index of the first sample with `date >= cutoff` (`count` if none).
        func firstIndex(notBefore cutoff: Date) -> Int {
            var low = 0
            var high = count
            while low < high {
                let mid = (low + high) / 2
                if self[mid].date < cutoff { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }
}
