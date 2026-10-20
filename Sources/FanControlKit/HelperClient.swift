/// Connection state of `HelperClient` (mirrored by `FanControlManager.helperConnectionState`).
public enum HelperConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

/// Async client for FanControlHelper over a privileged Mach-service `NSXPCConnection`.
///
/// - The connection is created lazily on the first call and recreated after
///   invalidation (e.g. the daemon was not yet registered or was unregistered).
/// - Each call goes through `remoteObjectProxyWithErrorHandler`; a transport
///   error becomes `FanControlError.helperConnectionFailed`, a non-zero helper
///   return code becomes `FanControlError.helperRejected(code:message:)`.
/// - Interruption (helper crashed / restarted) and invalidation both drop the
///   session flag: the helper releases the session and restores the original
///   SMC values when its owner disappears, so a new `openSession()` is needed.
/// - Every call races against `callTimeout`: if the helper does not reply in
///   time the call throws `.helperConnectionFailed("timeout")` and the
///   connection is invalidated (which also ends the session, see above), so a
///   hung helper cannot block the `WriteSerializer` forever.
/// - Each new connection requires the helper's code signature to satisfy a
///   requirement (`NSXPCConnection.setCodeSigningRequirement`) chosen per connection
///   by `FanControlHelperConstants.helperRequirementMode(appTeamID:manualInstallDetected:)`:
///   - Team-ID mode (the app is signed with a Team ID and no manual installation
///     exists): `helperCodeSigningRequirement(teamID: clientTeamID)` — SMAppService path.
///   - Manual mode (the app is ad-hoc signed, or `install.sh` installed the helper):
///     `manualModeHelperRequirement(cdhash:)` with the cdhash of the root-owned
///     binary at `FanControlHelperConstants.manualHelperPath`, read at connect time
///     (`ManualHelperSigning.installedHelperCDHash`). If it cannot be read the call
///     throws `.helperConnectionFailed` without connecting.
///
/// All mutable state is guarded by `lock`; `onStateChange` is invoked outside
/// the lock on an arbitrary thread.
public final class HelperClient: SMCWriter, @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Bumped for every new connection so handlers of an old one are ignored.
    private var generation: UInt64 = 0
    private var sessionOpen = false
    private var state: HelperConnectionState = .disconnected
    private var stateHandler: ((HelperConnectionState) -> Void)?
    private var teamID: String = FanControlHelperConstants.teamIdentifierPlaceholder
    private var timeout: TimeInterval = 8

    private let machServiceName: String
    /// `true` while the current connection uses the manual-mode (cdhash) requirement.
    private var manualMode = false

    public init(machServiceName: String = FanControlHelperConstants.machServiceName) {
        self.machServiceName = machServiceName
    }

    /// Requirement mode for the next connection (manual if the app has no Team ID or
    /// the manual-install files exist).
    public static func currentRequirementMode() -> HelperRequirementMode {
        FanControlHelperConstants.helperRequirementMode(
            appTeamID: ManualHelperSigning.ownTeamIdentifier,
            manualInstallDetected: HelperInstaller().manualInstallState != .absent)
    }

    /// Builds the helper requirement for a new connection (file I/O in manual mode;
    /// call without `lock`).
    private static func makeHelperRequirement(teamID: String) throws -> (requirement: String, manual: Bool) {
        switch currentRequirementMode() {
        case .teamID:
            return (FanControlHelperConstants.helperCodeSigningRequirement(teamID: teamID), false)
        case .manualCDHash:
            let hash = try ManualHelperSigning.installedHelperCDHash()
            guard let requirement = FanControlHelperConstants.manualModeHelperRequirement(cdhash: hash) else {
                throw FanControlError.helperConnectionFailed("Invalid helper cdhash \(hash)")
            }
            return (requirement, true)
        }
    }

    deinit {
        connection?.invalidate()
    }

    // MARK: State

    /// Current connection state (thread-safe).
    public private(set) var connectionState: HelperConnectionState {
        get { lock.withLock { state } }
        set { updateState(newValue) }
    }

    /// Called (on an arbitrary thread) whenever `connectionState` changes.
    public var onStateChange: ((HelperConnectionState) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    /// Team ID the helper's code signature must carry. Takes effect for the next
    /// connection (set it before the first call). Defaults to
    /// `FanControlHelperConstants.teamIdentifierPlaceholder`.
    public var clientTeamID: String {
        get { lock.withLock { teamID } }
        set { lock.withLock { teamID = newValue } }
    }

    /// Seconds to wait for each helper reply (default 8). A value `<= 0`
    /// disables the timeout.
    public var callTimeout: TimeInterval {
        get { lock.withLock { timeout } }
        set { lock.withLock { timeout = newValue } }
    }

    /// Whether this client believes it owns the helper's write session.
    public var isSessionOpen: Bool {
        lock.withLock { sessionOpen }
    }

    private func updateState(_ newState: HelperConnectionState) {
        let handler: ((HelperConnectionState) -> Void)?
        lock.lock()
        if state == newState {
            lock.unlock()
            return
        }
        state = newState
        handler = stateHandler
        lock.unlock()
        handler?(newState)
    }

    // MARK: Connection

    private func ensureConnection() throws -> (connection: NSXPCConnection, manual: Bool) {
        lock.lock()
        if let connection {
            let manual = manualMode
            lock.unlock()
            return (connection, manual)
        }
        let currentTeamID = teamID
        lock.unlock()

        let helperRequirement: (requirement: String, manual: Bool)
        do {
            helperRequirement = try Self.makeHelperRequirement(teamID: currentTeamID)
        } catch let error as FanControlError {
            if case .helperConnectionFailed(let reason) = error { updateState(.error(reason)) }
            throw error
        }

        lock.lock()
        if let connection {
            // Another caller connected while the requirement was being computed.
            let manual = manualMode
            lock.unlock()
            return (connection, manual)
        }
        generation &+= 1
        let currentGeneration = generation
        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = makeHelperInterface()
        // Only talk to our own helper: signed by our team with the helper's identifier,
        // or (manual mode) exactly the binary root installed at manualHelperPath.
        newConnection.setCodeSigningRequirement(helperRequirement.requirement)
        manualMode = helperRequirement.manual
        newConnection.invalidationHandler = { [weak self] in
            self?.connectionEnded(generation: currentGeneration, invalidated: true)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.connectionEnded(generation: currentGeneration, invalidated: false)
        }
        connection = newConnection
        lock.unlock()

        updateState(.connecting)
        newConnection.resume()
        return (newConnection, helperRequirement.manual)
    }

    private func connectionEnded(generation ended: UInt64, invalidated: Bool) {
        lock.lock()
        guard ended == generation else {
            lock.unlock()
            return
        }
        sessionOpen = false
        if invalidated { connection = nil }
        lock.unlock()
        updateState(invalidated ? .disconnected : .error("The connection to the fan control helper was interrupted."))
    }

    /// Tears the connection down. The helper releases the session (restoring
    /// original SMC values) when the connection goes away.
    public func invalidate() {
        lock.lock()
        let old = connection
        connection = nil
        sessionOpen = false
        generation &+= 1
        lock.unlock()
        old?.invalidate()
        updateState(.disconnected)
    }

    /// Sends one request. `body` receives the proxy and must eventually
    /// resume the box exactly once (extra resumes are ignored). Races the reply
    /// against `callTimeout`; on timeout the connection is invalidated.
    private func call<T>(_ body: @escaping (FanControlHelperProtocol, ResumeOnce<T>) -> Void) async throws -> T {
        let (connection, manual) = try ensureConnection()
        let timeout = callTimeout
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                let box = ResumeOnce(continuation)
                if timeout > 0 {
                    let nanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        guard !Task.isCancelled else { return }
                        if box.resume(throwing: FanControlError.helperConnectionFailed("timeout")) {
                            // Hung helper or lost reply: start over with a fresh
                            // connection (the helper then releases the session).
                            self?.invalidate()
                        }
                    }
                    // Cancelled as soon as the box is resumed by anyone.
                    box.onResume { timeoutTask.cancel() }
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    var reason = error.localizedDescription
                    if manual {
                        // Most likely cause in manual mode: the app was rebuilt, so the
                        // helper's pinned client cdhash no longer matches.
                        reason += " (manual helper install: if the app was rebuilt or replaced, re-run sudo \(FanControlHelperConstants.manualInstallScriptName) <app> to pin its new cdhash)"
                    }
                    box.resume(throwing: FanControlError.helperConnectionFailed(reason))
                }
                guard let helper = proxy as? FanControlHelperProtocol else {
                    box.resume(throwing: FanControlError.helperConnectionFailed("The helper proxy has an unexpected type."))
                    return
                }
                body(helper, box)
            }
            updateState(.connected)
            return value
        } catch let error as FanControlError {
            if case .helperConnectionFailed(let reason) = error {
                updateState(.error(reason))
            }
            throw error
        }
    }

    /// Sends a request whose reply is `(rc, message)` and maps a non-zero rc to `.helperRejected`.
    private func callStatus(_ body: @escaping (FanControlHelperProtocol, @escaping (Int, String) -> Void) -> Void) async throws -> String {
        let (code, message): (Int, String) = try await call { helper, box in
            body(helper) { code, message in box.resume(returning: (code, message)) }
        }
        guard code == FanControlHelperErrorCode.ok.rawValue else {
            if code == FanControlHelperErrorCode.sessionNotOpen.rawValue
                || code == FanControlHelperErrorCode.notSessionOwner.rawValue {
                lock.withLock { sessionOpen = false }
            }
            throw FanControlError.helperRejected(code: code, message: message)
        }
        return message
    }

    // MARK: API

    /// Returns (`FanControlHelperConstants.protocolVersion` of the helper, build string).
    public func version() async throws -> (Int, String) {
        try await call { helper, box in
            helper.version { version, build in box.resume(returning: (version, build)) }
        }
    }

    /// Opens (or confirms) the exclusive write session.
    public func openSession() async throws {
        _ = try await callStatus { helper, reply in helper.openSession(reply: reply) }
        lock.withLock { sessionOpen = true }
    }

    /// Writes raw bytes to an allowlisted key. Throws `.sessionNotOpen` without
    /// contacting the helper if no session is open.
    public func write(key: SMCKey, bytes: [UInt8]) async throws {
        guard isSessionOpen else { throw FanControlError.sessionNotOpen }
        let data = Data(bytes)
        let name = key.name
        _ = try await callStatus { helper, reply in helper.writeKey(name, bytes: data, reply: reply) }
    }

    /// Closes the session (the helper restores the original values of every
    /// key written during it). Errors are ignored; the local flag is always cleared.
    public func closeSession() async {
        let wasOpen = isSessionOpen
        lock.withLock { sessionOpen = false }
        guard wasOpen else { return }
        _ = try? await callStatus { helper, reply in helper.closeSession(reply: reply) }
    }

    /// Key info as seen by the helper (root). Useful for diagnostics.
    public func keyInfo(_ key: SMCKey) async throws -> SMCKeyInfo {
        let name = key.name
        let (code, size, type, attributes, message): (Int, Int, UInt32, UInt8, String) = try await call { helper, box in
            helper.readKeyInfo(name) { code, size, type, attributes, message in
                box.resume(returning: (code, size, type, attributes, message))
            }
        }
        guard code == FanControlHelperErrorCode.ok.rawValue else {
            throw FanControlError.helperRejected(code: code, message: message)
        }
        return SMCKeyInfo(dataSize: size, dataType: SMCDataType(fourCC: type), attributes: attributes)
    }
}

/// Resumes a checked continuation at most once (XPC may call both the reply
/// block and the error handler in edge cases, e.g. invalidation mid-reply, and
/// the call timeout races the reply).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resumeHandler: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Runs `handler` once when the box is resumed (immediately if it already was).
    func onResume(_ handler: @escaping @Sendable () -> Void) {
        let alreadyResumed: Bool = lock.withLock {
            guard continuation != nil else { return true }
            resumeHandler = handler
            return false
        }
        if alreadyResumed { handler() }
    }

    private func take() -> CheckedContinuation<T, Error>? {
        let (current, handler) = lock.withLock { () -> (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) in
            let current = continuation
            let handler = resumeHandler
            continuation = nil
            resumeHandler = nil
            return (current, handler)
        }
        handler?()
        return current
    }

    /// Returns `true` if this call resumed the continuation.
    @discardableResult
    func resume(returning value: T) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(returning: value)
        return true
    }

    /// Returns `true` if this call resumed the continuation.
    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: error)
        return true
    }
}
#endif
