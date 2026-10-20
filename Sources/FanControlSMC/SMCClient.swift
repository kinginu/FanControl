import FanControlCore
import Synchronization

/// AppleSMC access: an `SMCReader` over the SMC user client, with a key-info cache.
///
/// - Reading needs no privileges and is what the app does in-process.
/// - `writeBytes(_:to:)` talks to the SMC directly and only succeeds as root; the app
///   must go through FanControlHelper (XPC) instead.
///
/// Thread-safe (checked `Sendable`): the connection serializes its round trips and the
/// cache is a `Mutex`. Call `close()` when done, or let the client deinitialize.
public final class SMCClient: SMCReader, Sendable {
    private let transport: any SMCTransport
    /// Key info by FourCC. The SMC's key set and key metadata are fixed for the boot,
    /// so entries never expire; failed lookups are not cached.
    private let keyInfoCache = Mutex<[UInt32: SMCKeyInfo]>([:])

    #if os(macOS)
    /// Opens a new AppleSMC connection. Throws `FanControlError.smcUnavailable` if the
    /// service is missing or cannot be opened.
    public convenience init() throws {
        try self.init(transport: SMCConnection())
    }
    #endif

    /// Wraps `transport` (the IOKit connection, or an in-memory SMC in tests).
    init(transport: any SMCTransport) {
        self.transport = transport
    }

    /// Closes the underlying connection. Later calls throw `smcUnavailable`, except
    /// `keyInfo(_:)` for keys already cached. Idempotent.
    public func close() {
        transport.close()
    }

    // MARK: SMCReader

    /// Size, type and attributes of `key` (cached after the first success).
    /// Throws `keyNotFound` if the SMC has no such key.
    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = keyInfoCache.withLock({ $0[key.code] }) { return cached }

        let output = try call(.keyInfoRequest(key))
        let info = SMCKeyInfo(dataSize: Int(output.keyInfo.dataSize),
                              dataType: SMCDataType(fourCC: output.keyInfo.dataType),
                              attributes: output.keyInfo.dataAttributes,
                              rawType: output.keyInfo.dataType)

        keyInfoCache.withLock { $0[key.code] = info }
        return info
    }

    /// The raw value of `key`, exactly `keyInfo(key).dataSize` bytes.
    ///
    /// Throws `readFailed(code: -1)` for keys larger than the 32-byte payload buffer,
    /// `keyNotFound` for missing keys, and `readFailed` with the SMC result byte
    /// otherwise (e.g. `0x85` for keys without the read attribute).
    public func readBytes(_ key: SMCKey) throws -> [UInt8] {
        let info = try keyInfo(key)
        guard (0...SMCParamStruct.bytesCapacity).contains(info.dataSize) else {
            throw FanControlError.readFailed(key: key.name, code: kSMCLocalFailureCode)
        }
        let output = try call(.readRequest(key, size: info.dataSize))
        return output.payload(count: info.dataSize)
    }

    /// The number of keys, from `#KEY` (a big-endian `ui32` on every known SMC).
    public func keyCount() throws -> Int {
        let bytes = try readBytes(.keyCount)
        guard bytes.count == 4 else {
            throw FanControlError.readFailed(key: SMCKey.keyCount.name, code: kSMCLocalFailureCode)
        }
        return Int(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    /// The key at enumeration `index` (`0..<keyCount()`).
    public func key(at index: Int) throws -> SMCKey {
        guard let rawIndex = UInt32(exactly: index) else {
            throw FanControlError.readFailed(key: "#\(index)", code: kSMCLocalFailureCode)
        }
        return SMCKey(code: try call(.keyAtIndexRequest(rawIndex)).key)
    }

    // MARK: Writing (root only)

    /// Writes raw bytes to `key`. Only works for a root process (FanControlHelper).
    ///
    /// `bytes.count` must equal the key's `dataSize` and fit the 32-byte payload;
    /// otherwise throws `writeFailed(code: -1)` without writing. A non-root caller gets
    /// `writeFailed` with IOKit's `kIOReturnNotPrivileged`. This method does not check
    /// the write attribute (`SMCKeyInfo.isWritable`) or any allow-list; the helper does.
    public func writeBytes(_ bytes: [UInt8], to key: SMCKey) throws {
        guard !bytes.isEmpty, bytes.count <= SMCParamStruct.bytesCapacity,
              bytes.count == (try keyInfo(key)).dataSize else {
            throw FanControlError.writeFailed(key: key.name, code: kSMCLocalFailureCode)
        }
        _ = try call(.writeRequest(key, bytes: bytes))
    }

    // MARK: Diagnostics

    /// Lists every SMC key as `KEY  [type] size=N attr=XX  hex bytes`, one per line,
    /// after a `# SMC keys: N` header (backs `exportSMCDump()` and `fanfi-probe --dump`).
    /// Read-only. Per-key failures become `<unreadable index>`, `<no key info>` or
    /// `<read failed>` lines; NULs in names are shown as `?` (types: as spaces).
    public func dump() -> String {
        let count: Int
        do {
            count = try keyCount()
        } catch {
            return "SMC dump failed: \(error)"
        }
        var lines = ["# SMC keys: \(count)"]
        lines.reserveCapacity(count + 1)
        for index in 0..<count {
            guard let key = try? key(at: index) else {
                lines.append("#\(index)  <unreadable index>")
                continue
            }
            let info = try? keyInfo(key)
            let bytes = info == nil ? nil : try? readBytes(key)
            lines.append(Self.dumpLine(key: key, info: info, bytes: bytes))
        }
        return lines.joined(separator: "\n")
    }

    /// One `dump()` line for `key` (`info == nil`: no key info; `bytes == nil`: read failed).
    static func dumpLine(key: SMCKey, info: SMCKeyInfo?, bytes: [UInt8]?) -> String {
        let name = key.name.replacing("\0", with: "?")
        guard let info else { return "\(name)  <no key info>" }
        let type = info.dataType.name.replacing("\0", with: " ")
        let value = bytes.map { $0.map(hex).joined(separator: " ") } ?? "<read failed>"
        return "\(name)  [\(type)] size=\(info.dataSize) attr=\(hex(info.attributes))  \(value)"
    }

    // MARK: Private

    /// One round trip with the SMC result byte checked.
    private func call(_ request: SMCParamStruct) throws -> SMCParamStruct {
        try request.validate(reply: transport.send(request))
    }

    /// Two lowercase hex digits.
    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
    }
}
