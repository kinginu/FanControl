import FanControlCore

/// Minimal in-memory `SMCReader` (copied from FanControlCoreTests; test targets cannot import each other).
final class MockSMCReader: SMCReader {
    var entries: [SMCKey: (type: SMCDataType, bytes: [UInt8])]
    var order: [SMCKey]

    init(_ list: [(String, SMCDataType, [UInt8])]) {
        var entries: [SMCKey: (type: SMCDataType, bytes: [UInt8])] = [:]
        var order: [SMCKey] = []
        for (name, type, bytes) in list {
            let key = SMCKey(name)!
            entries[key] = (type, bytes)
            order.append(key)
        }
        self.entries = entries
        self.order = order
    }

    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return SMCKeyInfo(dataSize: entry.bytes.count, dataType: entry.type)
    }

    func readBytes(_ key: SMCKey) throws -> [UInt8] {
        guard let entry = entries[key] else { throw FanControlError.keyNotFound(key.name) }
        return entry.bytes
    }

    func keyCount() throws -> Int { order.count }

    func key(at index: Int) throws -> SMCKey {
        guard order.indices.contains(index) else { throw FanControlError.invalidKey("#\(index)") }
        return order[index]
    }
}

enum Bytes {
    static func fpe2(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .fpe2, size: 2)! }
    static func flt(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .flt, size: 4)! }
}
