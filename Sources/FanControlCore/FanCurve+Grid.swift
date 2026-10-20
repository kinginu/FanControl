import Foundation

extension FanCurve {
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

        /// The preset's points (fan-agnostic).
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

    /// Every `GridPreset`, in declaration order (`GridPreset.allCases`).
    public static var gridPresets: [GridPreset] { GridPreset.allCases }
}
