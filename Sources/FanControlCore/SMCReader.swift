import Foundation

/// Metadata returned by the SMC key-info call.
public struct SMCKeyInfo: Hashable, Sendable {
    /// Size of the value in bytes.
    public var dataSize: Int
    /// Data type of the value.
    public var dataType: SMCDataType
    /// Attribute bitmask reported by the SMC.
    public var attributes: UInt8
    /// Raw data-type FourCC exactly as reported by the SMC (0 if unknown).
    /// Preserved so callers can forward it verbatim (e.g. over XPC).
    public var rawType: UInt32

    public init(dataSize: Int, dataType: SMCDataType, attributes: UInt8 = 0, rawType: UInt32 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
        self.rawType = rawType
    }

    /// Whether the key is readable (`0x80`). Not documented by Apple; on the
    /// Mac14,9 / macOS 26 dump every key that read successfully had `0x80` set and
    /// every key without it failed to read (`docs/verification/`).
    public var isReadable: Bool { attributes & 0x80 != 0 }

    /// Whether the key is writable (`0x40`). Not documented by Apple. `0x80` is
    /// the read bit, not the write bit: read-only keys such as `#KEY`, `FNum`
    /// and `F<n>Mn` report `0x80`/`0x84`, while `F<n>Tg` (`0xd4`) and `F<n>Md`
    /// (`0xd0`) also carry `0x40`. Inferred from attributes only; no write has
    /// been attempted to confirm it.
    public var isWritable: Bool { attributes & 0x40 != 0 }
}

/// Read-only access to the SMC. Implemented by the IOKit-backed reader on
/// macOS and by mocks in tests.
public protocol SMCReader: AnyObject {
    /// Returns size/type/attributes of `key`. Throws `.keyNotFound` if absent.
    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo
    /// Returns the raw bytes of `key` (exactly `keyInfo(key).dataSize` bytes).
    func readBytes(_ key: SMCKey) throws -> [UInt8]
    /// Total number of keys (`#KEY`).
    func keyCount() throws -> Int
    /// The key at enumeration `index` (0-based).
    func key(at index: Int) throws -> SMCKey
}

public extension SMCReader {
    /// Reads and decodes `key` using its reported data type.
    func readValue(_ key: SMCKey) throws -> SMCValue {
        try readDecoded(key).value
    }

    /// Reads `key` as a number. Throws `.unsupportedDataType` if the value is not numeric.
    func readNumber(_ key: SMCKey) throws -> Double {
        let (info, value) = try readDecoded(key)
        guard let number = value.doubleValue else {
            throw FanControlError.unsupportedDataType(info.dataType.name)
        }
        return number
    }

    /// `true` if the SMC reports key-info for `key`.
    func exists(_ key: SMCKey) -> Bool {
        (try? keyInfo(key)) != nil
    }

    private func readDecoded(_ key: SMCKey) throws -> (info: SMCKeyInfo, value: SMCValue) {
        let info = try keyInfo(key)
        let bytes = try readBytes(key)
        guard let value = SMCCodec.decode(bytes, as: info.dataType) else {
            throw FanControlError.unsupportedDataType(info.dataType.name)
        }
        return (info, value)
    }
}

/// Privileged write access to the SMC (implemented by the helper / XPC client).
public protocol SMCWriter: AnyObject {
    /// Begins a control session (e.g. unlocks manual fan control).
    func openSession() async throws
    /// Writes raw bytes to `key`. Requires an open session.
    func write(key: SMCKey, bytes: [UInt8]) async throws
    /// Ends the session and returns fans to automatic control.
    func closeSession() async
    /// Whether a session is currently open.
    var isSessionOpen: Bool { get async }
}
