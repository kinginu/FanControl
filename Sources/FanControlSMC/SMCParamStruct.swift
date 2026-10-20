// AppleSMC user-client wire format (selector `kSMCHandleYPCEvent`), as documented by
// smcFanControl (`smc.h`) and SMCKit. Pure data layout and result interpretation with
// no IOKit dependency, so it is compiled on every platform (lets the 80-byte layout and
// the request/reply logic be checked off-Mac too).

import FanControlCore

/// Selector of the AppleSMC user client's single struct method.
let kSMCHandleYPCEvent: UInt32 = 2

// Commands placed in `SMCParamStruct.data8`.
let kSMCReadKey: UInt8 = 5
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyFromIndex: UInt8 = 8
let kSMCGetKeyInfo: UInt8 = 9

// Values reported in `SMCParamStruct.result`. Only these two are interpreted; any other
// non-zero byte is surfaced verbatim as the `code` of `readFailed`/`writeFailed`.
// Commonly cited values (not documented by Apple): 0x85 key not readable,
// 0x86 key not writable, 0x87 key size mismatch, 0x89 bad argument,
// 0xB7 timeout, 0xB8 key index out of range.
let kSMCSuccess: UInt8 = 0
let kSMCKeyNotFound: UInt8 = 0x84

/// The `code` carried by `FanControlError.readFailed`/`.writeFailed` when the failure
/// is detected locally (argument validation, short reply) rather than reported by
/// IOKit (`kern_return_t`, always negative for `kIOReturn*` errors) or by the SMC
/// (the result byte, 1...255).
let kSMCLocalFailureCode: Int32 = -1

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

    /// Size of the payload buffer. Keys whose `dataSize` exceeds it cannot be read or
    /// written through this struct (the Mac14,9 dump has a few, e.g. 118-byte `ACKG`).
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
        return withUnsafeBytes(of: bytes) { Array($0.prefix(n)) }
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

// MARK: - Requests

extension SMCParamStruct {
    /// `kSMCGetKeyInfo` for `key`: the reply's `keyInfo` holds size, type and attributes.
    static func keyInfoRequest(_ key: SMCKey) -> SMCParamStruct {
        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = kSMCGetKeyInfo
        return input
    }

    /// `kSMCReadKey` for `key`, whose value is `size` bytes (from its key info).
    static func readRequest(_ key: SMCKey, size: Int) -> SMCParamStruct {
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = UInt32(clamping: size)
        input.data8 = kSMCReadKey
        return input
    }

    /// `kSMCGetKeyFromIndex` for enumeration index `index`: the reply's `key` is the key.
    static func keyAtIndexRequest(_ index: UInt32) -> SMCParamStruct {
        var input = SMCParamStruct()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = index
        return input
    }

    /// `kSMCWriteKey` of `bytes` (at most `bytesCapacity`) to `key`.
    static func writeRequest(_ key: SMCKey, bytes: [UInt8]) -> SMCParamStruct {
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = UInt32(clamping: bytes.count)
        input.data8 = kSMCWriteKey
        input.setPayload(bytes)
        return input
    }
}

// MARK: - Replies

extension SMCParamStruct {
    /// The key a request refers to, for error messages: the key name, or `#<index>`
    /// for `kSMCGetKeyFromIndex` (whose `key` field is unset).
    var subjectDescription: String {
        data8 == kSMCGetKeyFromIndex ? "#\(data32)" : SMCKey(code: key).name
    }

    /// The error for a failed round trip of this request: `writeFailed` for
    /// `kSMCWriteKey`, `readFailed` for every other command.
    func failure(code: Int32) -> FanControlError {
        data8 == kSMCWriteKey
            ? .writeFailed(key: subjectDescription, code: code)
            : .readFailed(key: subjectDescription, code: code)
    }

    /// Interprets the SMC result byte of `output`, the reply to this request.
    ///
    /// Returns `output` on `kSMCSuccess`; throws `keyNotFound` for `0x84` and
    /// `readFailed`/`writeFailed` with the result byte as `code` otherwise.
    func validate(reply output: SMCParamStruct) throws -> SMCParamStruct {
        switch output.result {
        case kSMCSuccess:
            return output
        case kSMCKeyNotFound:
            throw FanControlError.keyNotFound(subjectDescription)
        default:
            throw failure(code: Int32(output.result))
        }
    }
}
