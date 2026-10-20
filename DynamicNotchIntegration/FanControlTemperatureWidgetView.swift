#if os(macOS)
// Drop-in file for the DynamicNotch app target (not part of the SwiftPM package): host-specific
// glue on top of FanControlUI (the chart and its series are `FanControlTemperatureChart` /
// `FanControlTemperatureSeries`).
//
// The Temperature Nook widget (2026-10-20, user decision: temperatures move out of the Fan
// Control widget). Dispatched from the Nook grid for `NookWidget.temperature`
// (PATCHES.md (a)–(c)); 5 grid cells (250 pt) × the 202 pt row.
//
// Layout (Apple-style, like the other Nook widgets — NookWidgetChrome: 8 pt vertical inset,
// subheadline-semibold secondary header, system text styles, quaternary grid):
//   header   thermometer + "Temperature", window chips "1  5 min  15  30" (only the selected
//            chip shows "min" and sits on the sliding glass pill; click = change the window,
//            stored in the widget settings)
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
import FanControlCore
import FanControlKit
import FanControlUI

struct FanControlTemperatureWidgetView: View {

    @FanControlSetting(.temperatureWidget) private var settings
    @FanControlSetting(.widget) private var fanWidgetSettings
    @FanControlSetting(.general) private var general

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

    @Namespace private var windowNamespace

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

    /// "1  5 min  15  30" chips: only the selected chip carries the unit and sits on the
    /// glass pill (one pill, shared `matchedGeometryEffect`, slides with `.snappy`). Every
    /// number is reserved two digits wide, so the row keeps its width whichever is selected.
    private var windowPicker: some View {
        HStack(spacing: 1) {
            ForEach(FanControlTemperatureWidgetSettings.HistoryWindow.allCases) { choice in
                WindowChip(title: choice.shortLabel, isSelected: choice == window,
                           namespace: windowNamespace) {
                    guard !preview else { return }
                    withAnimation(.snappy(duration: 0.25)) { settings.historyWindow = choice }
                }
                .accessibilityLabel(choice.rawValue == 1 ? Text("1 minute") : Text("\(choice.rawValue) minutes"))
            }
        }
        .animation(.snappy(duration: 0.25), value: window)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("History"))
    }

    // MARK: Values

    private func values(_ series: [FanControlTemperatureSeries]) -> some View {
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
    private func maxColor(_ item: FanControlTemperatureSeries, _ value: Double) -> Color {
        let reading = SensorReading(id: item.key, name: item.label, temperature: value,
                                    sensorType: item.key.hasPrefix("agg:") ? .greatest : .smc)
        let color = FanControlFormatting.temperatureColor(reading, policy: manager.safetyPolicy)
        return color == .primary ? .secondary : color
    }

    private func accessibilityValue(_ item: FanControlTemperatureSeries) -> String {
        var parts = [item.current.map { FanControlFormatting.temperature($0.temperature, unit: unit) } ?? "--"]
        if let range = item.range {
            parts.append(String(localized: "highest \(FanControlFormatting.temperature(range.upperBound, unit: unit)), lowest \(FanControlFormatting.temperature(range.lowerBound, unit: unit))"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Chart

    private func chart(_ series: [FanControlTemperatureSeries], now: Date) -> some View {
        let threshold = manager.safetyPolicy.highTemperatureAlert
        return FanControlTemperatureChart(series: series, window: window.seconds, now: now, unit: unit,
                                          alertThreshold: settings.showsAlertThreshold ? threshold : nil)
    }

    // MARK: Series

    private func makeSeries(now: Date) -> [FanControlTemperatureSeries] {
        FanControlTemperatureSeries.make(keys: settings.shownKeys, history: history, window: window.seconds,
                                         now: now, readings: previewHistory == nil ? manager.sensorReadings : nil)
    }
}

// MARK: - Window chip

private struct WindowChip: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                // Two-digit slot ("88" hidden), so 1 and 30 take the same width.
                ZStack {
                    Text(verbatim: "88").hidden()
                    Text(verbatim: title)
                }
                if isSelected {
                    Text("min")
                        .fontWeight(.medium)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .font(.caption2.weight(isSelected ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(isSelected
                             ? (colorScheme == .dark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                             : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .frame(minHeight: 16)
            .padding(.horizontal, 3)
            .contentShape(Capsule())
            .background {
                if isSelected {
                    FanControlSelectionPill()
                        .matchedGeometryEffect(id: "windowSelection", in: namespace)
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
