import Foundation

/// A multi-point fan curve: target RPM as a function of temperature (°C).
///
/// Evaluation (`rpm(at:in:)`):
/// 1. the points are sanitized (`normalized()`: non-finite points dropped, sorted by
///    temperature, temperatures clamped to `temperatureRange`, one point per temperature
///    — the last one wins);
/// 2. each point's RPM is clamped into the fan's range, so `fanMinimumRPM` (0) stands for
///    "the fan's minimum" and `fanMaximumRPM` (65 535) for "the fan's maximum" in
///    fan-agnostic curves (presets, migrated start/max modes);
/// 3. between points the curve is a **monotone cubic** (PCHIP, Fritsch–Carlson): it never
///    overshoots a point, is monotone wherever the points are, and is linear for two
///    points; before the first point it stays at the first RPM, after the last at the last;
/// 4. the result is clamped to the fan's range and rounded.
///
/// An empty curve evaluates to the fan's maximum (fail loud), one point to that RPM.
///
/// A curve is attached to a `.sensor` mode through `FanProfile.curves` /
/// `FanProfile.defaultCurve` (docs/kit.md "Fan curves"); the mode's
/// `startTemperature` / `maxTemperature` are the curve's first / last temperature.
public struct FanCurve: Codable, Hashable, Sendable {

    /// One curve point.
    public struct Point: Codable, Hashable, Sendable {
        /// °C.
        public var temperature: Double
        /// Target speed. Clamped to the fan's `rpmRange` when evaluated.
        public var rpm: Int

        public init(temperature: Double, rpm: Int) {
            self.temperature = temperature
            self.rpm = rpm
        }
    }

    /// The points as stored (see `normalized()` for the evaluated form).
    public var points: [Point]

    public init(points: [Point]) {
        self.points = points
    }

    /// `[(temperature, rpm)]` convenience: `FanCurve([(50, 0), (85, 6800)])`.
    public init(_ points: [(temperature: Double, rpm: Int)]) {
        self.points = points.map { Point(temperature: $0.temperature, rpm: $0.rpm) }
    }

    // MARK: Constants

    /// Allowed point temperatures (°C).
    public static let temperatureRange: ClosedRange<Double> = 0...130
    /// Stands for "the fan's minimum" in a fan-agnostic curve (clamped up to `F<n>Mn`).
    public static let fanMinimumRPM = 0
    /// Stands for "the fan's maximum" in a fan-agnostic curve (clamped down to `F<n>Mx`).
    public static let fanMaximumRPM = 65_535
    /// Temperature step of the editor grid (`gridTemperatures`, `GridPreset`).
    public static let gridStep: Double = 10

    // MARK: Construction

    /// The two-point curve equivalent to the legacy `.sensor(start, max)` ramp: the fan's
    /// minimum at `start`, its maximum at `max` (linear in between).
    public static func linear(startTemperature: Double, maxTemperature: Double) -> FanCurve {
        FanCurve([(startTemperature, fanMinimumRPM), (maxTemperature, fanMaximumRPM)])
    }

    /// The Boost preset curve (user decision 2026-10-20): full speed well before the
    /// emergency threshold. 50 °C minimum, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800
    /// (= the maximum of Mac14,9's fans).
    public static let boost = FanCurve([(50, fanMinimumRPM), (60, 3500), (70, 5200), (80, 6400), (85, 6800)])

    // MARK: Derived

    /// First (lowest) temperature of `normalized()`, `nil` when empty.
    public var startTemperature: Double? { normalized().points.first?.temperature }
    /// Last (highest) temperature of `normalized()`, `nil` when empty.
    public var endTemperature: Double? { normalized().points.last?.temperature }

    /// Sorted by temperature, non-finite points dropped, temperatures clamped to
    /// `temperatureRange`, one point per temperature (the later one in `points` wins).
    public func normalized() -> FanCurve {
        var byTemperature: [Double: Point] = [:]
        for point in points where point.temperature.isFinite {
            let t = min(max(point.temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
            byTemperature[t] = Point(temperature: t, rpm: point.rpm)
        }
        return FanCurve(points: byTemperature.values.sorted { $0.temperature < $1.temperature })
    }

    /// `normalized()` with every RPM clamped into `rpmRange` (what an editor shows for one fan).
    public func resolved(rpmRange: ClosedRange<Int>) -> FanCurve {
        var curve = normalized()
        for index in curve.points.indices {
            curve.points[index].rpm = min(max(curve.points[index].rpm, rpmRange.lowerBound), rpmRange.upperBound)
        }
        return curve
    }

    /// `resolved(rpmRange: fan.rpmRange)`.
    public func resolved(for fan: FanDevice) -> FanCurve { resolved(rpmRange: fan.rpmRange) }

    /// `true` if the curve's first / last temperatures equal `start` / `max` (±0.05 °C),
    /// i.e. it belongs to a `.sensor(startTemperature: start, maxTemperature: max)` mode.
    public func matches(startTemperature start: Double, maxTemperature max: Double) -> Bool {
        guard let first = startTemperature, let last = endTemperature else { return false }
        return abs(first - start) <= 0.05 && abs(last - max) <= 0.05
    }

    // MARK: Evaluation

    /// The target RPM at `temperature` for a fan with `rpmRange` (see the type documentation).
    /// A non-finite temperature gives the maximum (fail loud).
    public func rpm(at temperature: Double, in rpmRange: ClosedRange<Int>) -> Int {
        let value = value(at: temperature, in: rpmRange)
        return min(max(Int(value.rounded()), rpmRange.lowerBound), rpmRange.upperBound)
    }

    /// `rpm(at:in: fan.rpmRange)`.
    public func rpm(at temperature: Double, for fan: FanDevice) -> Int { rpm(at: temperature, in: fan.rpmRange) }

    /// The unrounded curve value (clamped to `rpmRange`; `nil` = no clamping of the
    /// stored RPMs), for charts.
    public func value(at temperature: Double, in rpmRange: ClosedRange<Int>?) -> Double {
        let curve = rpmRange.map { resolved(rpmRange: $0) } ?? normalized()
        let upper = Double(rpmRange?.upperBound ?? curve.points.map(\.rpm).max() ?? Self.fanMaximumRPM)
        guard temperature.isFinite else { return upper }
        let xs = curve.points.map(\.temperature)
        let ys = curve.points.map { Double($0.rpm) }
        guard let first = xs.first, let last = xs.last else { return upper }
        let result: Double
        if xs.count == 1 || temperature <= first {
            result = ys[0]
        } else if temperature >= last {
            result = ys[ys.count - 1]
        } else {
            result = Self.pchip(xs: xs, ys: ys, at: temperature)
        }
        guard let rpmRange else { return result }
        return min(max(result, Double(rpmRange.lowerBound)), Double(rpmRange.upperBound))
    }

    /// One chart sample.
    public struct Sample: Hashable, Sendable {
        public var temperature: Double
        public var rpm: Double
    }

    /// `count` (≥ 2) evenly spaced samples over `temperatureDomain` (default: the curve's
    /// own span, or `temperatureRange` when it has fewer than two points), clamped to
    /// `rpmRange` (`nil` = stored RPMs as-is). The points' own temperatures inside the
    /// domain are included as well, so a chart passes through them exactly.
    public func sample(count: Int, rpmRange: ClosedRange<Int>? = nil,
                       temperatureDomain: ClosedRange<Double>? = nil) -> [Sample] {
        let curve = normalized()
        let domain: ClosedRange<Double>
        if let temperatureDomain {
            domain = temperatureDomain
        } else if let first = curve.points.first?.temperature, let last = curve.points.last?.temperature,
                  first < last {
            domain = first...last
        } else {
            domain = Self.temperatureRange
        }
        let n = max(count, 2)
        var temperatures = (0..<n).map {
            domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double($0) / Double(n - 1)
        }
        temperatures += curve.points.map(\.temperature).filter { domain.contains($0) }
        return Array(Set(temperatures)).sorted().map {
            Sample(temperature: $0, rpm: value(at: $0, in: rpmRange))
        }
    }

    // MARK: Validation

    /// A problem found by `validationIssues(rpmRange:)`; `index` refers to `points`.
    public enum ValidationIssue: Hashable, Sendable {
        /// Fewer than two points.
        case tooFewPoints
        case nonFiniteTemperature(index: Int)
        /// Outside `FanCurve.temperatureRange` (0…130 °C).
        case temperatureOutOfRange(index: Int)
        /// Not strictly above the previous point's temperature.
        case notSorted(index: Int)
        /// Outside the fan's RPM range.
        case rpmOutOfRange(index: Int)
    }

    /// Problems of the stored points for an editor: at least two points, finite
    /// temperatures inside 0…130 °C in strictly increasing order, and (when `rpmRange` is
    /// given) every RPM inside it. Fan-agnostic curves (presets) use `fanMinimumRPM` /
    /// `fanMaximumRPM`; validate `resolved(rpmRange:)` for those.
    public func validationIssues(rpmRange: ClosedRange<Int>? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if points.count < 2 { issues.append(.tooFewPoints) }
        for (index, point) in points.enumerated() {
            if !point.temperature.isFinite {
                issues.append(.nonFiniteTemperature(index: index))
                continue
            }
            if !Self.temperatureRange.contains(point.temperature) {
                issues.append(.temperatureOutOfRange(index: index))
            }
            if index > 0, points[index - 1].temperature.isFinite,
               point.temperature <= points[index - 1].temperature {
                issues.append(.notSorted(index: index))
            }
            if let rpmRange, !rpmRange.contains(point.rpm) {
                issues.append(.rpmOutOfRange(index: index))
            }
        }
        return issues
    }

    /// `validationIssues(rpmRange:).isEmpty`.
    public func isValid(rpmRange: ClosedRange<Int>? = nil) -> Bool { validationIssues(rpmRange: rpmRange).isEmpty }

    // MARK: 10 °C grid

    /// Grid temperatures `from`, `from + step`, … up to `through` (default 30…100 °C, 10 °C).
    public static func gridTemperatures(from: Double = 30, through: Double = 100,
                                        step: Double = gridStep) -> [Double] {
        guard step > 0, from.isFinite, through.isFinite, from <= through else { return [] }
        return Array(stride(from: from, through: through + step / 1000, by: step))
    }

    /// The curve evaluated at `temperatures` (one point each, RPMs clamped to `rpmRange`
    /// and rounded to `rpmStep`), e.g. to load any curve into a fixed-column grid editor.
    public func resampled(at temperatures: [Double], rpmRange: ClosedRange<Int>, rpmStep: Int = 50) -> FanCurve {
        let step = max(rpmStep, 1)
        return FanCurve(points: temperatures.filter(\.isFinite).sorted().map { t in
            let raw = value(at: t, in: rpmRange)
            let rounded = Int((raw / Double(step)).rounded()) * step
            return Point(temperature: t, rpm: min(max(rounded, rpmRange.lowerBound), rpmRange.upperBound))
        })
    }

    /// Ready-made curves on the 10 °C grid for a curve editor (fan-agnostic: 0 = minimum,
    /// `fanMaximumRPM` = maximum; resolve them for a fan before editing).
    public enum GridPreset: String, CaseIterable, Codable, Sendable {
        /// Minimum up to 60 °C, maximum at 90 °C.
        case quiet
        /// Minimum up to 50 °C, maximum at 85 °C (smooth ramp).
        case balanced
        /// The Boost preset (`FanCurve.boost`): maximum at 85 °C.
        case boost
        /// Maximum everywhere.
        case fullSpeed

        public var curve: FanCurve {
            switch self {
            case .quiet:
                return FanCurve([(60, fanMinimumRPM), (70, 3000), (80, 4300), (90, fanMaximumRPM)])
            case .balanced:
                return FanCurve([(50, fanMinimumRPM), (60, 3000), (70, 4200), (80, 5600), (85, fanMaximumRPM)])
            case .boost:
                return FanCurve.boost
            case .fullSpeed:
                return FanCurve([(30, fanMaximumRPM), (100, fanMaximumRPM)])
            }
        }
    }

    /// Every `GridPreset` curve, in declaration order.
    public static var gridPresets: [GridPreset] { GridPreset.allCases }

    // MARK: PCHIP (Fritsch–Carlson)

    /// Monotone piecewise-cubic Hermite interpolation of sorted, distinct `xs` (≥ 2) at
    /// `x` strictly inside `xs.first...xs.last`. Interior slopes: weighted harmonic mean
    /// of the neighbouring secants (0 at a local extremum or a flat segment); end slopes:
    /// the shape-preserving three-point formula (as SciPy's `PchipInterpolator`). Two
    /// points give a straight line.
    static func pchip(xs: [Double], ys: [Double], at x: Double) -> Double {
        let n = xs.count
        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            h[k] = xs[k + 1] - xs[k]
            delta[k] = (ys[k + 1] - ys[k]) / h[k]
        }
        var m = [Double](repeating: 0, count: n)
        if n == 2 {
            m[0] = delta[0]
            m[1] = delta[0]
        } else {
            for k in 1..<(n - 1) {
                let d0 = delta[k - 1], d1 = delta[k]
                if d0 == 0 || d1 == 0 || (d0 > 0) != (d1 > 0) {
                    m[k] = 0
                } else {
                    let w1 = 2 * h[k] + h[k - 1]
                    let w2 = h[k] + 2 * h[k - 1]
                    m[k] = (w1 + w2) / (w1 / d0 + w2 / d1)
                }
            }
            m[0] = endSlope(h0: h[0], h1: h[1], d0: delta[0], d1: delta[1])
            m[n - 1] = endSlope(h0: h[n - 2], h1: h[n - 3], d0: delta[n - 2], d1: delta[n - 3])
        }
        // Segment containing x.
        var k = 0
        while k < n - 2 && x >= xs[k + 1] { k += 1 }
        let t = (x - xs[k]) / h[k]
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[k] + h10 * h[k] * m[k] + h01 * ys[k + 1] + h11 * h[k] * m[k + 1]
    }

    private static func endSlope(h0: Double, h1: Double, d0: Double, d1: Double) -> Double {
        var slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
        if slope == 0 || d0 == 0 || (slope > 0) != (d0 > 0) {
            slope = 0
        } else if (d0 > 0) != (d1 > 0), abs(slope) > abs(3 * d0) {
            slope = 3 * d0
        }
        return slope
    }
}
