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
///
/// Editor support: `validationIssues(rpmRange:)` (FanCurve+Validation.swift), the 10 °C
/// grid and `GridPreset` (FanCurve+Grid.swift). Interpolation: FanCurve+PCHIP.swift.
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

    /// The Boost preset curve: full speed well before the emergency threshold.
    /// 50 °C minimum, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800 (= the maximum of
    /// Mac14,9's fans).
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

    /// Tolerance (°C) of `matches(startTemperature:maxTemperature:)`.
    static let matchTolerance = 0.05

    /// `true` if the curve's first / last temperatures equal `start` / `max` (±0.05 °C),
    /// i.e. it belongs to a `.sensor(startTemperature: start, maxTemperature: max)` mode.
    /// An empty curve matches nothing.
    public func matches(startTemperature start: Double, maxTemperature max: Double) -> Bool {
        let points = normalized().points
        guard let first = points.first?.temperature, let last = points.last?.temperature else { return false }
        return abs(first - start) <= Self.matchTolerance && abs(last - max) <= Self.matchTolerance
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
        evaluationCurve(rpmRange: rpmRange).evaluate(at: temperature, clampingTo: rpmRange)
    }

    /// `resolved(rpmRange:)`, or `normalized()` without a range: the form `evaluate` expects.
    private func evaluationCurve(rpmRange: ClosedRange<Int>?) -> FanCurve {
        rpmRange.map { resolved(rpmRange: $0) } ?? normalized()
    }

    /// `value(at:in:)` of a curve that is already `evaluationCurve(rpmRange:)`.
    private func evaluate(at temperature: Double, clampingTo rpmRange: ClosedRange<Int>?) -> Double {
        let upper = Double(rpmRange?.upperBound ?? points.map(\.rpm).max() ?? Self.fanMaximumRPM)
        guard temperature.isFinite else { return upper }
        let xs = points.map(\.temperature)
        let ys = points.map { Double($0.rpm) }
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
        /// °C.
        public var temperature: Double
        /// Unrounded curve value (`value(at:in:)`).
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
        let evaluated = evaluationCurve(rpmRange: rpmRange)
        return Array(Set(temperatures)).sorted().map {
            Sample(temperature: $0, rpm: evaluated.evaluate(at: $0, clampingTo: rpmRange))
        }
    }
}
