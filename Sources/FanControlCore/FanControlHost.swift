#if canImport(Darwin)
import Darwin
#endif

/// Host hardware check shared by the app (`FanControlKit.FanControlPlatform`),
/// the helper and `fanfi-probe`. Fan control supports **Apple Silicon only**
/// (Intel dropped 2026-10-20); on any other hardware the entry points fail with
/// `FanControlError.unsupportedPlatform` instead of running an untested write
/// scheme.
public enum FanControlHost {

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

    /// Short description of an unsupported host, for logs and
    /// `FanControlError.unsupportedPlatform`.
    public static let unsupportedDetail =
        "this Mac is not Apple silicon (hw.optional.arm64 != 1); Intel Macs are not supported"

    /// Throws `FanControlError.unsupportedPlatform` unless `isAppleSilicon`.
    public static func requireAppleSilicon() throws {
        guard isAppleSilicon else { throw FanControlError.unsupportedPlatform(unsupportedDetail) }
    }
}
