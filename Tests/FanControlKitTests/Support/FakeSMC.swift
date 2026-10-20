import Foundation
import Synchronization
import FanControlCore

/// The one in-memory SMC of the Kit tests (never the IOKit `SMCClient`): a reader
/// (`SMCReader`, for `FanWriteStrategy` and the poller) and the write target of
/// `FakeHelper` (which runs on XPC queues). Thread-safe; records every successful
/// write in order.
final class FakeSMC: SMCReader, Sendable {
    struct Entry: Sendable {
        var type: SMCDataType
        var bytes: [UInt8]
        var attributes: UInt8
    }

    struct State: Sendable {
        var entries: [SMCKey: Entry] = [:]
        var order: [SMCKey] = []
        /// Successful writes, in order.
        var writes: [(key: SMCKey, bytes: [UInt8])] = []
        /// Keys whose next `remaining` writes fail (value: remaining count, `Int.max` = always).
        var failingWrites: [SMCKey: Int] = [:]
    }

    private let state: Mutex<State>

    init(_ list: [(String, SMCDataType, [UInt8], UInt8)]) {
        var initial = State()
        for (name, type, bytes, attributes) in list {
            let key = SMCKey(name)!
            initial.entries[key] = Entry(type: type, bytes: bytes, attributes: attributes)
            initial.order.append(key)
        }
        state = Mutex(initial)
    }

    /// Keys without attributes (0x00), for tests that only read.
    convenience init(_ list: [(String, SMCDataType, [UInt8])]) {
        self.init(list.map { ($0.0, $0.1, $0.2, UInt8(0)) })
    }

    /// Mac14,9-like layout (`docs/verification/Mac14,9-macOS26-dump.txt`): two fans,
    /// `F<n>Md` ui8 (0xd0), `F<n>Tg` flt (0xd4), read-only `F<n>Mn`/`Mx` (0x84),
    /// idle (automatic, `Tg` = 0).
    static func mac14_9() -> FakeSMC {
        FakeSMC([
            ("FNum", .ui8, [2], 0x80),
            ("F0Md", .ui8, [0], 0xd0),
            ("F0Mn", .flt, flt(2317), 0x84),
            ("F0Mx", .flt, flt(6800), 0x84),
            ("F0Ac", .flt, flt(0), 0x80),
            ("F0Tg", .flt, flt(0), 0xd4),
            ("F1Md", .ui8, [0], 0xd0),
            ("F1Mn", .flt, flt(2317), 0x84),
            ("F1Mx", .flt, flt(6800), 0x84),
            ("F1Ac", .flt, flt(0), 0x80),
            ("F1Tg", .flt, flt(0), 0xd4),
        ])
    }

    static func flt(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .flt, size: 4)! }
    static func fpe2(_ value: Double) -> [UInt8] { SMCCodec.encode(value, as: .fpe2, size: 2)! }

    // MARK: SMCReader

    func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        try state.withLock { state in
            guard let entry = state.entries[key] else { throw FanControlError.keyNotFound(key.name) }
            return SMCKeyInfo(dataSize: entry.bytes.count, dataType: entry.type, attributes: entry.attributes)
        }
    }

    func readBytes(_ key: SMCKey) throws -> [UInt8] {
        try state.withLock { state in
            guard let entry = state.entries[key] else { throw FanControlError.keyNotFound(key.name) }
            return entry.bytes
        }
    }

    func keyCount() throws -> Int { state.withLock { $0.order.count } }

    func key(at index: Int) throws -> SMCKey {
        try state.withLock { state in
            guard state.order.indices.contains(index) else { throw FanControlError.invalidKey("#\(index)") }
            return state.order[index]
        }
    }

    // MARK: Writing (helper side) and inspection

    func writeBytes(_ bytes: [UInt8], to key: SMCKey) throws {
        try state.withLock { state in
            guard state.entries[key] != nil else { throw FanControlError.keyNotFound(key.name) }
            if let remaining = state.failingWrites[key], remaining > 0 {
                if remaining != .max { state.failingWrites[key] = remaining - 1 }
                throw FanControlError.writeFailed(key: key.name, code: -1)
            }
            state.entries[key]!.bytes = bytes
            state.writes.append((key, bytes))
        }
    }

    /// Makes the next `count` writes to `key` fail at the SMC level.
    func failWrites(to key: String, count: Int = .max) {
        state.withLock { $0.failingWrites[SMCKey(key)!] = count }
    }

    /// Sets a value directly (e.g. what the SMC does on its own after wake).
    func poke(_ key: String, _ bytes: [UInt8]) {
        state.withLock { $0.entries[SMCKey(key)!]!.bytes = bytes }
    }

    /// Successful writes as `"F0Md=1"` / `"F0Tg=3000"` (decoded with the key's type).
    var writeLog: [String] {
        state.withLock { state in
            state.writes.map { write in
                let type = state.entries[write.key]!.type
                let number = SMCCodec.decode(write.bytes, as: type)?.doubleValue ?? .nan
                return "\(write.key.name)=\(number.isFinite ? String(Int(number.rounded())) : "?")"
            }
        }
    }

    func clearWriteLog() { state.withLock { $0.writes = [] } }

    func number(_ key: String) -> Double? { try? readNumber(SMCKey(key)!) }
}
