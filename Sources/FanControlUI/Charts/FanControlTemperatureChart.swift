#if os(macOS)
// Temperature history chart (Swift Charts) over `FanControlManager.temperatureHistory`:
// one line per series (CPU (max), GPU (max), SSD `TH0x` by default), broken at gaps > 25 s
// such as sleep or a paused Nook, downsampled to bucket means, the high-temperature alert
// threshold as a dashed red rule with its value, "−5 min" … "now" under it.
// Series colours are categorical (blue / aqua / violet); red and orange stay reserved for the
// alert / warm status. Used by DynamicNotch's Temperature widget (host glue in that
// app's repository), which adds the header, window chips and values.

import SwiftUI
import Charts
import FanControlCore
import FanControlKit

// MARK: - Series

/// One series of the chart: the samples of a key over a window, downsampled and split at gaps.
public struct FanControlTemperatureSeries: Identifiable, Sendable {
    public let key: String
    public let label: String
    public let color: Color
    /// The latest reading (current value; drives the colour rule).
    public let current: SensorReading?
    /// Lowest / highest raw value of the window.
    public let range: ClosedRange<Double>?
    /// Downsampled history of the window, split at gaps.
    public let segments: [[TemperatureHistory.Sample]]

    public var id: String { key }

    public init(key: String, label: String, color: Color, current: SensorReading?,
                range: ClosedRange<Double>?, segments: [[TemperatureHistory.Sample]]) {
        self.key = key
        self.label = label
        self.color = color
        self.current = current
        self.range = range
        self.segments = segments
    }

    /// The series of `keys` over the last `window` seconds of `history`. `readings` supplies the
    /// current values (the manager's `sensorReadings`); `nil` takes them from the history's
    /// latest samples (previews).
    public static func make(keys: [String], history: TemperatureHistory, window: TimeInterval,
                            now: Date, readings: [SensorReading]?) -> [FanControlTemperatureSeries] {
        keys.map { key in
            let samples = history.history(for: key, window: window, now: now)
            let reading: SensorReading?
            if let readings {
                reading = readings.first { $0.id == key && $0.temperature.isFinite }
            } else {
                reading = history.latest(for: key).map {
                    SensorReading(id: key, name: key, temperature: $0.temperature,
                                  sensorType: key.hasPrefix("agg:") ? .greatest : .smc)
                }
            }
            let label = reading.map(FanControlFormatting.keyTemperatureLabel) ?? Self.label(for: key)
            let temperatures = samples.map(\.temperature)
            let range = temperatures.min().flatMap { low in temperatures.max().map { low...$0 } }
            return FanControlTemperatureSeries(
                key: key, label: label, color: color(for: key), current: reading, range: range,
                segments: segments(downsample(samples, window: window, now: now)))
        }
    }

    /// Series colours (categorical slots blue / aqua / violet; red and orange stay reserved
    /// for the alert / warm status).
    public static func color(for key: String) -> Color {
        switch key {
        case SensorAggregator.ID.cpu: return Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
        case SensorAggregator.ID.gpu: return Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
        default: return Color(red: 0x90 / 255, green: 0x85 / 255, blue: 0xE9 / 255)
        }
    }

    /// Short label of a series key ("CPU" / "GPU" / "SSD", else the key).
    public static func label(for key: String) -> String {
        switch key {
        case SensorAggregator.ID.cpu: return String(localized: "CPU")
        case SensorAggregator.ID.gpu: return String(localized: "GPU")
        case "TH0x": return String(localized: "SSD")
        default: return key
        }
    }

    /// A gap longer than this breaks the line (sleep, paused Nook, battery polling is ≤ 10 s).
    public static let gapThreshold: TimeInterval = 25
    /// Points per series drawn at most (bucket means; min / max use the raw samples).
    public static let maximumPoints = 180

    /// Bucket means over `maximumPoints` equal time buckets of the window (samples already
    /// sparser than that are kept as they are).
    public static func downsample(_ samples: [TemperatureHistory.Sample], window: TimeInterval,
                                  now: Date) -> [TemperatureHistory.Sample] {
        guard samples.count > maximumPoints, window > 0 else { return samples }
        let bucket = window / Double(maximumPoints)
        let start = now.addingTimeInterval(-window)
        var result: [TemperatureHistory.Sample] = []
        var currentIndex = -1
        var sumT = 0.0, sumDate = 0.0, n = 0.0
        func flush() {
            guard n > 0 else { return }
            result.append(.init(date: Date(timeIntervalSinceReferenceDate: sumDate / n), temperature: sumT / n))
        }
        for sample in samples {
            let index = Int(sample.date.timeIntervalSince(start) / bucket)
            if index != currentIndex {
                flush()
                currentIndex = index
                sumT = 0; sumDate = 0; n = 0
            }
            sumT += sample.temperature
            sumDate += sample.date.timeIntervalSinceReferenceDate
            n += 1
        }
        flush()
        return result
    }

    /// Splits at gaps longer than `gapThreshold`.
    public static func segments(_ samples: [TemperatureHistory.Sample]) -> [[TemperatureHistory.Sample]] {
        var result: [[TemperatureHistory.Sample]] = []
        var current: [TemperatureHistory.Sample] = []
        for sample in samples {
            if let last = current.last, sample.date.timeIntervalSince(last.date) > gapThreshold {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Chart

/// The history chart of `series` over the `window` seconds before `now`, with the
/// high-temperature alert threshold (`alertThreshold`, `nil` = hidden) and a "−N min … now"
/// time line under it. Fills the height it is given.
public struct FanControlTemperatureChart: View {
    let series: [FanControlTemperatureSeries]
    let window: TimeInterval
    let now: Date
    let unit: TemperatureUnit
    let alertThreshold: Double?

    public init(series: [FanControlTemperatureSeries], window: TimeInterval, now: Date,
                unit: TemperatureUnit, alertThreshold: Double?) {
        self.series = series
        self.window = window
        self.now = now
        self.unit = unit
        self.alertThreshold = alertThreshold
    }

    public var body: some View {
        let threshold = alertThreshold.flatMap { $0.isFinite ? $0 : nil }
        let hasData = series.contains { !$0.segments.isEmpty }
        VStack(spacing: 1) {
            Chart {
                if let threshold {
                    thresholdRule(threshold)
                }
                ForEach(series) { item in
                    seriesLines(item)
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-window)...now)
            .chartYScale(domain: Self.yDomain(series, threshold: threshold))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let celsius = value.as(Double.self) {
                            Text(verbatim: FanControlFormatting.temperature(celsius, unit: unit))
                                .font(.system(size: 8))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .overlay {
                if !hasData {
                    Text("Collecting temperatures…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel(Text("Temperature history"))

            HStack {
                Text(verbatim: windowLabel)
                Spacer()
                Text("now")
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .padding(.trailing, 22)
        }
    }

    @ChartContentBuilder
    private func thresholdRule(_ threshold: Double) -> some ChartContent {
        RuleMark(y: .value("Alert", threshold))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.red.opacity(0.75))
            .annotation(position: .top, alignment: .leading, spacing: 0) {
                Text(verbatim: FanControlFormatting.temperature(threshold, unit: unit))
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.red.opacity(0.9))
            }
    }

    /// One line per segment (`series:` keeps the segments apart, so gaps stay open).
    @ChartContentBuilder
    private func seriesLines(_ item: FanControlTemperatureSeries) -> some ChartContent {
        ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
            let name = "\(item.key)#\(index)"
            ForEach(segment, id: \.date) { sample in
                LineMark(x: .value("Time", sample.date),
                         y: .value("Temperature", sample.temperature),
                         series: .value("Series", name))
                    .foregroundStyle(item.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
    }

    /// "−5 min" (the window in whole minutes).
    private var windowLabel: String {
        let minutes = Int((window / 60).rounded())
        return "−\(minutes.formatted()) \(String(localized: "min"))"
    }

    /// Visible values of the window, the threshold included; padded to 5 °C steps.
    static func yDomain(_ series: [FanControlTemperatureSeries], threshold: Double?) -> ClosedRange<Double> {
        var values = series.flatMap { $0.segments.flatMap { $0.map(\.temperature) } }
        if let threshold { values.append(threshold) }
        guard let low = values.min(), let high = values.max() else { return 30...100 }
        let lower = ((low - 2) / 5).rounded(.down) * 5
        let upper = max(((high + 2) / 5).rounded(.up) * 5, lower + 10)
        return lower...upper
    }
}
#endif
