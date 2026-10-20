import Foundation

extension FanCurve {
    // MARK: Validation

    /// A problem found by `validationIssues(rpmRange:)`; `index` refers to `points`.
    public enum ValidationIssue: Hashable, Sendable {
        /// Fewer than two points.
        case tooFewPoints
        /// NaN or infinite temperature.
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
}
