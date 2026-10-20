#if os(macOS)
import Foundation
import Synchronization
import FanControlCore

/// IOKit-backed `SMCReader` with a key-info cache.
///
/// `writeBytes(_:to:)` talks to the SMC directly and only succeeds as root; the app must
/// go through FanControlHelper (XPC) instead.
/// Thread-safe (checked `Sendable`): the connection serializes its calls and the
/// cache is a `Mutex`.
public final class SMCClient: SMCReader, Sendable {
    private let connection: SMCConnection
    private let keyInfoCache = Mutex<[UInt32: SMCKeyInfo]>([:])

    /// Opens a new AppleSMC connection.
    public convenience init() throws {
        try self.init(connection: SMCConnection())
    }

    public init(connection: SMCConnection) {
        self.connection = connection
    }

    /// Closes the underlying connection.
    public func close() {
        connection.close()
    }

    // MARK: SMCReader

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = keyInfoCache.withLock({ $0[key.code] }) { return cached }

        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = kSMCGetKeyInfo
        let output = try connection.call(&input)
        let info = SMCKeyInfo(dataSize: Int(output.keyInfo.dataSize),
                              dataType: SMCDataType(fourCC: output.keyInfo.dataType),
                              attributes: output.keyInfo.dataAttributes,
                              rawType: output.keyInfo.dataType)

        keyInfoCache.withLock { $0[key.code] = info }
        return info
    }

    public func readBytes(_ key: SMCKey) throws -> [UInt8] {
        let info = try keyInfo(key)
        guard info.dataSize >= 0, info.dataSize <= SMCParamStruct.bytesCapacity else {
            throw FanControlError.readFailed(key: key.name, code: -1)
        }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = kSMCReadKey
        let output = try connection.call(&input)
        return output.payload(count: info.dataSize)
    }

    public func keyCount() throws -> Int {
        let bytes = try readBytes(.keyCount)
        guard bytes.count >= 4 else {
            throw FanControlError.readFailed(key: SMCKey.keyCount.name, code: -1)
        }
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(value)
    }

    public func key(at index: Int) throws -> SMCKey {
        guard index >= 0, index <= Int(UInt32.max) else {
            throw FanControlError.readFailed(key: "#\(index)", code: -1)
        }
        var input = SMCParamStruct()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        let output = try connection.call(&input)
        return SMCKey(code: output.key)
    }

    // MARK: Writing (root only)

    /// Writes raw bytes to `key`. `bytes.count` must equal the key's `dataSize`
    /// (otherwise throws `writeFailed(code: -1)` without touching the SMC).
    /// Only works for a root process (FanControlHelper).
    public func writeBytes(_ bytes: [UInt8], to key: SMCKey) throws {
        guard !bytes.isEmpty, bytes.count <= SMCParamStruct.bytesCapacity else {
            throw FanControlError.writeFailed(key: key.name, code: -1)
        }
        guard bytes.count == (try keyInfo(key)).dataSize else {
            throw FanControlError.writeFailed(key: key.name, code: -1)
        }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = kSMCWriteKey
        input.setPayload(bytes)
        _ = try connection.call(&input)
    }

    // MARK: Diagnostics

    /// Lists every SMC key as `KEY  [type] size  hex`, one per line
    /// (backs `exportSMCDump()` in the integration design).
    public func dump() -> String {
        var lines: [String] = []
        let count: Int
        do {
            count = try keyCount()
        } catch {
            return "SMC dump failed: \(error)"
        }
        lines.append("# SMC keys: \(count)")
        for index in 0..<count {
            guard let k = try? key(at: index) else {
                lines.append("#\(index)  <unreadable index>")
                continue
            }
            let name = k.name.replacingOccurrences(of: "\0", with: "?")
            guard let info = try? keyInfo(k) else {
                lines.append("\(name)  <no key info>")
                continue
            }
            let typeName = info.dataType.name.replacingOccurrences(of: "\0", with: " ")
            let attrs = String(format: "%02x", info.attributes)
            let value: String
            if let bytes = try? readBytes(k) {
                value = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            } else {
                value = "<read failed>"
            }
            lines.append("\(name)  [\(typeName)] size=\(info.dataSize) attr=\(attrs)  \(value)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
