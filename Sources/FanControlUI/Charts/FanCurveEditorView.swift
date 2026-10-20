#if os(macOS)
// Multi-point fan curve editor (Settings ▸ Fan Control ▸ Profiles, sensor-based mode of a
// Custom 1 / Custom 2 fan; 2026-10-20). Replaces the old start / maximum temperature steppers:
// the curve's first / last points are the mode's start / maximum temperature
// (`FanProfile.setCurve`, which the profiles tab calls through the `curve` binding).
//
//   - live chart (Swift Charts): the PCHIP curve exactly as the engine evaluates it
//     (`FanCurve.sample(count: 48, rpmRange: fan.rpmRange, …)`), its control points, the
//     emergency threshold (dashed red) and the operating point (the curve's target at the
//     smoothed control temperature `FanControlManager.controlTemperature(for:)`, plus the
//     fan's measured speed). Points can be dragged vertically in the chart.
//   - one row per control point: temperature on the 10 °C grid (30…100 °C; a point loaded
//     from elsewhere, e.g. Boost's 85 °C, keeps its own temperature), RPM slider + stepper
//     (50 RPM steps, the fan's Mn…Mx), remove (at least two points stay).
//   - "Add Point" inserts on the free grid temperature farthest from the existing points, at
//     the curve's current value there (the shape does not jump).
//   - "Use Preset": Quiet / Balanced / Boost / Full Speed (`FanCurve.GridPreset`, resolved
//     for this fan).
//   - validation: errors (`FanCurve.validationIssues`) block Save / Apply
//     (`FanCurveEditorView.hasErrors`); warnings explain falling speeds, a curve that never
//     reaches the maximum, or full speed only above the emergency threshold.
// The editor stores the curve resolved for the fan (RPMs clamped into Mn…Mx, sorted).

import SwiftUI
import Charts
import FanControlCore
import FanControlKit

public struct FanCurveEditorView: View {

    let fan: FanDevice
    /// Colour of this fan in `FanCurveView` (fan order).
    let color: Color
    /// The sensor the curve follows (operating point).
    let sensorKey: String
    /// The fan's curve as stored in the profile draft.
    @Binding var curve: FanCurve
    let unit: TemperatureUnit
    let emergencyTemperature: Double
    let currentRPM: Int?
    /// `false` for the read-only presets: chart + point summary only.
    var isEditable: Bool = true

    public init(fan: FanDevice, color: Color, sensorKey: String, curve: Binding<FanCurve>,
                unit: TemperatureUnit, emergencyTemperature: Double, currentRPM: Int?,
                isEditable: Bool = true) {
        self.fan = fan
        self.color = color
        self.sensorKey = sensorKey
        _curve = curve
        self.unit = unit
        self.emergencyTemperature = emergencyTemperature
        self.currentRPM = currentRPM
        self.isEditable = isEditable
    }

    /// Grid of the editor (°C).
    public static let gridTemperatures = FanCurve.gridTemperatures(from: 30, through: 100)
    public static let rpmStep = 50

    @State private var draggedIndex: Int? = nil

    private var manager: FanControlManager { FanControlManager.shared }
    private var range: ClosedRange<Int> { fan.rpmRange }

    /// The points shown / edited: normalized (sorted, one per temperature), RPMs clamped.
    private var points: [FanCurve.Point] { curve.resolved(for: fan).points }

    private var domain: ClosedRange<Double> {
        let temperatures = points.map(\.temperature)
        return min(30, temperatures.min() ?? 30)...max(100, temperatures.max() ?? 100)
    }

    private var controlTemperature: Double? {
        manager.controlTemperature(for: sensorKey).flatMap { $0.isFinite ? $0 : nil }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditable {
                toolbar
            }
            chart
                .frame(height: isEditable ? 150 : 110)
            operatingLine
            if isEditable {
                pointRows
                messagesView
            } else {
                Text(verbatim: FanControlFormatting.curvePointsSummary(curve, rpmRange: range, unit: unit))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Fan Curve")
                .font(.subheadline.weight(.semibold))
            Text("\(points.count) points")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Use Preset") {
                ForEach(FanCurve.GridPreset.allCases, id: \.self) { preset in
                    Button(Self.presetName(preset)) { setPoints(preset.curve.resolved(for: fan).points) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                addPoint()
            } label: {
                Label("Add Point", systemImage: "plus")
            }
            .disabled(nextFreeTemperature == nil)
        }
    }

    public static func presetName(_ preset: FanCurve.GridPreset) -> String {
        switch preset {
        case .quiet: return String(localized: "Quiet")
        case .balanced: return String(localized: "Balanced")
        case .boost: return NSLocalizedString("Boost", comment: "Fan curve preset")
        case .fullSpeed: return String(localized: "Full Speed")
        }
    }

    // MARK: Chart

    private var chart: some View {
        let domain = domain
        let samples = curve.sample(count: FanCurveView.sampleCount, rpmRange: range, temperatureDomain: domain)
        let points = points
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        let operating = controlTemperature.map { ($0, Double(curve.rpm(at: $0, for: fan))) }
        return Chart {
            ForEach(samples, id: \.temperature) { sample in
                AreaMark(x: .value("Temperature", sample.temperature),
                         yStart: .value("RPM", low), yEnd: .value("RPM", sample.rpm))
                    .foregroundStyle(color.opacity(0.12))
                LineMark(x: .value("Temperature", sample.temperature), y: .value("RPM", sample.rpm))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if domain.contains(emergencyTemperature) {
                RuleMark(x: .value("Emergency", emergencyTemperature))
                    .foregroundStyle(Color.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 0) {
                        Text(verbatim: FanControlFormatting.temperature(emergencyTemperature, unit: unit))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
            }
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                PointMark(x: .value("Temperature", point.temperature), y: .value("RPM", Double(point.rpm)))
                    .symbolSize(index == draggedIndex ? 90 : 45)
                    .foregroundStyle(color)
            }
            if let (temperature, rpm) = operating, domain.contains(temperature) {
                RuleMark(x: .value("Now", temperature))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Now", temperature), y: .value("RPM", rpm))
                    .symbol {
                        // Ring in the fan's colour on the window background (visible in both appearances).
                        Circle()
                            .strokeBorder(color, lineWidth: 2.5)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            .frame(width: 11, height: 11)
                    }
                    .annotation(position: rpm > (low + high) / 2 ? .bottom : .top, spacing: 2) {
                        Text("now")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                if let currentRPM {
                    // Measured speed, kept inside the plot (an SMC-controlled fan may idle at 0 RPM, below Mn).
                    PointMark(x: .value("Now", temperature), y: .value("RPM", min(max(Double(currentRPM), low), high)))
                        .symbol(.diamond)
                        .symbolSize(40)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: low...max(high, low + 1))
        .chartXAxis {
            AxisMarks(values: Self.gridTemperatures.filter { domain.contains($0) }) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                // Centred under its grid line (the default anchor puts the label to its right).
                AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                    if let celsius = value.as(Double.self) {
                        Text(verbatim: FanControlFormatting.temperature(celsius, unit: unit))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let rpm = value.as(Double.self) {
                        Text(verbatim: Int(rpm).formatted())
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            if isEditable {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in drag(value, proxy: proxy, geometry: geometry) }
                                .onEnded { _ in draggedIndex = nil }
                        )
                }
            }
        }
        .padding(.trailing, 10)   // room for the last x-axis label
        .accessibilityLabel(Text("Fan Curve"))
    }

    /// Vertical drag of the control point nearest to where the drag started (within 16 pt).
    private func drag(_ value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let points = points
        if draggedIndex == nil {
            let start = CGPoint(x: value.startLocation.x - frame.minX, y: value.startLocation.y - frame.minY)
            let nearest = points.enumerated().compactMap { index, point -> (Int, CGFloat)? in
                guard let x = proxy.position(forX: point.temperature),
                      let y = proxy.position(forY: Double(point.rpm)) else { return nil }
                return (index, hypot(x - start.x, y - start.y))
            }.min { $0.1 < $1.1 }
            guard let nearest, nearest.1 <= 16 else { return }
            draggedIndex = nearest.0
        }
        guard let index = draggedIndex, points.indices.contains(index),
              let rpm: Double = proxy.value(atY: value.location.y - frame.minY) else { return }
        setRPM(Int(rpm), at: index)
    }

    // MARK: Operating point

    @ViewBuilder
    private var operatingLine: some View {
        let sensorName = FanControlSensorNames.localized(
            manager.sensorReadings.first { $0.id == sensorKey }
                ?? SensorReading(id: sensorKey, name: sensorKey, temperature: .nan,
                                 sensorType: sensorKey.hasPrefix("agg:") ? .greatest : .smc))
        if let temperature = controlTemperature {
            let target = curve.rpm(at: temperature, for: fan)
            HStack(spacing: 4) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.secondary)
                Text("Now: \(sensorName) \(FanControlFormatting.temperature(temperature, unit: unit)) → \(target.formatted()) RPM on this curve")
                if let currentRPM {
                    Text("(fan at \(currentRPM.formatted()) RPM)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(sensorName) is not available: the fan would run at maximum speed.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Point rows

    private var pointRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(spacing: 8) {
                    Picker("Temperature", selection: temperatureBinding(at: index)) {
                        ForEach(temperatureOptions(for: index), id: \.self) { temperature in
                            Text(verbatim: FanControlFormatting.temperature(temperature, unit: unit)).tag(temperature)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 82)
                    if range.lowerBound < range.upperBound {
                        Slider(value: sliderBinding(at: index),
                               in: Double(range.lowerBound)...Double(range.upperBound))
                            .controlSize(.small)
                    }
                    Stepper(value: rpmBinding(at: index), in: range, step: Self.rpmStep) {
                        Text(verbatim: "\(point.rpm.formatted()) RPM")
                            .monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                    Button {
                        removePoint(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(points.count <= 2)
                    .help(Text("Remove Point"))
                    .accessibilityLabel(Text("Remove Point"))
                }
            }
        }
    }

    /// Free grid temperatures (not used by another point) plus the point's own temperature.
    private func temperatureOptions(for index: Int) -> [Double] {
        let others = Set(points.enumerated().filter { $0.offset != index }.map(\.element.temperature))
        var options = Self.gridTemperatures.filter { !others.contains($0) }
        if points.indices.contains(index), !options.contains(points[index].temperature) {
            options.append(points[index].temperature)
        }
        return options.sorted()
    }

    private func temperatureBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { points.indices.contains(index) ? points[index].temperature : 0 },
            set: { temperature in
                var points = points
                guard points.indices.contains(index) else { return }
                points[index].temperature = temperature
                setPoints(points)
            }
        )
    }

    private func rpmBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: { points.indices.contains(index) ? points[index].rpm : range.lowerBound },
            set: { setRPM($0, at: index) }
        )
    }

    private func sliderBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { Double(points.indices.contains(index) ? points[index].rpm : range.lowerBound) },
            set: { setRPM(Int($0.rounded()), at: index) }
        )
    }

    /// Rounds to `rpmStep` (the ends of the fan's range stay reachable) and clamps.
    private func setRPM(_ rpm: Int, at index: Int) {
        var points = points
        guard points.indices.contains(index) else { return }
        var value = Int((Double(rpm) / Double(Self.rpmStep)).rounded()) * Self.rpmStep
        if abs(rpm - range.lowerBound) < Self.rpmStep / 2 { value = range.lowerBound }
        if abs(rpm - range.upperBound) < Self.rpmStep / 2 { value = range.upperBound }
        points[index].rpm = min(max(value, range.lowerBound), range.upperBound)
        guard points[index].rpm != self.points[index].rpm else { return }
        setPoints(points)
    }

    private func setPoints(_ points: [FanCurve.Point]) {
        curve = FanCurve(points: points.sorted { $0.temperature < $1.temperature })
    }

    /// The free grid temperature farthest from every existing point (ties: the lower one).
    private var nextFreeTemperature: Double? {
        let used = points.map(\.temperature)
        var best: (temperature: Double, distance: Double)? = nil
        for t in Self.gridTemperatures where !used.contains(t) {
            let distance: Double = used.map { abs($0 - t) }.min() ?? .infinity
            if best == nil || distance > best!.distance { best = (t, distance) }
        }
        return best?.temperature
    }

    private func addPoint() {
        guard let temperature = nextFreeTemperature else { return }
        let raw = curve.value(at: temperature, in: range)
        let rpm = min(max(Int((raw / Double(Self.rpmStep)).rounded()) * Self.rpmStep, range.lowerBound), range.upperBound)
        setPoints(points + [FanCurve.Point(temperature: temperature, rpm: rpm)])
    }

    private func removePoint(at index: Int) {
        var points = points
        guard points.count > 2, points.indices.contains(index) else { return }
        points.remove(at: index)
        setPoints(points)
    }

    // MARK: Validation

    public struct Message: Hashable, Sendable {
        public enum Severity: Sendable { case error, warning }
        public let severity: Severity
        public let text: String
    }

    /// Errors block Save / Apply.
    public static func hasErrors(_ curve: FanCurve, fan: FanDevice) -> Bool {
        messages(for: curve, fan: fan, emergencyTemperature: .infinity, unit: .celsius)
            .contains { $0.severity == .error }
    }

    /// Validation of the curve as the editor stores it (the stored points with their RPMs
    /// clamped into the fan's range, i.e. fan-agnostic presets are fine).
    public static func messages(for curve: FanCurve, fan: FanDevice, emergencyTemperature: Double,
                         unit: TemperatureUnit) -> [Message] {
        let range = fan.rpmRange
        let clamped = FanCurve(points: curve.points.map {
            FanCurve.Point(temperature: $0.temperature, rpm: min(max($0.rpm, range.lowerBound), range.upperBound))
        })
        var result: [Message] = []
        var seen = Set<String>()
        func add(_ severity: Message.Severity, _ text: String) {
            if seen.insert(text).inserted { result.append(Message(severity: severity, text: text)) }
        }
        for issue in clamped.validationIssues(rpmRange: range) {
            switch issue {
            case .tooFewPoints:
                add(.error, String(localized: "A curve needs at least two points."))
            case .nonFiniteTemperature, .temperatureOutOfRange:
                add(.error, String(localized: "Every point needs a temperature between 0 and 130 °C."))
            case .notSorted:
                add(.error, String(localized: "Two points have the same temperature."))
            case .rpmOutOfRange:
                add(.error, String(localized: "A point is outside this fan's range (\(range.lowerBound.formatted())–\(range.upperBound.formatted()) RPM)."))
            }
        }
        let points = clamped.normalized().points
        guard points.count >= 2 else { return result }
        if let drop = zip(points, points.dropFirst()).first(where: { $1.rpm < $0.rpm }) {
            add(.warning, String(localized: "The speed falls from \(drop.0.rpm.formatted()) to \(drop.1.rpm.formatted()) RPM between \(FanControlFormatting.temperature(drop.0.temperature, unit: unit)) and \(FanControlFormatting.temperature(drop.1.temperature, unit: unit)): the fan slows down as it gets hotter."))
        }
        if let first = points.first(where: { $0.rpm >= range.upperBound }) {
            if emergencyTemperature.isFinite, first.temperature >= emergencyTemperature {
                add(.warning, String(localized: "Full speed only at \(FanControlFormatting.temperature(first.temperature, unit: unit)), at or above the emergency threshold (\(FanControlFormatting.temperature(emergencyTemperature, unit: unit)))."))
            }
        } else if emergencyTemperature.isFinite {
            add(.warning, String(localized: "The curve never reaches this fan's maximum (\(range.upperBound.formatted()) RPM). Only the emergency override (\(FanControlFormatting.temperature(emergencyTemperature, unit: unit))) runs it at full speed."))
        }
        return result
    }

    @ViewBuilder
    private var messagesView: some View {
        let messages = Self.messages(for: curve, fan: fan, emergencyTemperature: emergencyTemperature, unit: unit)
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(messages, id: \.self) { message in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: message.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(message.severity == .error ? Color.red : Color.orange)
                        Text(verbatim: message.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
        }
    }
}
#endif
