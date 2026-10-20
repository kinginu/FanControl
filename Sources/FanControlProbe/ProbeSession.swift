// Reading layer of fanfi-probe: everything that touches the SMC lives here and
// returns plain values; rendering (text / JSON) never reads the SMC itself.
//
// READ-ONLY BY DESIGN: only `SMCReader` methods (keyInfo / readBytes / readValue /
// keyCount / key(at:)) and the read-only `SMCClient.dump()` are used. Never call
// `SMCClient.writeBytes`, anything on `SMCWriter`, profile application or helper
// registration from this target.

#if os(macOS)
import Foundation
import FanControlCore
import FanControlSMC

/// Machine / OS identification.
struct HostInfo {
    var model: String
    var cpu: String
    var osVersion: String
    var isAppleSilicon: Bool

    static func current() -> HostInfo {
        HostInfo(model: sysctlString("hw.model"),
                 cpu: sysctlString("machdep.cpu.brand_string"),
                 osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                 isAppleSilicon: FanControlHost.isAppleSilicon)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One raw SMC key as listed in "Fan keys (raw)".
struct RawKeyReading {
    enum State {
        case invalid
        /// `bytes` / `decoded` are `nil` when that read failed.
        case present(type: String, size: Int, attributes: UInt8, bytes: [UInt8]?, decoded: String?)
        case absent(error: String)
    }
    var name: String
    var state: State
}

/// A fan with its live state.
struct FanState {
    var device: FanDevice
    var currentRPM: Int?
    var targetRPM: Int?
    var mode: FanControlMode?
}

/// A temperature reading plus its SMC data type name (`"?"` if unknown).
struct TemperatureSample {
    var reading: SensorReading
    var dataType: String
}

/// One fan/temperature readout.
struct ProbeSnapshot {
    var date: Date
    var fans: [FanState]
    var temperatures: [TemperatureSample]
    /// Aggregates computed from the *filtered* samples, as in `FanControlManager`.
    var aggregates: [SensorReading]
    /// Keys whose raw reading the filter replaced in this readout.
    var substitutedKeys: Set<String>
    /// Number of temperature keys discovered (temperatures may hold fewer).
    var temperatureKeyCount: Int
}

/// An open read-only SMC session with discovered fans and temperature keys.
final class ProbeSession {
    let client: SMCClient
    let fans: [FanDevice]
    /// Set when fan discovery threw (`fans` is then empty).
    let fanDiscoveryError: String?
    /// Discovered temperature keys (`SensorCatalog.discoverTemperatureSensors`).
    let sensorKeys: [String]
    /// Set when temperature discovery threw (`sensorKeys` is then empty).
    let sensorDiscoveryError: String?

    private var sampleFilter = TemperatureSampleFilter()
    private let aggregateDefinitions = SensorAggregator.definitions

    /// Raw fan keys listed by the snapshot. `FS! ` (Intel force bitmask) and `Ftst`
    /// (unlock key) are never written; listed only to record that they are absent
    /// (Mac14,9: key not found).
    static let globalFanKeyNames = ["FNum", "FS! ", "Ftst"]
    static let perFanKeySuffixes = ["ID", "Mn", "Mx", "Ac", "Tg", "Md", "Sf"]

    /// Opens the AppleSMC user client and discovers fans and temperature keys.
    init() throws {
        client = try SMCClient()
        do {
            fans = try FanDiscovery.discoverFans(using: client)
            fanDiscoveryError = nil
        } catch {
            fans = []
            fanDiscoveryError = "\(error)"
        }
        do {
            sensorKeys = try SensorCatalog.discoverTemperatureSensors(using: client).map(\.id)
            sensorDiscoveryError = nil
        } catch {
            sensorKeys = []
            sensorDiscoveryError = "\(error)"
        }
    }

    deinit { client.close() }

    /// `#KEY`, or `nil` if it could not be read.
    func keyCount() -> Int? { try? client.keyCount() }

    /// The full key dump (`SMCClient.dump()`).
    func dump() -> String { client.dump() }

    /// Global plus per-fan raw keys, in listing order.
    func rawFanKeys() -> [RawKeyReading] {
        var names = Self.globalFanKeyNames
        for fan in fans {
            for suffix in Self.perFanKeySuffixes { names.append("F\(fan.id)\(suffix)") }
        }
        return names.map(rawKey)
    }

    private func rawKey(_ name: String) -> RawKeyReading {
        guard let key = SMCKey(name) else { return RawKeyReading(name: name, state: .invalid) }
        do {
            let info = try client.keyInfo(key)
            let bytes = try? client.readBytes(key)
            let decoded = (try? client.readValue(key)).map { "\($0)" }
            return RawKeyReading(name: name, state: .present(type: info.dataType.name, size: info.dataSize,
                                                            attributes: info.attributes, bytes: bytes, decoded: decoded))
        } catch {
            return RawKeyReading(name: name, state: .absent(error: "\(error)"))
        }
    }

    /// Actual and target RPM of every fan (the `--fan-stats` sample).
    func fanSpeeds() -> (current: [Int: Int], target: [Int: Int]) {
        (FanDiscovery.readCurrentRPMs(fans: fans, using: client),
         FanDiscovery.readTargetRPMs(fans: fans, using: client))
    }

    /// Reads fans and temperatures and advances the sample filter.
    func snapshot() -> ProbeSnapshot {
        let date = Date()
        let speeds = fanSpeeds()
        let modes = FanDiscovery.fanControlModes(fans: fans, using: client)
        let fanStates = fans.map {
            FanState(device: $0, currentRPM: speeds.current[$0.id], targetRPM: speeds.target[$0.id], mode: modes[$0.id])
        }
        let readings = SensorCatalog.readTemperatures(keys: sensorKeys, using: client)
        let temperatures = readings.map { reading in
            TemperatureSample(reading: reading,
                              dataType: (SMCKey(reading.id).flatMap { try? client.keyInfo($0) })?.dataType.name ?? "?")
        }
        let filtered = sampleFilter.filter(readings)
        let aggregates = SensorAggregator.aggregates(of: filtered, definitions: aggregateDefinitions)
        return ProbeSnapshot(date: date, fans: fanStates, temperatures: temperatures, aggregates: aggregates,
                             substitutedKeys: sampleFilter.substitutedKeys, temperatureKeyCount: sensorKeys.count)
    }
}
#endif
