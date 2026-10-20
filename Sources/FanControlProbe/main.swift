// fanfi-probe — read-only SMC probe for Phase 1 verification (docs/integration.md §6).
//
// READ-ONLY BY DESIGN. This tool must never write to the SMC: it uses only
// `SMCReader` methods (keyInfo / readBytes / keyCount / key(at:)) and the
// read-only `SMCClient.dump()`. Do not call `SMCClient.writeBytes`, anything on
// `SMCWriter`, profile application or helper registration from here, and do
// not add any write option. It runs unprivileged (no sudo needed).
//
// Usage: fanfi-probe [--dump] [--watch N]
//   (default)   machine model, SMC key count, fans, temperature sensors
//   --dump      every SMC key with type/size/attributes and raw bytes
//   --watch N   repeat the fan/temperature readout every N seconds (Ctrl-C to stop)

#if os(macOS)
import Foundation
import FanControlCore
import FanControlSMC

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: fanfi-probe [--dump] [--watch N]\n".utf8))
    exit(2)
}

var wantDump = false
var watchInterval: Double?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--dump": wantDump = true
    case "--watch":
        guard let value = args.popFirst(), let seconds = Double(value), seconds > 0 else { usage() }
        watchInterval = seconds
    case "-h", "--help": usage()
    default: usage()
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func lpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

/// Type/size/attr/raw description of a key, or why it is unavailable.
func describeKey(_ name: String, _ reader: SMCReader) -> String {
    guard let key = SMCKey(name) else { return "\(name): invalid key" }
    let display = name.replacingOccurrences(of: " ", with: "_")
    do {
        let info = try reader.keyInfo(key)
        let raw = (try? reader.readBytes(key))?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "<read failed>"
        let decoded = (try? reader.readValue(key)).map { "\($0)" } ?? "-"
        return "\(pad(display, 5)) [\(info.dataType.name)] size=\(info.dataSize) attr=\(String(format: "%02x", info.attributes))  \(raw)  => \(decoded)"
    } catch {
        return "\(pad(display, 5)) <absent: \(error)>"
    }
}

func modeString(_ mode: FanControlMode?) -> String {
    switch mode {
    case .none: return "?"
    case .automatic: return "automatic"
    case .constant(let rpm): return "manual(\(rpm))"
    case .sensor(let key, let start, let max): return "sensor(\(key) \(start)-\(max))"
    }
}

// Apple Silicon only (Intel dropped 2026-10-20). Reading is harmless, so the
// probe still runs, but its labels and aggregates assume Apple Silicon.
if !FanControlHost.isAppleSilicon {
    FileHandle.standardError.write(Data("warning: unsupported host: \(FanControlHost.unsupportedDetail)\n".utf8))
}

let client: SMCClient
do {
    client = try SMCClient()
} catch {
    print("SMC connection failed: \(error) (AppleSMC available: \(SMCConnection.isAvailable()))")
    exit(1)
}
defer { client.close() }

if wantDump {
    print(client.dump())
    exit(0)
}

print("model: \(sysctlString("hw.model"))  cpu: \(sysctlString("machdep.cpu.brand_string"))")
print("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
let keyCount = (try? client.keyCount()).map(String.init) ?? "<read failed>"
print("SMC keys (#KEY): \(keyCount)")
print("")

let fans: [FanDevice]
do {
    fans = try FanDiscovery.discoverFans(using: client)
} catch {
    print("fan discovery failed: \(error)")
    fans = []
}

print("== Fan keys (raw) ==")
// `FS! ` (Intel force bitmask) and `Ftst` (unlock key) are never written; listed
// only to record that they are absent (Mac14,9: key not found).
var fanKeyNames = ["FNum", "FS! ", "Ftst"]
for fan in fans {
    for suffix in ["ID", "Mn", "Mx", "Ac", "Tg", "Md", "Sf"] { fanKeyNames.append("F\(fan.id)\(suffix)") }
}
for name in fanKeyNames { print("  " + describeKey(name, client)) }
print("")

print("== Temperature discovery ==")
let sensors = (try? SensorCatalog.discoverTemperatureSensors(using: client)) ?? []
print("plausible temperature keys found: \(sensors.count)")
let sensorKeys = sensors.map(\.id)
print("")

// Aggregates are computed from filtered samples, as in FanControlManager.
var sampleFilter = TemperatureSampleFilter()
let aggregateDefinitions = SensorAggregator.definitions

// Top-level code (and its globals, such as `sampleFilter`) is main-actor isolated in Swift 6.
@MainActor
func readout() {
    let current = FanDiscovery.readCurrentRPMs(fans: fans, using: client)
    let target = FanDiscovery.readTargetRPMs(fans: fans, using: client)
    let modes = FanDiscovery.fanControlModes(fans: fans, using: client)
    print("== Fans (\(fans.count)) @ \(ISO8601DateFormatter().string(from: Date())) ==")
    print("  idx  name              min    max    current  target  mode")
    for fan in fans {
        print("  \(lpad(String(fan.id), 3))  \(pad(fan.name, 16))  \(lpad(String(fan.minRPM), 5))  \(lpad(String(fan.maxRPM), 5))  "
              + "\(lpad(current[fan.id].map(String.init) ?? "-", 7))  \(lpad(target[fan.id].map(String.init) ?? "-", 6))  \(modeString(modes[fan.id]))")
    }
    let temps = SensorCatalog.readTemperatures(keys: sensorKeys, using: client)
    print("== Temperatures (\(temps.count) of \(sensorKeys.count) keys) ==")
    for reading in temps {
        let type = (SMCKey(reading.id).flatMap { try? client.keyInfo($0) })?.dataType.name ?? "?"
        print("  \(pad(reading.id, 4))  [\(type)]  \(lpad(String(format: "%.2f", reading.temperature), 7)) °C  \(reading.name)")
    }
    let filtered = sampleFilter.filter(temps)
    let aggregates = SensorAggregator.aggregates(of: filtered, definitions: aggregateDefinitions)
    print("== Aggregates (from filtered samples; \(sampleFilter.substitutedKeys.count) substituted) ==")
    for reading in aggregates {
        print("  \(pad(reading.id, 9))  \(lpad(String(format: "%.2f", reading.temperature), 7)) °C  \(reading.name)")
    }
}

readout()
if let interval = watchInterval {
    while true {
        Thread.sleep(forTimeInterval: interval)
        print("")
        readout()
    }
}
#else
print("fanfi-probe requires macOS")
#endif
