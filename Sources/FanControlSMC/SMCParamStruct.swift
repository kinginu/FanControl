// AppleSMC user-client wire format (selector kSMCHandleYPCEvent), as documented by
// smcFanControl (smc.h) and SMCKit. Pure data layout with no IOKit dependency, so it is
// compiled on every platform (lets the 80-byte layout be checked off-Mac too).

/// Selector of the AppleSMC user client's single struct method.
let kSMCHandleYPCEvent: UInt32 = 2

// Commands placed in `SMCParamStruct.data8`.
let kSMCReadKey: UInt8 = 5
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyFromIndex: UInt8 = 8
let kSMCGetKeyInfo: UInt8 = 9

// Values reported in `SMCParamStruct.result`.
let kSMCSuccess: UInt8 = 0
let kSMCKeyNotFound: UInt8 = 0x84

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    /// `IOByteCount32` in the C header.
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytesTuple = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// Mirrors `SMCKeyData_t` (80 bytes).
///
/// Swift lays out `SMCKeyInfoData` with size 9 (not the C stride 12), so the explicit
/// `padding` field reproduces C's offsets: `result` at 40, `data32` at 44, `bytes` at 48.
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytesTuple = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    /// Size of the payload buffer.
    static let bytesCapacity = 32

    /// Size handed to `IOConnectCallStructMethod`. Must be 80.
    static let size: Int = {
        let size = MemoryLayout<SMCParamStruct>.size
        precondition(size == 80, "SMCParamStruct must be 80 bytes, got \(size)")
        return size
    }()

    /// Copies the first `count` bytes of the payload (clamped to 0...32).
    func payload(count: Int) -> [UInt8] {
        let n = max(0, min(count, SMCParamStruct.bytesCapacity))
        var copy = bytes
        return withUnsafeBytes(of: &copy) { Array($0.prefix(n)) }
    }

    /// Replaces the payload with `newBytes` (truncated to 32), zero-filling the rest.
    mutating func setPayload(_ newBytes: [UInt8]) {
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<raw.count {
                raw[i] = i < newBytes.count ? newBytes[i] : 0
            }
        }
    }
}
