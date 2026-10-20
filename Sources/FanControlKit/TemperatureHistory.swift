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
/// with `FanControlManager.setTemperatureHistoryKeys(_:for:)` on every published poll.
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
    public static let defaultMaximumKeys = 32

    public let capacityPerKey: Int
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

    /// Appends the readings of `sensors` whose id is in `keys`.
    public mutating func record(_ sensors: [SensorReading], keys: Set<String>, at date: Date) {
        for reading in sensors where keys.contains(reading.id) {
            append(reading.temperature, for: reading.id, at: date)
        }
    }

    /// Samples of `key`, oldest first; with `window`, only those not older than
    /// `window` seconds before `now`.
    public func history(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> [Sample] {
        guard let ring = buffers[key] else { return [] }
        let all = ring.ordered()
        guard let window else { return all }
        let cutoff = now.addingTimeInterval(-window)
        return all.filter { $0.date >= cutoff }
    }

    /// The latest sample of `key`.
    public func latest(for key: String) -> Sample? { buffers[key]?.last }

    /// Lowest and highest temperature of `key` in `history(for:window:now:)`.
    public func range(for key: String, window: TimeInterval? = nil, now: Date = Date()) -> ClosedRange<Double>? {
        let temperatures = history(for: key, window: window, now: now).map(\.temperature)
        guard let low = temperatures.min(), let high = temperatures.max() else { return nil }
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

    /// Fixed-capacity ring buffer.
    private struct Ring: Hashable, Sendable {
        let capacity: Int
        var storage: [Sample] = []
        /// Index of the oldest sample once `storage` is full.
        var head = 0

        init(capacity: Int) {
            self.capacity = capacity
            storage.reserveCapacity(min(capacity, 64))
        }

        var last: Sample? {
            guard !storage.isEmpty else { return nil }
            return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
        }

        mutating func append(_ sample: Sample) {
            if let last, sample.date < last.date { return }
            if storage.count < capacity {
                storage.append(sample)
            } else {
                storage[head] = sample
                head = (head + 1) % capacity
            }
        }

        func ordered() -> [Sample] {
            storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
        }
    }
}
