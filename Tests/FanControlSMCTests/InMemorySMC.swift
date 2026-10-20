import Foundation
import Synchronization
import FanControlCore
@testable import FanControlSMC

/// An in-memory AppleSMC behind the `SMCTransport` seam: answers the four commands
/// `SMCClient` sends with the result bytes the real SMC uses, and records traffic.
final class InMemorySMC: SMCTransport, Sendable {
    struct Entry: Sendable {
        var name: String
        /// `nil` = the SMC returns no key info (`kSMCKeyNotFound` for `kSMCGetKeyInfo`).
        var info: SMCKeyInfo?
        /// `nil` = reading fails with `resultNotReadable`.
        var bytes: [UInt8]?
    }

    static let resultNotReadable: UInt8 = 0x85
    static let resultNotWritable: UInt8 = 0x86
    static let resultSizeMismatch: UInt8 = 0x87
    static let resultIndexRange: UInt8 = 0xB8

    struct State {
        var entries: [Entry]
        var byCode: [UInt32: Int]
        var closed = false
        var requests: [SMCParamStruct] = []
        /// When set, every `send` throws `request.failure(code:)` with this code (an IOKit error).
        var transportFailure: Int32?
    }

    let state: Mutex<State>

    init(entries: [Entry]) {
        var byCode: [UInt32: Int] = [:]
        for (i, entry) in entries.enumerated() { byCode[Self.code(entry.name)] = i }
        state = Mutex(State(entries: entries, byCode: byCode))
    }

    /// Packs a 4-character name (`?` = NUL, as `dump()` prints it).
    static func code(_ name: String) -> UInt32 {
        Array(name.utf8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1 == UInt8(ascii: "?") ? 0 : $1) }
    }

    var requests: [SMCParamStruct] { state.withLock { $0.requests } }
    func requests(command: UInt8) -> [SMCParamStruct] { requests.filter { $0.data8 == command } }
    func bytes(of name: String) -> [UInt8]? {
        state.withLock { s in s.byCode[Self.code(name)].flatMap { s.entries[$0].bytes } }
    }
    func failTransport(with code: Int32?) { state.withLock { $0.transportFailure = code } }

    // MARK: SMCTransport

    func send(_ request: SMCParamStruct) throws -> SMCParamStruct {
        try state.withLock { s in
            guard !s.closed else { throw FanControlError.smcUnavailable }
            s.requests.append(request)
            if let code = s.transportFailure { throw request.failure(code: code) }

            var reply = SMCParamStruct()
            let index = s.byCode[request.key]
            switch request.data8 {
            case kSMCGetKeyInfo:
                guard let index, let info = s.entries[index].info else {
                    reply.result = kSMCKeyNotFound
                    break
                }
                reply.keyInfo.dataSize = UInt32(info.dataSize)
                reply.keyInfo.dataType = info.rawType
                reply.keyInfo.dataAttributes = info.attributes
            case kSMCReadKey:
                guard let index, let info = s.entries[index].info else {
                    reply.result = kSMCKeyNotFound
                    break
                }
                guard let bytes = s.entries[index].bytes else {
                    reply.result = Self.resultNotReadable
                    break
                }
                guard Int(request.keyInfo.dataSize) == info.dataSize else {
                    reply.result = Self.resultSizeMismatch
                    break
                }
                reply.setPayload(bytes)
            case kSMCGetKeyFromIndex:
                guard Int(request.data32) < s.entries.count else {
                    reply.result = Self.resultIndexRange
                    break
                }
                reply.key = Self.code(s.entries[Int(request.data32)].name)
            case kSMCWriteKey:
                guard let index, let info = s.entries[index].info else {
                    reply.result = kSMCKeyNotFound
                    break
                }
                guard info.isWritable else {
                    reply.result = Self.resultNotWritable
                    break
                }
                guard Int(request.keyInfo.dataSize) == info.dataSize else {
                    reply.result = Self.resultSizeMismatch
                    break
                }
                s.entries[index].bytes = request.payload(count: info.dataSize)
            default:
                reply.result = 0x82 // bad command
            }
            return reply
        }
    }

    func close() {
        state.withLock { $0.closed = true }
    }
}

// MARK: - Mac14,9 / macOS 26 dump fixture

/// `docs/verification/Mac14,9-macOS26-dump.txt`, a real `SMCClient.dump()` of an
/// M2 Pro MacBook Pro (2299 keys).
enum DumpFixture {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FanControlSMCTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // FanControl
        .appendingPathComponent("docs/verification/Mac14,9-macOS26-dump.txt")

    /// The fixture's lines, without the trailing empty line.
    static let lines: [String] = {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }()

    /// Lines whose value was redacted before the dump was committed.
    static func isRedacted(_ line: String) -> Bool { line.contains("<redacted") }

    /// Parses a key line: `NAME  [TYPE] size=N attr=XX  VALUE` or `NAME  <no key info>`.
    /// A redacted value is treated as unreadable.
    static func entry(_ line: String) -> InMemorySMC.Entry? {
        let chars = Array(line)
        guard chars.count > 6, chars[4] == " ", chars[5] == " " else { return nil }
        let name = String(chars[0..<4])
        let rest = String(chars[6...])
        if rest == "<no key info>" { return .init(name: name, info: nil, bytes: nil) }

        guard rest.first == "[", rest.count > 6 else { return nil }
        let restChars = Array(rest)
        let typeName = String(restChars[1..<5])
        guard restChars[5] == "]" else { return nil }
        let fields = String(restChars[6...])
        guard let match = fields.wholeMatch(of: /\ size=(\d+)\ attr=([0-9a-f]{2})\ \ (.*)/),
              let size = Int(match.1), let attr = UInt8(match.2, radix: 16) else { return nil }
        let value = String(match.3)
        let bytes: [UInt8]? = value.hasPrefix("<")
            ? nil
            : value.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        let rawType = InMemorySMC.code(typeName)
        let info = SMCKeyInfo(dataSize: size, dataType: SMCDataType(fourCC: rawType),
                              attributes: attr, rawType: rawType)
        return .init(name: name, info: info, bytes: bytes)
    }

    static let entries: [InMemorySMC.Entry] = lines.dropFirst().compactMap(entry)

    /// A fresh in-memory SMC loaded with the fixture.
    static func smc() -> InMemorySMC { InMemorySMC(entries: entries) }
}
