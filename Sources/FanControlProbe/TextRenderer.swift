// Text rendering of fanfi-probe. Pure: takes values read by `ProbeSession` and
// returns lines (no trailing newline). The layout matches the original probe
// output byte for byte, so recorded transcripts in docs/verification stay comparable.

#if os(macOS)
import Foundation
import FanControlCore

/// A fixed-width table: cells are separated by two spaces and every row is
/// indented by two. Data cells use their column's alignment; header cells are
/// always left-aligned. The last column is never padded (no trailing spaces).
struct TextTable {
    enum Alignment { case left, right }
    struct Column {
        var title: String?
        var width: Int
        var alignment: Alignment
        init(_ title: String? = nil, width: Int = 0, _ alignment: Alignment = .left) {
            self.title = title
            self.width = width
            self.alignment = alignment
        }
    }

    var columns: [Column]

    func header() -> String {
        format(columns.map { $0.title ?? "" }, header: true)
    }

    func row(_ cells: [String]) -> String {
        format(cells, header: false)
    }

    private func format(_ cells: [String], header: Bool) -> String {
        precondition(cells.count == columns.count, "cell count must match the column count")
        let rendered = zip(columns, cells).enumerated().map { index, pair -> String in
            let (column, cell) = pair
            if index == columns.count - 1 { return cell }
            let alignment = header ? .left : column.alignment
            return alignment == .left ? TextFormat.pad(cell, column.width) : TextFormat.lpad(cell, column.width)
        }
        return "  " + rendered.joined(separator: "  ")
    }
}

/// Cell formatting shared by every mode.
enum TextFormat {
    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func lpad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// An RPM value, or "-" when it could not be read.
    static func rpm(_ value: Int?) -> String { value.map(String.init) ?? "-" }

    /// "72.70" (two decimals, no unit).
    static func celsius(_ value: Double) -> String { String(format: "%.2f", value) }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func mode(_ mode: FanControlMode?) -> String {
        switch mode {
        case .none: return "?"
        case .automatic: return "automatic"
        case .constant(let rpm): return "manual(\(rpm))"
        case .sensor(let key, let start, let max): return "sensor(\(key) \(start)-\(max))"
        }
    }
}

enum TextRenderer {
    // MARK: Snapshot

    /// Machine header, raw fan keys and the discovery summary (printed once).
    static func preamble(host: HostInfo, keyCount: Int?, fanDiscoveryError: String?,
                         rawFanKeys: [RawKeyReading], temperatureKeyCount: Int) -> [String] {
        var lines = [
            "model: \(host.model)  cpu: \(host.cpu)",
            "os: \(host.osVersion)",
            "SMC keys (#KEY): \(keyCount.map(String.init) ?? "<read failed>")",
            "",
        ]
        if let fanDiscoveryError { lines.append("fan discovery failed: \(fanDiscoveryError)") }
        lines.append("== Fan keys (raw) ==")
        lines += rawFanKeys.map { "  " + rawKey($0) }
        lines += [
            "",
            "== Temperature discovery ==",
            "plausible temperature keys found: \(temperatureKeyCount)",
            "",
        ]
        return lines
    }

    /// "KEY_ [type] size=N attr=XX  bytes  => decoded" (spaces in key names shown as "_").
    static func rawKey(_ key: RawKeyReading) -> String {
        let display = TextFormat.pad(key.name.replacingOccurrences(of: " ", with: "_"), 5)
        switch key.state {
        case .invalid:
            return "\(key.name): invalid key"
        case .absent(let error):
            return "\(display) <absent: \(error)>"
        case .present(let type, let size, let attributes, let bytes, let decoded):
            let raw = bytes?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "<read failed>"
            return "\(display) [\(type)] size=\(size) attr=\(String(format: "%02x", attributes))  \(raw)  => \(decoded ?? "-")"
        }
    }

    static let fanTable = TextTable(columns: [
        .init("idx", width: 3, .right),
        .init("name", width: 16),
        .init("min", width: 5, .right),
        .init("max", width: 5, .right),
        .init("current", width: 7, .right),
        .init("target", width: 6, .right),
        .init("mode"),
    ])
    static let temperatureTable = TextTable(columns: [.init(width: 4), .init(), .init(width: 10, .right), .init()])
    static let aggregateTable = TextTable(columns: [.init(width: 9), .init(width: 10, .right), .init()])

    /// Fans, temperatures and aggregates of one readout.
    static func readout(_ snapshot: ProbeSnapshot) -> [String] {
        var lines = ["== Fans (\(snapshot.fans.count)) @ \(TextFormat.timestamp(snapshot.date)) ==", fanTable.header()]
        for fan in snapshot.fans {
            lines.append(fanTable.row([
                String(fan.device.id), fan.device.name,
                String(fan.device.minRPM), String(fan.device.maxRPM),
                TextFormat.rpm(fan.currentRPM), TextFormat.rpm(fan.targetRPM),
                TextFormat.mode(fan.mode),
            ]))
        }
        lines.append("== Temperatures (\(snapshot.temperatures.count) of \(snapshot.temperatureKeyCount) keys) ==")
        for sample in snapshot.temperatures {
            lines.append(temperatureTable.row([
                sample.reading.id, "[\(sample.dataType)]",
                "\(TextFormat.celsius(sample.reading.temperature)) °C", sample.reading.name,
            ]))
        }
        lines.append("== Aggregates (from filtered samples; \(snapshot.substitutedKeys.count) substituted) ==")
        for reading in snapshot.aggregates {
            lines.append(aggregateTable.row([reading.id, "\(TextFormat.celsius(reading.temperature)) °C", reading.name]))
        }
        return lines
    }

    // MARK: Fan stats

    static func fanStatsHeader(seconds: Double, interval: Double, criteria: FanStabilityCriteria) -> [String] {
        let f = FanStatistics.formatted
        return [
            "== Fan stats: \(f(seconds)) s window, sample every \(f(interval)) s ==",
            "criteria: target reversals ≤ \(f(criteria.maxReversalsPerMinute))/60 s "
                + "(dead band \(criteria.reversalDeadBandRPM) RPM); |actual − target| ≤ \(criteria.trackingToleranceRPM) RPM "
                + "for ≥ \(f(criteria.requiredTrackingFraction * 100))% of samples after "
                + "\(f(criteria.settleSeconds)) s",
        ]
    }

    /// "  t=   1.0s  Fan 1:  2317 /  2317  Fan 2: …  (actual / target)"
    static func fanStatsSample(elapsed: TimeInterval, fans: [FanDevice], current: [Int: Int], target: [Int: Int]) -> String {
        var line = "  t=\(TextFormat.lpad(String(format: "%.1f", elapsed), 6))s"
        for fan in fans {
            line += "  \(fan.name): \(TextFormat.lpad(TextFormat.rpm(current[fan.id]), 5)) / \(TextFormat.lpad(TextFormat.rpm(target[fan.id]), 5))"
        }
        return line + "  (actual / target)"
    }

    static func fanStatsReport(_ result: FanStatsResult) -> [String] {
        let f = FanStatistics.formatted
        let rpm = TextFormat.rpm
        var lines = [""]
        for (fan, r) in result.reports {
            lines += [
                "== \(fan.name) (fan \(fan.id)): \(r.passed ? "PASS" : "FAIL") ==",
                "  samples \(r.sampleCount) over \(f(r.duration)) s",
                "  actual  min \(rpm(r.actualMin))  max \(rpm(r.actualMax))  mean \(r.actualMean.map { String(format: "%.0f", $0) } ?? "-")",
                "  target  min \(rpm(r.targetMin))  max \(rpm(r.targetMax))  reversals \(r.targetReversals) (allowed \(f(r.allowedReversals)))",
                "  after settle: \(r.postSettleCount) samples, max |actual − target| \(rpm(r.maxDeviationAfterSettle)), "
                    + "within ±\(result.criteria.trackingToleranceRPM): \(r.trackingFraction.map { f($0 * 100) + "%" } ?? "-")",
            ]
            lines += r.failureReasons.map { "  reason: \($0)" }
        }
        if result.reports.isEmpty { lines.append("no fans: FAIL") }
        return lines
    }
}
#endif
