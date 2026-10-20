/// Connection state of `HelperClient` (mirrored by `FanControlManager.helperConnectionState`).
public enum HelperConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    /// The last call failed (transient: timeout, helper not running, interrupted).
    /// Further calls back off exponentially (`HelperConnectionGate`).
    case error(String)
    /// The helper does not accept this app (code-signing requirement mismatch in
    /// either direction). Sticky: no connection is attempted until
    /// `HelperClient.resetRejection()` (user action), a relaunch, or a change of
    /// the installed files (re-running `install.sh`).
    case rejected(reason: HelperRejectionReason)
}

#if os(macOS)
import Foundation
import Synchronization
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
/// - The client never connects on its own: only a call (`version`, `openSession`,
///   `write`, `closeSession`, `keyInfo`) does, and the manager issues those only for
///   user actions or for an already open session (docs/kit.md "Helper connection lifecycle").
/// - Retry policy (`HelperConnectionGate`): before connecting, each call is admitted
///   by the gate. In manual mode the LaunchDaemon plist's pinned client cdhash is
///   compared with this app's first; a mismatch is a rejection
///   (`.clientNotPinned`) without any connection. At runtime, an
///   `NSXPCConnectionCodeSigningRequirementFailure` (helper signature) or two
///   consecutive interruptions before any reply (the helper dropping us after the
///   first message) are rejections too. A rejection sets `.rejected(reason:)` and
///   makes every later call throw `.helperConnectionRejected` immediately. Other
///   failures back off exponentially (2 s, 4 s, … capped at 5 min).
///
/// All mutable state is guarded by `lock`; `onStateChange` is invoked outside
/// the lock on an arbitrary thread.
///
/// `@unchecked Sendable` (justified): every stored `var` is read and written only
/// with `lock` held. The state cannot move into a `Mutex` because it includes the
/// non-`Sendable` `NSXPCConnection`, which `ensureConnection` hands out of the
/// critical section (a `Mutex` only returns `sending` values); `NSXPCConnection`
/// itself is documented as safe to use from any thread.
public final class HelperClient: SMCWriter, @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Bumped for every new connection so handlers of an old one are ignored.
    private var generation: UInt64 = 0
    private var sessionOpen = false
    private var state: HelperConnectionState = .disconnected
    private var stateHandler: (@Sendable (HelperConnectionState) -> Void)?
    private var teamID: String = FanControlHelperConstants.teamIdentifierPlaceholder
    private var timeout: TimeInterval = 8

    private let machServiceName: String
    /// `true` while the current connection uses the manual-mode (cdhash) requirement.
    private var manualMode = false
    /// Retry / rejection policy (see the type documentation).
    private var gate = HelperConnectionGate()
    /// The helper has replied on the current peer connection (reset when the
    /// connection is created or interrupted). Distinguishes "dropped right after the
    /// first message" (requirement failure on the helper side) from a crash.
    private var peerReplied = false

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

    // MARK: Retry gate

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Identity of the installation the next connection would talk to (cheap file
    /// attributes; call without `lock`). A sticky rejection is dropped when it changes.
    private func installFingerprint() -> String {
        switch Self.currentRequirementMode() {
        case .manualCDHash: return "manual|" + ManualHelperSigning.installFingerprint()
        case .teamID: return "team|" + clientTeamID
        }
    }

    /// The current sticky rejection, if any.
    public var rejection: HelperRejectionReason? {
        lock.withLock { gate.rejection }
    }

    /// Forgets a rejection and the transient backoff (user action: "Check Again",
    /// or after re-running `install.sh`). Does not connect.
    public func resetRejection() {
        let wasRejected: Bool = lock.withLock {
            let rejected = gate.rejection != nil
            gate.reset()
            return rejected
        }
        if wasRejected { updateState(.disconnected) }
    }

    /// Throws without connecting if the gate refuses the call.
    private func admit(fingerprint: String) throws {
        let decision = lock.withLock { gate.decide(now: Self.now(), fingerprint: fingerprint) }
        switch decision {
        case .proceed:
            return
        case .rejected(let reason):
            updateState(.rejected(reason: reason))
            throw FanControlError.helperConnectionRejected(reason.description)
        case .backingOff(let remaining):
            throw FanControlError.helperConnectionFailed(
                "not retrying for another \(Int(remaining.rounded(.up))) s after repeated failures (Check Again retries now)")
        }
    }

    /// Records a rejection, drops the connection and publishes `.rejected`.
    private func reject(_ reason: HelperRejectionReason, fingerprint: String) -> FanControlError {
        lock.withLock { gate.recordRejection(reason, fingerprint: fingerprint) }
        kitLog.error("Helper connection rejected, not retrying automatically: \(reason.description, privacy: .public)")
        dropConnection()
        updateState(.rejected(reason: reason))
        return FanControlError.helperConnectionRejected(reason.description)
    }

    // MARK: State

    /// Current connection state (thread-safe).
    public private(set) var connectionState: HelperConnectionState {
        get { lock.withLock { state } }
        set { updateState(newValue) }
    }

    /// Called (on an arbitrary thread) whenever `connectionState` changes.
    public var onStateChange: (@Sendable (HelperConnectionState) -> Void)? {
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
        let handler: (@Sendable (HelperConnectionState) -> Void)?
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

    private func ensureConnection(fingerprint: String) throws -> (connection: NSXPCConnection, manual: Bool) {
        lock.lock()
        if let connection {
            let manual = manualMode
            lock.unlock()
            return (connection, manual)
        }
        let currentTeamID = teamID
        lock.unlock()

        // Manual mode: if the plist pins another build of the app, the helper would
        // refuse us; report it without connecting at all.
        if Self.currentRequirementMode() == .manualCDHash,
           case .mismatch(let pinned, let app) = ManualHelperSigning.clientPinCheck() {
            throw reject(.clientNotPinned(pinnedCDHash: pinned, appCDHash: app), fingerprint: fingerprint)
        }

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
        peerReplied = false
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
        peerReplied = false
        if invalidated { connection = nil }
        let rejection = gate.rejection
        lock.unlock()
        if let rejection {
            // The drop that caused (or followed) a rejection must not hide it.
            updateState(.rejected(reason: rejection))
            return
        }
        updateState(invalidated ? .disconnected : .error("The connection to the fan control helper was interrupted."))
    }

    /// Invalidates the connection without publishing a state.
    private func dropConnection() {
        lock.lock()
        let old = connection
        connection = nil
        sessionOpen = false
        peerReplied = false
        generation &+= 1
        lock.unlock()
        old?.invalidate()
    }

    /// Tears the connection down. The helper releases the session (restoring
    /// original SMC values) when the connection goes away. A sticky rejection
    /// stays published (`.rejected`), otherwise the state becomes `.disconnected`.
    public func invalidate() {
        dropConnection()
        updateState(rejection.map { .rejected(reason: $0) } ?? .disconnected)
    }

    /// Sends one request. `body` receives the proxy and must eventually
    /// resume the box exactly once (extra resumes are ignored). Races the reply
    /// against `callTimeout`; on timeout the connection is invalidated.
    private func call<T>(_ body: @escaping (FanControlHelperProtocol, ResumeOnce<T>) -> Void) async throws -> T {
        let fingerprint = installFingerprint()
        try admit(fingerprint: fingerprint)
        let (connection, manual) = try ensureConnection(fingerprint: fingerprint)
        let hadReplyBeforeSend = lock.withLock { peerReplied }
        let timeout = callTimeout
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                let box = ResumeOnce(continuation)
                if timeout > 0 {
                    let nanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        guard !Task.isCancelled else { return }
                        if box.resume(throwing: HelperTransportError(reason: "timeout", failure: .transient)) {
                            // Hung helper or lost reply: start over with a fresh
                            // connection (the helper then releases the session).
                            self?.invalidate()
                        }
                    }
                    // Cancelled as soon as the box is resumed by anyone.
                    box.onResume { timeoutTask.cancel() }
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    let nsError = error as NSError
                    let failure = HelperConnectionGate.classify(errorDomain: nsError.domain, errorCode: nsError.code,
                                                                hadReplyBeforeSend: hadReplyBeforeSend)
                    var reason = error.localizedDescription
                    if manual {
                        // Most likely cause in manual mode: the app was rebuilt, so the
                        // helper's pinned client cdhash no longer matches.
                        reason += " (manual helper install: if the app was rebuilt or replaced, re-run sudo \(FanControlHelperConstants.manualInstallScriptName) <app> to pin its new cdhash)"
                    }
                    box.resume(throwing: HelperTransportError(reason: reason, failure: failure))
                }
                guard let helper = proxy as? FanControlHelperProtocol else {
                    box.resume(throwing: HelperTransportError(reason: "The helper proxy has an unexpected type.",
                                                              failure: .transient))
                    return
                }
                body(helper, box)
            }
            lock.withLock {
                gate.recordSuccess()
                peerReplied = true
            }
            updateState(.connected)
            return value
        } catch let transport as HelperTransportError {
            let rejection = lock.withLock {
                gate.recordFailure(transport.failure, now: Self.now(), fingerprint: fingerprint)
            }
            if let rejection {
                throw reject(rejection, fingerprint: fingerprint)
            }
            updateState(.error(transport.reason))
            throw FanControlError.helperConnectionFailed(transport.reason)
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

/// Transport-level failure of one call, classified for `HelperConnectionGate`
/// (converted to `FanControlError` before leaving `HelperClient`).
private struct HelperTransportError: Error {
    var reason: String
    var failure: HelperCallFailure
}

/// Resumes a checked continuation at most once (XPC may call both the reply
/// block and the error handler in edge cases, e.g. invalidation mid-reply, and
/// the call timeout races the reply).
final class ResumeOnce<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var resumeHandler: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = Mutex(State(continuation: continuation))
    }

    /// Runs `handler` once when the box is resumed (immediately if it already was).
    func onResume(_ handler: @escaping @Sendable () -> Void) {
        let alreadyResumed: Bool = state.withLock { state in
            guard state.continuation != nil else { return true }
            state.resumeHandler = handler
            return false
        }
        if alreadyResumed { handler() }
    }

    /// Takes the continuation (at most once) and runs the resume handler outside the lock.
    private func take() -> CheckedContinuation<T, Error>? {
        let (current, handler) = state.withLock { state in
            defer { state = State() }
            return (state.continuation, state.resumeHandler)
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
