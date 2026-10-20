#if os(macOS)
import Foundation
import Synchronization
import FanControlCore
import FanControlXPC
@testable import FanControlKit

/// In-process stand-in for FanControlHelper, served over a real anonymous
/// `NSXPCListener` (no launchd, no root, no code-signing requirement unless a test
/// sets one).
///
/// The session logic mirrors `SessionRegistry` / `SessionState` of the helper
/// executable (which is bound to the IOKit `SMCClient` and a process-wide singleton,
/// so it cannot run here): single owner per connection with same-pid reclaim,
/// allowlist (`FanControlHelperConstants.isWriteAllowed`), value validation
/// (`HelperWritePolicy.validate`) against the `Mn...Mx` read at open, snapshot
/// before the first write of a key, restore through `HelperWritePolicy.restore` on
/// close / connection loss / shutdown, and sleep/wake through
/// `PowerTransitionPolicy`. The decision logic is the real one; only the glue is
/// duplicated. Keep it in step with `Sources/FanControlHelper/SessionRegistry.swift`.
final class FakeHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    /// What the listener does with a new connection.
    enum AcceptMode: Sendable {
        case accept
        /// Accept, then invalidate the connection as soon as the first message
        /// arrives (what the helper's system-enforced client requirement does).
        case dropOnFirstMessage
        /// `shouldAcceptNewConnection` returns `false`.
        case refuse
        /// Accept with this code-signing requirement on the client (as
        /// `HelperListenerDelegate` does); the system then rejects the messages.
        case clientRequirement(String)
    }

    struct Config: Sendable {
        var version = FanControlHelperConstants.protocolVersion
        var acceptMode = AcceptMode.accept
        /// Methods that never reply ("version", "openSession", "writeKey", "closeSession").
        var hangingMethods: Set<String> = []
        /// Give each connection its own fake (alive) pid instead of this process's,
        /// so a second client is refused (`notSessionOwner`) instead of reclaiming.
        var distinctPids = false
    }

    struct Owner: Equatable, Sendable {
        let pid: pid_t
        let connectionID: UInt64
    }

    private struct Session: Sendable {
        var owner: Owner?
        var originals: [(key: SMCKey, bytes: [UInt8])] = []
        var fanCount: Int?
        var fanLimits: [Int: ClosedRange<Double>] = [:]
        var lastWritten: [SMCKey: [UInt8]] = [:]
        var nextConnectionID: UInt64 = 1
        /// Owners whose session was ended by connection loss (`release`).
        var released: [Owner] = []
        var acceptedConnections = 0
        var receivedMessages = 0
        var restores: [[HelperWritePolicy.RestoreWrite]] = []
    }

    let smc: FakeSMC
    private let listener: NSXPCListener
    private let config: Mutex<Config>
    private let session = Mutex(Session())
    /// Connections must stay referenced while they live.
    private let connectionsLock = NSLock()
    private var connections: [UInt64: NSXPCConnection] = [:]

    init(smc: FakeSMC = .mac14_9(), config: Config = Config()) {
        self.smc = smc
        self.config = Mutex(config)
        self.listener = NSXPCListener.anonymous()
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
        for connection in connectionsLock.withLock({ Array(connections.values) }) { connection.invalidate() }
    }

    func updateConfig(_ change: (inout Config) -> Void) {
        config.withLock { change(&$0) }
    }

    /// A `HelperClient` connected to this fake through `init(connectionFactory:)`.
    /// `configure` may adjust each new client-side connection (e.g. set a
    /// code-signing requirement on the helper).
    func makeClient(timeout: TimeInterval = 5,
                    configure: (@Sendable (NSXPCConnection) -> Void)? = nil) -> HelperClient {
        let endpoint = UncheckedBox(listener.endpoint)
        let client = HelperClient(connectionFactory: {
            let connection = NSXPCConnection(listenerEndpoint: endpoint.value)
            configure?(connection)
            return connection
        })
        client.callTimeout = timeout
        return client
    }

    // MARK: Inspection

    var owner: Owner? { session.withLock { $0.owner } }
    var released: [Owner] { session.withLock { $0.released } }
    var acceptedConnections: Int { session.withLock { $0.acceptedConnections } }
    var receivedMessages: Int { session.withLock { $0.receivedMessages } }
    var restores: [[HelperWritePolicy.RestoreWrite]] { session.withLock { $0.restores } }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let config = self.config.withLock { $0 }
        if case .refuse = config.acceptMode { return false }
        if case .clientRequirement(let requirement) = config.acceptMode {
            newConnection.setCodeSigningRequirement(requirement)
        }
        let id = session.withLock { state -> UInt64 in
            defer { state.nextConnectionID += 1 }
            state.acceptedConnections += 1
            return state.nextConnectionID
        }
        let pid = config.distinctPids ? pid_t(100_000 + Int32(id)) : newConnection.processIdentifier
        let owner = Owner(pid: pid, connectionID: id)
        let weakConnection = WeakBox(newConnection)
        let service = FakeHelperService(helper: self, owner: owner, drop: {
            guard case .dropOnFirstMessage = config.acceptMode else { return false }
            weakConnection.value?.invalidate()
            return true
        })
        newConnection.exportedInterface = makeHelperInterface()
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak self] in
            self?.release(owner)
            guard let self else { return }
            _ = self.connectionsLock.withLock { self.connections.removeValue(forKey: id) }
        }
        newConnection.interruptionHandler = { [weak self] in self?.release(owner) }
        connectionsLock.withLock { connections[id] = newConnection }
        newConnection.resume()
        return true
    }

    // MARK: Session logic (mirrors SessionState)

    fileprivate func isHanging(_ method: String) -> Bool {
        config.withLock { $0.hangingMethods.contains(method) }
    }

    fileprivate var reportedVersion: Int { config.withLock { $0.version } }

    fileprivate func noteMessage() {
        session.withLock { $0.receivedMessages += 1 }
    }

    fileprivate func open(for requester: Owner) -> (FanControlHelperErrorCode, String) {
        session.withLock { state in
            if let current = state.owner {
                if current == requester { return (.ok, "session already open") }
                if current.pid == requester.pid {
                    endSession(&state)  // same process, new connection: reclaim
                } else {
                    return (.notSessionOwner, "session is owned by pid \(current.pid)")
                }
            }
            state.owner = requester
            state.originals = []
            state.lastWritten = [:]
            state.fanLimits = [:]
            let count = (try? smc.readNumber(.fanCount)).map { Int(min(max($0, 0), 10)) }
            state.fanCount = count
            for fan in 0..<(count ?? 0) {
                if let lo = try? smc.readNumber(.fanMin(fan)), let hi = try? smc.readNumber(.fanMax(fan)), lo <= hi {
                    state.fanLimits[fan] = lo...hi
                }
            }
            return (.ok, "session opened")
        }
    }

    fileprivate func write(_ bytes: [UInt8], to name: String, from requester: Owner) -> (FanControlHelperErrorCode, String) {
        guard let key = SMCKey(name) else { return (.invalidKey, "key must be exactly 4 ASCII characters") }
        guard FanControlHelperConstants.isWriteAllowed(key: name) else {
            return (.keyNotAllowed, "key '\(name)' is not in the write allowlist")
        }
        guard (1...32).contains(bytes.count) else { return (.badRequest, "payload must be 1...32 bytes") }
        return session.withLock { state in
            guard let current = state.owner else { return (.sessionNotOpen, "no session is open") }
            guard current == requester else { return (.notSessionOwner, "session is owned by pid \(current.pid)") }
            let result = performWrite(bytes, to: key, state: &state)
            if result.0 == .ok { state.lastWritten[key] = bytes }
            return result
        }
    }

    private func performWrite(_ bytes: [UInt8], to key: SMCKey, state: inout Session) -> (FanControlHelperErrorCode, String) {
        guard let info = try? smc.keyInfo(key) else { return (.invalidKey, "key '\(key.name)' does not exist") }
        if let rejection = HelperWritePolicy.validate(bytes, for: key, info: info, fanLimits: state.fanLimits) {
            return (rejection.code, rejection.message)
        }
        if !state.originals.contains(where: { $0.key == key }) {
            guard let original = try? smc.readBytes(key) else { return (.smcError, "cannot snapshot '\(key.name)'") }
            state.originals.append((key, original))
        }
        do {
            try smc.writeBytes(bytes, to: key)
        } catch {
            return (.smcError, "write to '\(key.name)' failed: \(error)")
        }
        return (.ok, "ok")
    }

    fileprivate func close(for requester: Owner) -> (FanControlHelperErrorCode, String) {
        session.withLock { state in
            guard let current = state.owner else { return (.sessionNotOpen, "no session is open") }
            guard current == requester else { return (.notSessionOwner, "session is owned by pid \(current.pid)") }
            endSession(&state)
            return (.ok, "session closed")
        }
    }

    private func release(_ owner: Owner) {
        session.withLock { state in
            guard state.owner == owner else { return }
            state.released.append(owner)
            endSession(&state)
        }
    }

    /// SIGTERM path (`SessionRegistry.shutdown()`).
    func shutdown() {
        session.withLock { state in
            guard state.owner != nil else { return }
            endSession(&state)
        }
    }

    private func endSession(_ state: inout Session) {
        let smc = self.smc
        let performed = HelperWritePolicy.restore(
            originals: state.originals, fanLimits: state.fanLimits,
            keyInfo: { try? smc.keyInfo($0) },
            write: { try smc.writeBytes($1, to: $0) })
        if !state.originals.isEmpty { state.restores.append(performed) }
        state.owner = nil
        state.originals = []
        state.lastWritten = [:]
        state.fanCount = nil
        state.fanLimits = [:]
    }

    // MARK: Sleep / wake (PowerObserver → SessionRegistry)

    func prepareForSleep() {
        session.withLock { state in
            guard state.owner != nil else { return }
            let writes = PowerTransitionPolicy.sleepHandBack(remembered: remembered(state),
                                                             snapshot: snapshot(state))
            for write in writes { _ = performWrite(write.bytes, to: write.key, state: &state) }
        }
    }

    func recoverAfterWake() {
        session.withLock { state in
            guard state.owner != nil else { return }
            let writes = PowerTransitionPolicy.wakeRecovery(remembered: remembered(state),
                                                            snapshot: snapshot(state))
            for write in writes { _ = performWrite(write.bytes, to: write.key, state: &state) }
        }
    }

    private func remembered(_ state: Session) -> [PowerTransitionPolicy.RememberedFan] {
        let smc = self.smc
        return PowerTransitionPolicy.rememberedFans(lastWritten: state.lastWritten, keyInfo: { try? smc.keyInfo($0) })
    }

    private func snapshot(_ state: Session) -> PowerTransitionPolicy.Snapshot {
        PowerTransitionPolicy.snapshot(using: smc, fanCount: state.fanCount ?? 0)
    }
}

/// Exported object for one connection (mirrors `HelperService`).
private final class FakeHelperService: NSObject, FanControlHelperProtocol, @unchecked Sendable {
    private weak var helper: FakeHelper?
    private let owner: FakeHelper.Owner
    /// Returns `true` if the connection was dropped instead of serving the message.
    private let drop: @Sendable () -> Bool

    init(helper: FakeHelper, owner: FakeHelper.Owner, drop: @escaping @Sendable () -> Bool) {
        self.helper = helper
        self.owner = owner
        self.drop = drop
    }

    /// Common prologue: counts the message; `false` if it must not be answered.
    private func admit(_ method: String) -> Bool {
        guard let helper else { return false }
        helper.noteMessage()
        if drop() { return false }
        return !helper.isHanging(method)
    }

    func version(reply: @escaping (Int, String) -> Void) {
        guard admit("version"), let helper else { return }
        reply(helper.reportedVersion, "fake")
    }

    func openSession(reply: @escaping (Int, String) -> Void) {
        guard admit("openSession"), let helper else { return }
        let (code, message) = helper.open(for: owner)
        reply(code.rawValue, message)
    }

    func writeKey(_ key: String, bytes: Data, reply: @escaping (Int, String) -> Void) {
        guard admit("writeKey"), let helper else { return }
        let (code, message) = helper.write([UInt8](bytes), to: key, from: owner)
        reply(code.rawValue, message)
    }

    func closeSession(reply: @escaping (Int, String) -> Void) {
        guard admit("closeSession"), let helper else { return }
        let (code, message) = helper.close(for: owner)
        reply(code.rawValue, message)
    }

    func readKeyInfo(_ key: String, reply: @escaping (Int, Int, UInt32, UInt8, String) -> Void) {
        guard admit("readKeyInfo"), let helper else { return }
        guard let smcKey = SMCKey(key), let info = try? helper.smc.keyInfo(smcKey) else {
            reply(FanControlHelperErrorCode.invalidKey.rawValue, 0, 0, 0, "no such key")
            return
        }
        reply(FanControlHelperErrorCode.ok.rawValue, info.dataSize, SMCKey(info.dataType.name)?.code ?? 0, info.attributes, "ok")
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Polls `condition` until it holds or `timeout` elapses (XPC callbacks are asynchronous).
func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
#endif
