#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package).
//
// The Temperature Nook widget (2026-10-20, user decision: temperatures move out of the Fan
// Control widget). Dispatched from the Nook grid for `NookWidget.temperature`
// (PATCHES.md (a)–(c)); 5 grid cells (250 pt) × the 202 pt row.
//
// Layout (Apple-style, like the other Nook widgets — NookWidgetChrome: 8 pt vertical inset,
// subheadline-semibold secondary header, system text styles, quaternary grid):
//   header   thermometer + "Temperature", window chips 1 · 5 · 15 · 30 min (glass pill on the
//            selected one; click = change the window, stored in the widget settings)
//   values   one column per series (CPU (max), GPU (max), SSD `TH0x`): series dot + label,
//            current value (title3, monospaced), "↑ max ↓ min" of the window
//   chart    Swift Charts history of `FanControlManager.temperatureHistory` over the window
//            (one line per series, broken at gaps > 25 s such as sleep or a paused Nook),
//            the high-temperature alert threshold as a dashed red rule with its value,
//            "−5 min" … "Now" under it
// Colours: series identity = blue / aqua / violet (categorical, never red/orange, which are
// reserved for status); values follow the Fan Control rule (`FanControlFormatting
// .temperatureColor`: red at/above the alert threshold, orange within 10 °C below it, CPU/GPU
// only), text otherwise primary/secondary. The header turns red with `thermometer.high` while
// the alert is active (icon + colour, never colour alone).

import SwiftUI
import Charts
import FanControlCore
import FanControlKit

struct FanControlTemperatureWidgetView: View {

    @StoredSetting(.fanControlTemperatureWidgetSettings) private var settings
    @StoredSetting(.fanControlWidgetSettings) private var fanWidgetSettings
    @StoredSetting(.fanControlGeneralSettings) private var general

    /// Preview / debug rendering only: draw this history instead of the manager's (and do not
    /// count as a shown widget; window chips do nothing).
    var previewHistory: TemperatureHistory? = nil
    /// Preview / debug rendering only: do not count as a shown widget.
    var isPreview: Bool = false
    /// Preview / debug rendering only: window instead of the setting.
    var previewWindow: FanControlTemperatureWidgetSettings.HistoryWindow? = nil

    private var manager: FanControlManager { FanControlManager.shared }
    private var preview: Bool { isPreview || previewHistory != nil || previewWindow != nil }
    private var window: FanControlTemperatureWidgetSettings.HistoryWindow { previewWindow ?? settings.historyWindow }
    private var unit: TemperatureUnit { fanWidgetSettings.temperatureUnit }
    private var history: TemperatureHistory { previewHistory ?? manager.temperatureHistory }

    var body: some View {
        content
            .frame(width: FanControlTemperatureWidgetSettings.widthInPoints)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { FanControlWidgetPresence.widgetAppeared(isPreview: preview) }
            .onDisappear { FanControlWidgetPresence.widgetDisappeared(isPreview: preview) }
    }

    @ViewBuilder
    private var content: some View {
        if previewHistory == nil && !general.isEnabled {
            TemperatureEmptyState(systemImage: "thermometer.medium", message: "Fan control disabled",
                                  detail: "Turn on Fan Control in Settings to read temperatures.")
        } else if previewHistory == nil && !manager.isSMCConnected {
            TemperatureEmptyState(systemImage: "exclamationmark.triangle", message: "SMC unavailable", detail: nil)
        } else {
            let now = Date()
            let series = makeSeries(now: now)
            VStack(alignment: .leading, spacing: 6) {
                header
                values(series)
                chart(series, now: now)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.highTempAlertActive ? "thermometer.high" : "thermometer.medium")
                .symbolRenderingMode(.hierarchical)
            Text("Temperature")
                .accessibilityAddTraits(.isHeader)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            windowPicker
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(manager.highTempAlertActive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
    }

    /// 1 · 5 · 15 · 30 min chips; the selected one on the glass pill (bold, white).
    private var windowPicker: some View {
        HStack(spacing: 1) {
            ForEach(FanControlTemperatureWidgetSettings.HistoryWindow.allCases) { choice in
                WindowChip(title: choice.shortLabel, isSelected: choice == window) {
                    guard !preview else { return }
                    withAnimation(.snappy(duration: 0.25)) { settings.historyWindow = choice }
                }
                .accessibilityLabel(Text("\(choice.rawValue) min"))
            }
            Text("min")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("History"))
    }

    // MARK: Values

    private func values(_ series: [Series]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(series) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(verbatim: item.label)
                            .lineLimit(1)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    Text(verbatim: item.current.map { FanControlFormatting.temperature($0.temperature, unit: unit) } ?? "--")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(item.current.map { FanControlFormatting.temperatureColor($0, policy: manager.safetyPolicy) }
                                         ?? .secondary)
                    if settings.showsMinMax {
                        HStack(spacing: 4) {
                            if let range = item.range {
                                Text(verbatim: "↑\(FanControlFormatting.temperature(range.upperBound, unit: unit))")
                                    .foregroundStyle(maxColor(item, range.upperBound))
                                Text(verbatim: "↓\(FanControlFormatting.temperature(range.lowerBound, unit: unit))")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(verbatim: "↑-- ↓--").foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 9).weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: item.label))
                .accessibilityValue(Text(verbatim: accessibilityValue(item)))
            }
        }
    }

    /// The window maximum is coloured with the same rule as the current value (secondary below it).
    private func maxColor(_ item: Series, _ value: Double) -> Color {
        let reading = SensorReading(id: item.key, name: item.label, temperature: value,
                                    sensorType: item.key.hasPrefix("agg:") ? .greatest : .smc)
        let color = FanControlFormatting.temperatureColor(reading, policy: manager.safetyPolicy)
        return color == .primary ? .secondary : color
    }

    private func accessibilityValue(_ item: Series) -> String {
        var parts = [item.current.map { FanControlFormatting.temperature($0.temperature, unit: unit) } ?? "--"]
        if let range = item.range {
            parts.append(String(localized: "highest \(FanControlFormatting.temperature(range.upperBound, unit: unit)), lowest \(FanControlFormatting.temperature(range.lowerBound, unit: unit))"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ series: [Series], now: Date) -> some View {
        let threshold = manager.safetyPolicy.highTemperatureAlert
        let showsThreshold = settings.showsAlertThreshold && threshold.isFinite
        let hasData = series.contains { !$0.segments.isEmpty }
        VStack(spacing: 1) {
            Chart {
                if showsThreshold {
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
                ForEach(series) { item in
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment, id: \.date) { sample in
                            LineMark(x: .value("Time", sample.date),
                                     y: .value("Temperature", sample.temperature),
                                     series: .value("Series", "\(item.key)#\(index)"))
                                .foregroundStyle(item.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-window.seconds)...now)
            .chartYScale(domain: yDomain(series, threshold: showsThreshold ? threshold : nil))
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
                Text(verbatim: "−\(window.rawValue.formatted()) \(String(localized: "min"))")
                Spacer()
                Text("now")
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .padding(.trailing, 22)
        }
    }

    /// Visible values of the window, the threshold included; padded to 5 °C steps.
    private func yDomain(_ series: [Series], threshold: Double?) -> ClosedRange<Double> {
        var values = series.flatMap { $0.segments.flatMap { $0.map(\.temperature) } }
        if let threshold { values.append(threshold) }
        guard let low = values.min(), let high = values.max() else { return 30...100 }
        let lower = ((low - 2) / 5).rounded(.down) * 5
        let upper = max(((high + 2) / 5).rounded(.up) * 5, lower + 10)
        return lower...upper
    }

    // MARK: Series

    fileprivate struct Series: Identifiable {
        let key: String
        let label: String
        let color: Color
        /// The latest reading (current value; drives the colour rule).
        let current: SensorReading?
        /// Lowest / highest raw value of the window.
        let range: ClosedRange<Double>?
        /// Downsampled history of the window, split at gaps.
        let segments: [[TemperatureHistory.Sample]]

        var id: String { key }
    }

    /// Series colours (categorical slots blue / aqua / violet; red and orange stay reserved
    /// for the alert / warm status).
    static func color(for key: String) -> Color {
        switch key {
        case SensorAggregator.ID.cpu: return Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
        case SensorAggregator.ID.gpu: return Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
        default: return Color(red: 0x90 / 255, green: 0x85 / 255, blue: 0xE9 / 255)
        }
    }

    /// A gap longer than this breaks the line (sleep, paused Nook, battery polling is ≤ 10 s).
    static let gapThreshold: TimeInterval = 25
    /// Points per series drawn at most (bucket means; min / max use the raw samples).
    static let maximumPoints = 180

    private func makeSeries(now: Date) -> [Series] {
        let history = history
        return settings.shownKeys.map { key in
            let samples = history.history(for: key, window: window.seconds, now: now)
            let reading = previewHistory == nil
                ? manager.sensorReadings.first { $0.id == key && $0.temperature.isFinite }
                : history.latest(for: key).map {
                    SensorReading(id: key, name: key, temperature: $0.temperature,
                                  sensorType: key.hasPrefix("agg:") ? .greatest : .smc)
                }
            let label = reading.map(FanControlFormatting.keyTemperatureLabel) ?? Self.label(for: key)
            let temperatures = samples.map(\.temperature)
            let range = temperatures.min().flatMap { low in temperatures.max().map { low...$0 } }
            return Series(key: key, label: label, color: Self.color(for: key), current: reading, range: range,
                          segments: Self.segments(Self.downsample(samples, window: window.seconds, now: now)))
        }
    }

    static func label(for key: String) -> String {
        switch key {
        case SensorAggregator.ID.cpu: return String(localized: "CPU")
        case SensorAggregator.ID.gpu: return String(localized: "GPU")
        case "TH0x": return String(localized: "SSD")
        default: return key
        }
    }

    /// Bucket means over `maximumPoints` equal time buckets of the window (samples already
    /// sparser than that are kept as they are).
    static func downsample(_ samples: [TemperatureHistory.Sample], window: TimeInterval,
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
    static func segments(_ samples: [TemperatureHistory.Sample]) -> [[TemperatureHistory.Sample]] {
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

// MARK: - Window chip

private struct WindowChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption2.weight(isSelected ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected
                                 ? (colorScheme == .dark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                                 : AnyShapeStyle(.secondary))
                .frame(minWidth: 17, minHeight: 16)
                .padding(.horizontal, 2)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        FanControlSelectionPill()
                    } else if isHovering {
                        Capsule().fill(.quinary)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Empty state

private struct TemperatureEmptyState: View {
    let systemImage: String
    let message: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
            Text(message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
#endif
