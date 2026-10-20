#if os(macOS)
import Foundation
import Darwin
import IOKit

/// Cumulative CPU ticks of the whole host (`host_statistics(HOST_CPU_LOAD_INFO)`).
/// The counters are 32-bit and wrap; `usage(from:to:)` subtracts with wrap-around.
public struct CPULoadTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share between two readings in percent (0–100), or `nil` when no tick elapsed.
    public static func usage(from old: CPULoadTicks, to new: CPULoadTicks) -> Double? {
        let busy = UInt64(new.user &- old.user) + UInt64(new.system &- old.system) + UInt64(new.nice &- old.nice)
        let total = busy + UInt64(new.idle &- old.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

/// A tiny CPU / GPU load sampler for workload automation (feature F3), independent of
/// any host statistics code: CPU from `host_statistics` tick deltas between calls,
/// GPU from the IOAccelerator `PerformanceStatistics` "Device Utilization %".
/// Not thread-safe; call from one actor (the host uses the main actor).
public final class SystemLoadSampler {

    private let host: mach_port_t = mach_host_self()
    private var previousTicks: CPULoadTicks?

    public init() {}

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// CPU load since the previous call (`nil` on the first call or if unreadable) and
    /// the current GPU utilization (`nil` if no accelerator reports it).
    public func sample() -> (cpu: Double?, gpu: Double?) {
        var cpu: Double?
        if let ticks = readCPUTicks() {
            if let previousTicks { cpu = CPULoadTicks.usage(from: previousTicks, to: ticks) }
            previousTicks = ticks
        }
        return (cpu, Self.readGPUUtilization())
    }

    private func readCPUTicks() -> CPULoadTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // (user, system, idle, nice): CPU_STATE_USER / SYSTEM / IDLE / NICE
        return CPULoadTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    /// Highest "Device Utilization %" among the IOAccelerator services.
    static func readGPUUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var statistics: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let dictionary = value as? [String: Any] {
                statistics.append(dictionary)
            }
        }
        return gpuUtilization(fromPerformanceStatistics: statistics)
    }

    /// Highest finite "Device Utilization %" (clamped to 0–100) in `statistics`.
    static func gpuUtilization(fromPerformanceStatistics statistics: [[String: Any]]) -> Double? {
        statistics.compactMap { entry -> Double? in
            guard let number = entry["Device Utilization %"] as? NSNumber else { return nil }
            let value = number.doubleValue
            return value.isFinite ? Swift.min(Swift.max(value, 0), 100) : nil
        }.max()
    }
}
#endif
