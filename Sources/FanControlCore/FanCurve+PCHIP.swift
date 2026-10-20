import Foundation

extension FanCurve {
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
