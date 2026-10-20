// `--json` rendering of fanfi-probe. Pure: converts values read by `ProbeSession`
// into Codable documents with a stable, documented shape.
//
// Shape (schemaVersion 1; keys are sorted, temperatures are °C rounded to 0.01, values
// that could not be read or computed are null; mode fields that do not apply are omitted):
//   snapshot: { kind: "snapshot", schemaVersion, timestamp, host{model,cpu,os,appleSilicon},
//               smcKeyCount, fans[{id,name,minRPM,maxRPM,currentRPM,targetRPM,mode}],
//               aggregates[{id,name,celsius}], temperatures[{id,name,celsius,dataType}],
//               temperatureKeyCount, substitutedSensorKeys[], errors[] }
//     mode: null | {kind:"automatic"} | {kind:"manual",rpm} | {kind:"sensor",sensorKey,startTemperature,maxTemperature}
//   fanStats: { kind: "fanStats", schemaVersion, timestamp, windowSeconds, intervalSeconds,
//               criteria{…}, passed, fans[{id,name,passed,…,failureReasons,samples[{t,actualRPM,targetRPM}]}] }

#if os(macOS)
import Foundation
import FanControlCore

enum JSONRenderer {
    static let schemaVersion = 1

    struct Host: Encodable {
        var model: String
        var cpu: String
        var os: String
        var appleSilicon: Bool
    }

    struct Mode: Encodable {
        var kind: String
        var rpm: Int?
        var sensorKey: String?
        var startTemperature: Double?
        var maxTemperature: Double?

        init?(_ mode: FanControlMode?) {
            switch mode {
            case .none: return nil
            case .automatic: kind = "automatic"
            case .constant(let rpm): kind = "manual"; self.rpm = rpm
            case .sensor(let key, let start, let max):
                kind = "sensor"; sensorKey = key; startTemperature = start; maxTemperature = max
            }
        }
    }

    struct Fan: Encodable {
        var id: Int
        var name: String
        var minRPM: Int
        var maxRPM: Int
        var currentRPM: Int?
        var targetRPM: Int?
        var mode: Mode?

        // Explicit so that unreadable values are emitted as null instead of omitted.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(minRPM, forKey: .minRPM)
            try c.encode(maxRPM, forKey: .maxRPM)
            try c.encode(currentRPM, forKey: .currentRPM)
            try c.encode(targetRPM, forKey: .targetRPM)
            try c.encode(mode, forKey: .mode)
        }
        enum CodingKeys: String, CodingKey { case id, name, minRPM, maxRPM, currentRPM, targetRPM, mode }
    }

    struct Temperature: Encodable {
        var id: String
        var name: String
        var celsius: Double
        var dataType: String?
    }

    struct Snapshot: Encodable {
        var kind = "snapshot"
        var schemaVersion = JSONRenderer.schemaVersion
        var timestamp: String
        var host: Host
        var smcKeyCount: Int?
        var fans: [Fan]
        var aggregates: [Temperature]
        var temperatures: [Temperature]
        var temperatureKeyCount: Int
        var substitutedSensorKeys: [String]
        var errors: [String]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encode(host, forKey: .host)
            try c.encode(smcKeyCount, forKey: .smcKeyCount)
            try c.encode(fans, forKey: .fans)
            try c.encode(aggregates, forKey: .aggregates)
            try c.encode(temperatures, forKey: .temperatures)
            try c.encode(temperatureKeyCount, forKey: .temperatureKeyCount)
            try c.encode(substitutedSensorKeys, forKey: .substitutedSensorKeys)
            try c.encode(errors, forKey: .errors)
        }
        enum CodingKeys: String, CodingKey {
            case kind, schemaVersion, timestamp, host, smcKeyCount, fans, aggregates, temperatures
            case temperatureKeyCount, substitutedSensorKeys, errors
        }
    }

    struct Criteria: Encodable {
        var reversalDeadBandRPM: Int
        var maxReversalsPerMinute: Double
        var settleSeconds: Double
        var trackingToleranceRPM: Int
        var requiredTrackingFraction: Double
    }

    struct Sample: Encodable {
        var t: Double
        var actualRPM: Int?
        var targetRPM: Int?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(t, forKey: .t)
            try c.encode(actualRPM, forKey: .actualRPM)
            try c.encode(targetRPM, forKey: .targetRPM)
        }
        enum CodingKeys: String, CodingKey { case t, actualRPM, targetRPM }
    }

    struct FanStatsFan: Encodable {
        var id: Int
        var name: String
        var passed: Bool
        var sampleCount: Int
        var durationSeconds: Double
        var actualMin: Int?
        var actualMax: Int?
        var actualMean: Double?
        var targetMin: Int?
        var targetMax: Int?
        var targetReversals: Int
        var allowedReversals: Double
        var postSettleCount: Int
        var maxDeviationAfterSettle: Int?
        var trackingFraction: Double?
        var failureReasons: [String]
        var samples: [Sample]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(passed, forKey: .passed)
            try c.encode(sampleCount, forKey: .sampleCount)
            try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(actualMin, forKey: .actualMin)
            try c.encode(actualMax, forKey: .actualMax)
            try c.encode(actualMean, forKey: .actualMean)
            try c.encode(targetMin, forKey: .targetMin)
            try c.encode(targetMax, forKey: .targetMax)
            try c.encode(targetReversals, forKey: .targetReversals)
            try c.encode(allowedReversals, forKey: .allowedReversals)
            try c.encode(postSettleCount, forKey: .postSettleCount)
            try c.encode(maxDeviationAfterSettle, forKey: .maxDeviationAfterSettle)
            try c.encode(trackingFraction, forKey: .trackingFraction)
            try c.encode(failureReasons, forKey: .failureReasons)
            try c.encode(samples, forKey: .samples)
        }
        enum CodingKeys: String, CodingKey {
            case id, name, passed, sampleCount, durationSeconds, actualMin, actualMax, actualMean
            case targetMin, targetMax, targetReversals, allowedReversals, postSettleCount
            case maxDeviationAfterSettle, trackingFraction, failureReasons, samples
        }
    }

    struct FanStats: Encodable {
        var kind = "fanStats"
        var schemaVersion = JSONRenderer.schemaVersion
        var timestamp: String
        var windowSeconds: Double
        var intervalSeconds: Double
        var criteria: Criteria
        var passed: Bool
        var fans: [FanStatsFan]
    }

    // MARK: Builders

    static func snapshot(_ s: ProbeSnapshot, host: HostInfo, keyCount: Int?, errors: [String]) -> Snapshot {
        Snapshot(
            timestamp: TextFormat.timestamp(s.date),
            host: Host(model: host.model, cpu: host.cpu, os: host.osVersion, appleSilicon: host.isAppleSilicon),
            smcKeyCount: keyCount,
            fans: s.fans.map {
                Fan(id: $0.device.id, name: $0.device.name, minRPM: $0.device.minRPM, maxRPM: $0.device.maxRPM,
                    currentRPM: $0.currentRPM, targetRPM: $0.targetRPM, mode: Mode($0.mode))
            },
            aggregates: s.aggregates.map { Temperature(id: $0.id, name: $0.name, celsius: rounded($0.temperature)) },
            temperatures: s.temperatures.map {
                Temperature(id: $0.reading.id, name: $0.reading.name, celsius: rounded($0.reading.temperature),
                            dataType: $0.dataType == "?" ? nil : $0.dataType.trimmingCharacters(in: .whitespaces))
            },
            temperatureKeyCount: s.temperatureKeyCount,
            substitutedSensorKeys: s.substitutedKeys.sorted(),
            errors: errors)
    }

    static func fanStats(_ r: FanStatsResult, date: Date) -> FanStats {
        FanStats(
            timestamp: TextFormat.timestamp(date),
            windowSeconds: r.windowSeconds,
            intervalSeconds: r.intervalSeconds,
            criteria: Criteria(reversalDeadBandRPM: r.criteria.reversalDeadBandRPM,
                               maxReversalsPerMinute: r.criteria.maxReversalsPerMinute,
                               settleSeconds: r.criteria.settleSeconds,
                               trackingToleranceRPM: r.criteria.trackingToleranceRPM,
                               requiredTrackingFraction: r.criteria.requiredTrackingFraction),
            passed: r.passed,
            fans: r.reports.map { fan, rep in
                FanStatsFan(id: fan.id, name: fan.name, passed: rep.passed, sampleCount: rep.sampleCount,
                            durationSeconds: rounded(rep.duration),
                            actualMin: rep.actualMin, actualMax: rep.actualMax, actualMean: rep.actualMean.map(rounded),
                            targetMin: rep.targetMin, targetMax: rep.targetMax,
                            targetReversals: rep.targetReversals, allowedReversals: rounded(rep.allowedReversals),
                            postSettleCount: rep.postSettleCount, maxDeviationAfterSettle: rep.maxDeviationAfterSettle,
                            trackingFraction: rep.trackingFraction.map { (($0 * 10_000).rounded()) / 10_000 },
                            failureReasons: rep.failureReasons,
                            samples: (r.samples[fan.id] ?? []).map {
                                Sample(t: rounded($0.time), actualRPM: $0.actualRPM, targetRPM: $0.targetRPM)
                            })
            })
    }

    // MARK: Encoding

    /// Pretty-printed (single document) or compact (one JSON Lines record).
    static func encode<T: Encodable>(_ value: T, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain structs of strings and numbers cannot fail.
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Two decimals, so that 72.7 is emitted as 72.7 rather than 72.70000000000001.
    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
#endif
