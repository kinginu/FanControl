#if os(macOS)
import SwiftUI
import FanControlCore
import FanControlKit

// MARK: - Fan curve

/// The fan curve of `profile`: x = temperature 30…100 °C (wider when a curve point lies
/// outside), y = RPM from the lowest fan minimum to the highest fan maximum. One line per fan,
/// straight from the engine: a `.sensor` mode draws its `FanProfile.curve(for:)` (the stored
/// multi-point PCHIP curve, or the two-point linear ramp) sampled with
/// `FanCurve.sample(count: 48, rpmRange:temperatureDomain:)`, a constant mode a horizontal
/// line (`FanControlEngine.targetRPM(for: profile, …)`), automatic no line. Curve points are
/// marked (regular style). The dot is the live operating point: the fan's measured RPM at the
/// smoothed control temperature of the sensor its mode follows
/// (`FanControlManager.controlTemperature(for:)`; CPU (max) for constant / automatic modes).
/// A dashed red line marks the emergency temperature. Before the emergency override.
public struct FanCurveView: View {
    public enum Style: Sendable { case compact, regular }

    /// Default temperature axis (°C).
    public static let temperatureDomain: ClosedRange<Double> = 30...100
    /// Samples per curve (plus the curve's own points).
    public static let sampleCount = 48

    let profile: FanProfile
    let fans: [FanDevice]
    let sensors: [SensorReading]
    let currentRPMs: [Int: Int]
    let unit: TemperatureUnit
    var emergencyTemperature: Double? = nil
    var style: Style = .regular

    public init(profile: FanProfile, fans: [FanDevice], sensors: [SensorReading], currentRPMs: [Int: Int],
                unit: TemperatureUnit, emergencyTemperature: Double? = nil, style: Style = .regular) {
        self.profile = profile
        self.fans = fans
        self.sensors = sensors
        self.currentRPMs = currentRPMs
        self.unit = unit
        self.emergencyTemperature = emergencyTemperature
        self.style = style
    }

    /// Per-fan colours (fan order).
    public static let palette: [Color] = [.accentColor, .orange, .green, .pink]

    public static func color(forFanAt index: Int) -> Color { palette[index % palette.count] }

    private var manager: FanControlManager { FanControlManager.shared }

    private var rpmDomain: ClosedRange<Double> {
        let low = Double(fans.map(\.rpmRange.lowerBound).min() ?? 0)
        let high = Double(fans.map(\.rpmRange.upperBound).max() ?? 1)
        return high > low ? low...high : (low - 1)...(low + 1)
    }

    /// 30…100 °C, widened to every drawn curve point.
    private var domain: ClosedRange<Double> {
        let temperatures = fans.compactMap { profile.curve(for: $0) }.flatMap { $0.normalized().points.map(\.temperature) }
        let low = min(Self.temperatureDomain.lowerBound, temperatures.min() ?? .infinity)
        let high = max(Self.temperatureDomain.upperBound, temperatures.max() ?? -.infinity)
        return low...high
    }

    private var isAllAutomatic: Bool {
        fans.allSatisfy { !profile.mode(for: $0).isManual }
    }

    /// What is drawn for one fan (computed on the main actor, drawn by the Canvas).
    private struct FanTrace {
        var color: Color
        var line: [(temperature: Double, rpm: Double)]
        var points: [(temperature: Double, rpm: Double)]
        var operatingPoint: (temperature: Double, rpm: Double)?
    }

    private var traces: [FanTrace] {
        let domain = domain
        return fans.enumerated().map { index, fan in
            let mode = profile.mode(for: fan)
            var trace = FanTrace(color: Self.color(forFanAt: index), line: [], points: [], operatingPoint: nil)
            if let curve = profile.curve(for: fan) {
                trace.line = curve.sample(count: Self.sampleCount, rpmRange: fan.rpmRange, temperatureDomain: domain)
                    .map { ($0.temperature, $0.rpm) }
                trace.points = curve.resolved(for: fan).points.map { ($0.temperature, Double($0.rpm)) }
            } else if mode.isManual {
                trace.line = Self.samples(for: mode, domain: domain).map { temperature in
                    (temperature, Double(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: temperature,
                                                                    policy: manager.safetyPolicy) ?? 0))
                }
            }
            if let rpm = currentRPMs[fan.id], let temperature = operatingTemperature(for: mode) {
                trace.operatingPoint = (temperature, Double(rpm))
            }
            return trace
        }
    }

    public var body: some View {
        let traces = traces
        let domain = domain
        let rpmDomain = rpmDomain
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                draw(traces, domain: domain, rpmDomain: rpmDomain, in: &context, size: size)
            }
            .overlay {
                if isAllAutomatic {
                    Text("Controlled by macOS")
                        .font(style == .compact ? .caption2 : .callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.background.opacity(0.6), in: Capsule())
                }
            }
            HStack(spacing: 0) {
                Text(verbatim: FanControlFormatting.temperature(domain.lowerBound, unit: unit))
                Spacer(minLength: 2)
                if style == .regular {
                    Text("Temperature")
                    Spacer(minLength: 2)
                }
                Text(verbatim: FanControlFormatting.temperature(domain.upperBound, unit: unit))
            }
            .font(style == .compact ? .system(size: 8) : .caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fan Curve"))
    }

    private func point(temperature: Double, rpm: Double, domain t: ClosedRange<Double>,
                       rpmDomain r: ClosedRange<Double>, size: CGSize) -> CGPoint {
        let x = (min(max(temperature, t.lowerBound), t.upperBound) - t.lowerBound) / (t.upperBound - t.lowerBound)
        let y = (min(max(rpm, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
        let inset: CGFloat = 3
        return CGPoint(x: inset + x * (size.width - 2 * inset),
                       y: size.height - inset - y * (size.height - 2 * inset))
    }

    private func draw(_ traces: [FanTrace], domain: ClosedRange<Double>, rpmDomain: ClosedRange<Double>,
                      in context: inout GraphicsContext, size: CGSize) {
        func p(_ temperature: Double, _ rpm: Double) -> CGPoint {
            point(temperature: temperature, rpm: rpm, domain: domain, rpmDomain: rpmDomain, size: size)
        }
        // Frame + grid (every 10 °C).
        let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
        context.stroke(frame, with: .color(.primary.opacity(0.15)), lineWidth: 1)
        var t = (domain.lowerBound / 10).rounded(.up) * 10
        while t < domain.upperBound {
            if t > domain.lowerBound {
                var grid = Path()
                grid.move(to: CGPoint(x: p(t, rpmDomain.lowerBound).x, y: 0))
                grid.addLine(to: CGPoint(x: p(t, rpmDomain.lowerBound).x, y: size.height))
                context.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 0.5)
            }
            t += 10
        }
        if style == .regular {
            context.draw(Text(verbatim: "\(Int(rpmDomain.upperBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: 6), anchor: .topLeading)
            context.draw(Text(verbatim: "\(Int(rpmDomain.lowerBound).formatted()) RPM").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 6, y: size.height - 6), anchor: .bottomLeading)
        }
        if let emergencyTemperature, domain.contains(emergencyTemperature) {
            var line = Path()
            line.move(to: p(emergencyTemperature, rpmDomain.upperBound))
            line.addLine(to: p(emergencyTemperature, rpmDomain.lowerBound))
            context.stroke(line, with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }

        let lineWidth: CGFloat = style == .compact ? 1.5 : 2
        for (index, trace) in traces.enumerated() {
            // Offset overlapping curves of later fans by a hair so both stay visible.
            let dy = CGFloat(index) * 1.0
            if !trace.line.isEmpty {
                var curve = Path()
                for (n, sample) in trace.line.enumerated() {
                    let q = p(sample.temperature, sample.rpm)
                    if n == 0 { curve.move(to: q) } else { curve.addLine(to: q) }
                }
                context.stroke(curve.offsetBy(dx: 0, dy: dy), with: .color(trace.color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            if style == .regular {
                for point in trace.points where domain.contains(point.temperature) {
                    let q = p(point.temperature, point.rpm)
                    let r: CGFloat = 2.5
                    let marker = Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r + dy, width: 2 * r, height: 2 * r))
                    context.fill(marker, with: .style(.background))
                    context.stroke(marker, with: .color(trace.color), lineWidth: 1.25)
                }
            }
            if let operating = trace.operatingPoint {
                let q = p(operating.temperature, operating.rpm)
                let radius: CGFloat = style == .compact ? 2.5 : 4
                let dot = Path(ellipseIn: CGRect(x: q.x - radius, y: q.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(dot, with: .color(trace.color))
                context.stroke(dot, with: .color(.primary.opacity(0.8)), lineWidth: 0.75)
            }
        }
    }

    /// Temperatures at which a mode without a curve (constant, degenerate sensor ramp) changes
    /// value, plus the ends of `domain`.
    public static func samples(for mode: FanControlMode, domain: ClosedRange<Double> = temperatureDomain) -> [Double] {
        var points = [domain.lowerBound, domain.upperBound]
        if case .sensor(_, let start, let maxTemperature) = mode {
            let epsilon = 0.001
            points += [start, maxTemperature, start - epsilon, maxTemperature - epsilon]
        }
        return Array(Set(points.filter { domain.contains($0) })).sorted()
    }

    /// The temperature the operating point is drawn at: the smoothed control temperature of the
    /// followed sensor, else CPU (max) (or the hottest key temperature).
    private func operatingTemperature(for mode: FanControlMode) -> Double? {
        if case .sensor(let key, _, _) = mode, let value = manager.controlTemperature(for: key), value.isFinite {
            return value
        }
        if let cpu = manager.controlTemperature(for: SensorAggregator.ID.cpu), cpu.isFinite { return cpu }
        return FanControlFormatting.keyTemperatures(sensors).first?.temperature
    }
}
#endif
