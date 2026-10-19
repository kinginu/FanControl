#if canImport(Darwin)
import Darwin
#endif
import FanControlCore

/// Host CPU architecture detection used to pick architecture-dependent defaults
/// (`SafetyPolicy.default(appleSilicon:)`).
///
/// This deliberately does not reuse `FanWriteStrategy.ControlStyle`: the
/// `F<i>Md` mode key that marks the "Apple Silicon style" write scheme also
/// exists on some late Intel models, and the strategy is only known after fan
/// discovery, whereas the policy is needed when `FanControlManager` is created.
public enum FanControlPlatform {

    /// `true` on Apple Silicon Macs, also when the process runs under Rosetta 2
    /// (`sysctl hw.optional.arm64` reports the hardware, not the process
    /// architecture). Falls back to the compile-time architecture if the sysctl
    /// is unavailable (Intel Macs do not have it → `false`).
    public static let isAppleSilicon: Bool = {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        #endif
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// `SafetyPolicy.default(appleSilicon: isAppleSilicon)`: the policy
    /// `FanControlManager` starts with.
    public static var defaultSafetyPolicy: SafetyPolicy {
        .default(appleSilicon: isAppleSilicon)
    }

    /// `SensorAggregator.definitions(appleSilicon: isAppleSilicon)`: the
    /// aggregate sensors `FanControlManager` appends to `sensorReadings`.
    public static var sensorAggregateDefinitions: [SensorAggregateDefinition] {
        SensorAggregator.definitions(appleSilicon: isAppleSilicon)
    }
}
