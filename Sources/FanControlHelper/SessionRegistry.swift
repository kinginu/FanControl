#if os(macOS)
import Foundation
import Synchronization
import FanControlCore
import FanControlSMC
import FanControlXPC

/// Identity of a client connection. The session belongs to the XPC connection that
/// opened it; the pid is kept for liveness checks and logging.
struct SessionOwner: Equatable, Sendable, CustomStringConvertible {
    let pid: pid_t
    let connectionID: UInt64

    var description: String { "pid \(pid) (connection \(connectionID))" }
}

/// Result of a registry operation, mapped 1:1 onto XPC replies.
struct HelperResult: Sendable {
    var code: FanControlHelperErrorCode
    var message: String

    static func ok(_ message: String = "ok") -> HelperResult { HelperResult(code: .ok, message: message) }
    static func failure(_ code: FanControlHelperErrorCode, _ message: String) -> HelperResult {
        HelperResult(code: code, message: message)
    }
}

/// What the restore at the end of a session did (`HelperWritePolicy.restore`).
struct RestoreReport: Sendable {
    var writes: [HelperWritePolicy.RestoreWrite]
    /// `F0Md=0, F1Md=0` (decoded while the SMC connection was still open), or `nothing`.
    var summary: String

    static let nothingToRestore = RestoreReport(writes: [], summary: "nothing")

    /// `true` when every key the restore attempted was written successfully at least
    /// once (a failed first try followed by a successful retry counts as success).
    var succeeded: Bool {
        let succeededKeys = Set(writes.filter(\.succeeded).map(\.key))
        return writes.allSatisfy { succeededKeys.contains($0.key) }
    }

    /// Keys whose restore never succeeded.
    var failedKeys: [SMCKey] {
        let succeededKeys = Set(writes.filter(\.succeeded).map(\.key))
        var seen = Set<SMCKey>()
        return writes.compactMap { write in
            guard !succeededKeys.contains(write.key), seen.insert(write.key).inserted else { return nil }
            return write.key
        }
    }
}

/// Single-owner SMC write session. The process-wide entry point;
/// all state lives in `SessionState` behind one mutex.
///
/// Lifecycle (`SessionPhase`):
///
///     idle ──open──▶ open(WriteSession) ──close / release / reclaim / watchdog──▶ idle
///       │                     │
///       └─────shutdown────────┴──shutdown (restore first)──▶ terminated (final)
///
/// - Only one connection may own the session at a time; others get `notSessionOwner`.
///   A session whose owner process no longer exists is reclaimed by the next
///   `openSession`, and the owner-liveness watchdog ends it on its own within
///   `ownerLivenessInterval` (a backstop for a missed connection invalidation).
/// - The SMC connection is held only while a session is open.
/// - The original bytes of every key written during the session are recorded before
///   the first write (a write is refused if that snapshot cannot be taken). Every way
///   out of `open` (close, connection invalidation, reclaim, watchdog, SIGTERM/SIGINT)
///   runs the same restore exactly once (`WriteSession.finish()`):
///   `HelperWritePolicy.restore` hands the fans back to the SMC — mode keys first
///   (`F<n>Md` = 0), and `F<n>Tg` is written back (clamped into `Mn...Mx`) only for
///   fans whose `F<n>Md` was not written. The Apple Silicon idle snapshot `Tg` = 0 is
///   therefore never written while `F<n>Md` = 1 (pre-write review 2026-10-20).
/// - `terminated` refuses new sessions, so nothing can be forced between the
///   shutdown restore and process exit.
/// - Written values are validated by `HelperWritePolicy.validate` (the helper is the
///   safety authority), including the key's write attribute (`0x40`).
/// - Sleep/wake (`PowerObserver` → `prepareForSleep` / `recoverAfterWake`): before
///   sleep the fans the session forces are handed back to the SMC; after wake the
///   client's last writes (`lastWritten`) are re-applied and any other fan left in
///   manual mode is handed back (`PowerTransitionPolicy`, first-write test 4).
///
/// Concurrency: every entry point holds the mutex for its whole duration (SMC I/O
/// included), so XPC calls from any connection queue, power notifications, the
/// watchdog and the signal handler are serialised. The SMC calls are a few IOKit
/// round trips each, so nothing waits long.
final class SessionRegistry: Sendable {
    static let shared = SessionRegistry()

    /// How often the watchdog checks that the session owner's process still exists.
    static let ownerLivenessInterval: DispatchTimeInterval = .seconds(5)

    private let state = Mutex(SessionState())
    private let watchdogQueue = DispatchQueue(label: FanControlHelperConstants.machServiceName + ".watchdog",
                                              qos: .utility)

    private init() {}

    func open(for requester: SessionOwner) -> HelperResult {
        state.withLock { state in
            state.open(for: requester, startWatchdog: { self.makeWatchdog() })
        }
    }

    /// Writes `bytes` to `key`. Caller has already validated the key against the allowlist
    /// and the byte count against 1...32.
    func write(_ bytes: [UInt8], to key: SMCKey, from requester: SessionOwner) -> HelperResult {
        state.withLock { $0.write(bytes, to: key, from: requester) }
    }

    func close(for requester: SessionOwner) -> HelperResult {
        state.withLock { $0.close(for: requester) }
    }

    /// Restores and ends any open session, then refuses new ones (SIGTERM / SIGINT).
    /// Idempotent: a second call returns `.nothingToRestore`.
    func shutdown() -> RestoreReport {
        state.withLock { $0.shutdown() }
    }

    /// Called when a connection is invalidated/interrupted. No-op unless `owner` holds the session.
    func release(owner released: SessionOwner) {
        state.withLock { $0.release(owner: released) }
    }

    /// Key info lookup; uses the session's SMC connection if open, else a temporary one.
    func keyInfo(_ key: SMCKey) -> Result<SMCKeyInfo, FanControlError> {
        state.withLock { $0.keyInfo(key) }
    }

    /// `kIOMessageSystemWillSleep` (see `WriteSession.prepareForSleep()`).
    func prepareForSleep() {
        state.withLock { $0.prepareForSleep() }
    }

    /// `kIOMessageSystemHasPoweredOn` (see `WriteSession.recoverAfterWake(attempt:of:)`).
    func recoverAfterWake(attempt: Int, of total: Int) {
        state.withLock { $0.recoverAfterWake(attempt: attempt, of: total) }
    }

    /// Watchdog tick: ends the session if its owner's process has exited.
    private func checkOwnerLiveness() {
        state.withLock { $0.checkOwnerLiveness() }
    }

    /// A repeating timer on `watchdogQueue` that calls `checkOwnerLiveness()`; started
    /// with the session, cancelled when it ends.
    private func makeWatchdog() -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        let interval = Self.ownerLivenessInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [self] in checkOwnerLiveness() }
        timer.resume()
        return timer
    }
}

// MARK: - State machine

/// The registry's states (see the diagram on `SessionRegistry`).
private enum SessionPhase {
    /// No session; `openSession` is accepted.
    case idle
    /// One connection owns the write session.
    case open(WriteSession)
    /// Shut down (SIGTERM / SIGINT): the last session has been restored and no new one
    /// is accepted. Final.
    case terminated
}

/// Why a session ended (log wording).
private enum SessionEndReason: String {
    case closedByClient = "closed by the client"
    case connectionEnded = "owner connection went away"
    case reclaimedStaleConnection = "reclaimed by a new connection of the same pid"
    case reclaimedDeadOwner = "reclaimed from a dead owner"
    case ownerProcessExited = "owner process exited (watchdog)"
    case helperShutdown = "helper shutting down"
}

/// The state behind `SessionRegistry` (only touched with its mutex held). Owns the
/// phase transitions; the per-session work is in `WriteSession`.
private struct SessionState {
    var phase: SessionPhase = .idle
    /// Owner-liveness timer; non-nil exactly while `phase` is `.open`.
    var watchdog: (any DispatchSourceTimer)?

    mutating func open(for requester: SessionOwner,
                       startWatchdog: () -> any DispatchSourceTimer) -> HelperResult {
        switch phase {
        case .terminated:
            return .failure(.smcUnavailable, "the helper is shutting down")
        case .idle:
            break
        case .open(let current):
            if current.owner == requester {
                return .ok("session already open")
            }
            if current.owner.pid == requester.pid {
                // Same process on a new connection (e.g. after a client-side timeout
                // invalidated the old one before its invalidation reached us): the old
                // connection is dead to the client, so hand its fans back and start over.
                helperLog.notice("Session: reclaiming session of pid \(current.owner.pid, privacy: .public) from stale connection \(current.owner.connectionID, privacy: .public)")
                endSession(.reclaimedStaleConnection)
            } else if SessionState.isProcessAlive(current.owner.pid) {
                helperLog.info("Session: open by \(requester.description, privacy: .public) refused; owned by \(current.owner.description, privacy: .public)")
                return .failure(.notSessionOwner, "session is owned by pid \(current.owner.pid) since \(current.openedAt)")
            } else {
                helperLog.notice("Session: reclaiming session from dead pid \(current.owner.pid, privacy: .public)")
                endSession(.reclaimedDeadOwner)
            }
        }

        let client: SMCClient
        do {
            client = try SMCClient()
        } catch {
            helperLog.error("Session: open by \(requester.description, privacy: .public) failed: cannot open AppleSMC: \(String(describing: error), privacy: .public)")
            return .failure(.smcUnavailable, "cannot open AppleSMC: \(error)")
        }
        phase = .open(WriteSession(owner: requester, client: client))
        watchdog = startWatchdog()
        helperLog.notice("Session: opened by \(requester.description, privacy: .public)")
        return .ok("session opened")
    }

    func write(_ bytes: [UInt8], to key: SMCKey, from requester: SessionOwner) -> HelperResult {
        switch ownedSession(by: requester) {
        case .success(let session): return session.clientWrite(bytes, to: key)
        case .failure(let refusal): return refusal.result
        }
    }

    mutating func close(for requester: SessionOwner) -> HelperResult {
        switch ownedSession(by: requester) {
        case .success:
            endSession(.closedByClient)
            return .ok("session closed")
        case .failure(let refusal):
            return refusal.result
        }
    }

    mutating func shutdown() -> RestoreReport {
        switch phase {
        case .terminated:
            return .nothingToRestore
        case .idle:
            phase = .terminated
            helperLog.notice("Shutdown: no session open")
            return .nothingToRestore
        case .open:
            helperLog.notice("Shutdown: ending the open session and restoring fans")
            return endSession(.helperShutdown, then: .terminated)
        }
    }

    mutating func release(owner released: SessionOwner) {
        guard case .open(let session) = phase, session.owner == released else { return }
        helperLog.notice("Session: owner pid \(released.pid, privacy: .public) went away; releasing session")
        endSession(.connectionEnded)
    }

    mutating func checkOwnerLiveness() {
        guard case .open(let session) = phase, !SessionState.isProcessAlive(session.owner.pid) else { return }
        helperLog.notice("Session: watchdog: owner pid \(session.owner.pid, privacy: .public) no longer exists; releasing session")
        endSession(.ownerProcessExited)
    }

    func keyInfo(_ key: SMCKey) -> Result<SMCKeyInfo, FanControlError> {
        if case .open(let session) = phase {
            return session.keyInfo(key)
        }
        do {
            let reader = try SMCClient()
            defer { reader.close() }
            return .success(try reader.keyInfo(key))
        } catch let error as FanControlError {
            return .failure(error)
        } catch {
            return .failure(.smcUnavailable)
        }
    }

    func prepareForSleep() {
        guard case .open(let session) = phase else {
            helperLog.notice("Power: system will sleep; no session open, nothing to hand back")
            return
        }
        session.prepareForSleep()
    }

    func recoverAfterWake(attempt: Int, of total: Int) {
        switch phase {
        case .open(let session):
            session.recoverAfterWake(attempt: attempt, of: total)
        case .idle:
            guard attempt == 1 else { return }
            SessionState.logManualFansWithoutSession()
        case .terminated:
            return
        }
    }

    // MARK: Private

    private struct Refusal: Error {
        var result: HelperResult
    }

    /// The open session if `requester` owns it, else the refusal to reply with.
    private func ownedSession(by requester: SessionOwner) -> Result<WriteSession, Refusal> {
        guard case .open(let session) = phase else {
            return .failure(Refusal(result: .failure(.sessionNotOpen, "no session is open")))
        }
        guard session.owner == requester else {
            return .failure(Refusal(result: .failure(.notSessionOwner, "session is owned by pid \(session.owner.pid)")))
        }
        return .success(session)
    }

    /// The only way out of `.open`: moves to `next` first, stops the watchdog, then
    /// restores and closes the session's SMC connection (`WriteSession.finish()`, which
    /// is itself idempotent). No-op (apart from the phase change) when no session is open.
    @discardableResult
    private mutating func endSession(_ reason: SessionEndReason, then next: SessionPhase = .idle) -> RestoreReport {
        guard case .open(let session) = phase else {
            phase = next
            return .nothingToRestore
        }
        phase = next
        watchdog?.cancel()
        watchdog = nil
        let report = session.finish()
        let duration = Int(Date().timeIntervalSince(session.openedAt))
        if report.succeeded {
            helperLog.notice("Session: \(session.owner.description, privacy: .public) ended after \(duration, privacy: .public)s (\(reason.rawValue, privacy: .public)); handed back: \(report.summary, privacy: .public)")
        } else {
            helperLog.fault("Session: \(session.owner.description, privacy: .public) ended after \(duration, privacy: .public)s (\(reason.rawValue, privacy: .public)); restore FAILED for \(report.failedKeys.map(\.name).joined(separator: ", "), privacy: .public) - the fan may stay forced until the SMC is reset")
        }
        return report
    }

    /// Wake without a session: only logs fans left in manual mode (another tool may own them).
    private static func logManualFansWithoutSession() {
        let reader: SMCClient
        do {
            reader = try SMCClient()
        } catch {
            helperLog.error("Power: wake check without session: cannot open AppleSMC: \(String(describing: error), privacy: .public)")
            return
        }
        defer { reader.close() }
        let count = (try? reader.readNumber(.fanCount)).map { Int(min(max($0.isFinite ? $0 : 0, 0), 10)) } ?? 0
        let manual = PowerTransitionPolicy.manualFans(PowerTransitionPolicy.snapshot(using: reader, fanCount: count))
        if manual.isEmpty {
            helperLog.notice("Power: system has powered on; no session open, no fan in manual mode")
        } else {
            helperLog.warning("Power: system has powered on; no session open but fan(s) \(manual.map(String.init).joined(separator: ","), privacy: .public) are in manual mode - not writing (another tool may own them)")
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Write session

/// One open write session: its owner, SMC connection, hardware limits, original-value
/// snapshots and the client's intent. Not `Sendable`: it is only reachable through
/// `SessionState`, i.e. with the registry's mutex held.
private final class WriteSession {
    let owner: SessionOwner
    let openedAt = Date()
    private let client: SMCClient
    /// Original values captured before the first write of each key in this session, in write order.
    private var originals: [(key: SMCKey, bytes: [UInt8])] = []
    /// `FNum` read at session open (`nil` if unreadable).
    private var fanCount: Int?
    /// Hardware `F<n>Mn...F<n>Mx` per fan, read at session open (`F<n>Mn` is
    /// read-only on Apple Silicon). Fans missing here cannot have targets written.
    private var fanLimits: [Int: ClosedRange<Double>] = [:]
    /// The client's last successful write per key (its intent), re-applied on wake.
    /// The helper's own sleep/wake writes are not recorded here.
    private var lastWritten: [SMCKey: [UInt8]] = [:]
    /// Set by `finish()`; later calls do nothing.
    private var isFinished = false

    init(owner: SessionOwner, client: SMCClient) {
        self.owner = owner
        self.client = client
        readHardwareLimits()
    }

    /// A client write (validated, snapshotted, then recorded as the client's intent).
    func clientWrite(_ bytes: [UInt8], to key: SMCKey) -> HelperResult {
        guard !isFinished else { return .failure(.sessionNotOpen, "no session is open") }
        let result = performWrite(bytes, to: key)
        if result.code == .ok { lastWritten[key] = bytes }
        return result
    }

    func keyInfo(_ key: SMCKey) -> Result<SMCKeyInfo, FanControlError> {
        do {
            return .success(try client.keyInfo(key))
        } catch let error as FanControlError {
            return .failure(error)
        } catch {
            return .failure(.smcUnavailable)
        }
    }

    /// Ends the session: hands every fan touched in it back to the SMC
    /// (`HelperWritePolicy.restore`) and closes the SMC connection. Idempotent.
    func finish() -> RestoreReport {
        guard !isFinished else { return .nothingToRestore }
        isFinished = true
        let writes = HelperWritePolicy.restore(
            originals: originals,
            fanLimits: fanLimits,
            keyInfo: { [client] in try? client.keyInfo($0) },
            write: { [client] in try client.writeBytes($1, to: $0) },
            log: { message in helperLog.error("Session: \(message, privacy: .public)") })
        let report = RestoreReport(writes: writes, summary: describe(writes))
        client.close()
        originals = []
        lastWritten = [:]
        return report
    }

    // MARK: Sleep / wake (called by PowerObserver on its queue)

    /// `kIOMessageSystemWillSleep`: hands every fan the session forces back to the
    /// SMC (`PowerTransitionPolicy.sleepHandBack`). Keeps the session and the client's
    /// intent for `recoverAfterWake`. Returns quickly; failures are only logged.
    func prepareForSleep() {
        let remembered = rememberedFans()
        let snapshot = PowerTransitionPolicy.snapshot(using: client, fanCount: fanCount ?? 0)
        let writes = PowerTransitionPolicy.sleepHandBack(remembered: remembered, snapshot: snapshot)
        let done = performPowerWrites(writes)
        let rememberedTargets = describe(remembered)
        helperLog.notice("Power: system will sleep; session of pid \(self.owner.pid, privacy: .public) open, handed back to the SMC: \(done, privacy: .public); remembered targets: \(rememberedTargets, privacy: .public)")
    }

    /// `kIOMessageSystemHasPoweredOn`, attempt `attempt` of `total`
    /// (`PowerTransitionPolicy.wakeRetryDelays`): re-applies the remembered targets and
    /// hands back any other manual fan (`PowerTransitionPolicy.wakeRecovery`).
    func recoverAfterWake(attempt: Int, of total: Int) {
        let remembered = rememberedFans()
        let snapshot = PowerTransitionPolicy.snapshot(using: client, fanCount: fanCount ?? 0)
        let writes = PowerTransitionPolicy.wakeRecovery(remembered: remembered, snapshot: snapshot)
        let observed = snapshot.fans.map { state in
            "F\(state.fan) Md=\(state.modeBytes.map { $0.map(String.init).joined() } ?? "-") Tg=\(state.targetRPM.map { String(Int($0.rounded())) } ?? "-")"
        }.joined(separator: ", ")
        if writes.isEmpty {
            helperLog.notice("Power: wake recovery \(attempt, privacy: .public)/\(total, privacy: .public) (session of pid \(self.owner.pid, privacy: .public)): fans already match (\(observed, privacy: .public))")
            return
        }
        let done = performPowerWrites(writes)
        helperLog.notice("Power: wake recovery \(attempt, privacy: .public)/\(total, privacy: .public) (session of pid \(self.owner.pid, privacy: .public)): observed \(observed, privacy: .public); wrote \(done, privacy: .public)")
    }

    // MARK: Private

    /// `F0Md=0, F1Md=0` (or `nothing`) for restore writes.
    private func describe(_ writes: [HelperWritePolicy.RestoreWrite]) -> String {
        guard !writes.isEmpty else { return "nothing" }
        return writes.map { write in
            "\(write.key.name)=\(describeValue(write.bytes, key: write.key))\(write.succeeded ? "" : " FAILED")"
        }.joined(separator: ", ")
    }

    /// Validated write (allowlist already checked by the caller or by construction):
    /// `HelperWritePolicy.validate`, original-value snapshot, write.
    private func performWrite(_ bytes: [UInt8], to key: SMCKey) -> HelperResult {
        let info: SMCKeyInfo
        do {
            info = try client.keyInfo(key)
        } catch FanControlError.keyNotFound {
            return .failure(.invalidKey, "key '\(key.name)' does not exist on this SMC")
        } catch {
            return .failure(.smcError, "key info for '\(key.name)' failed: \(error)")
        }
        if let rejection = HelperWritePolicy.validate(bytes, for: key, info: info, fanLimits: fanLimits) {
            return .failure(rejection.code, rejection.message)
        }

        if !originals.contains(where: { $0.key == key }) {
            // Without a snapshot the key could not be restored on close: refuse the write.
            let original: [UInt8]
            do {
                original = try client.readBytes(key)
            } catch {
                return .failure(.smcError, "cannot snapshot original value of '\(key.name)': \(error); write refused")
            }
            guard original.count == info.dataSize else {
                return .failure(.smcError, "snapshot of '\(key.name)' has \(original.count) bytes, expected \(info.dataSize); write refused")
            }
            originals.append((key, original))
        }
        do {
            try client.writeBytes(bytes, to: key)
        } catch {
            return .failure(.smcError, "write to '\(key.name)' failed: \(error)")
        }
        helperLog.debug("Session: wrote \(key.name, privacy: .public)=\(self.describeValue(bytes, key: key, info: info), privacy: .public)")
        return .ok()
    }

    private func rememberedFans() -> [PowerTransitionPolicy.RememberedFan] {
        PowerTransitionPolicy.rememberedFans(lastWritten: lastWritten,
                                             keyInfo: { [client] in try? client.keyInfo($0) })
    }

    /// Writes `writes` in order through the validated path (not recorded as client
    /// intent). A failed write does not stop the list. Returns a log summary.
    private func performPowerWrites(_ writes: [PowerTransitionPolicy.Write]) -> String {
        guard !writes.isEmpty else { return "nothing" }
        return writes.map { write in
            let value = describeValue(write.bytes, key: write.key)
            guard FanControlHelperConstants.isWriteAllowed(key: write.key.name) else {
                return "\(write.key.name)=\(value) SKIPPED (not in the write allowlist)"
            }
            let result = performWrite(write.bytes, to: write.key)
            return result.code == .ok
                ? "\(write.key.name)=\(value)"
                : "\(write.key.name)=\(value) FAILED (\(result.message))"
        }.joined(separator: ", ")
    }

    private func describe(_ remembered: [PowerTransitionPolicy.RememberedFan]) -> String {
        guard !remembered.isEmpty else { return "none" }
        return remembered.map { fan in
            "F\(fan.fan) \(fan.targetRPM.map { String(Int($0.rounded())) } ?? "-")"
        }.joined(separator: ", ")
    }

    /// The decoded number (`3000`, `0`) when the key's type is known, else hex bytes.
    private func describeValue(_ bytes: [UInt8], key: SMCKey, info: SMCKeyInfo? = nil) -> String {
        if let info = info ?? (try? client.keyInfo(key)),
           let number = SMCCodec.decode(bytes, as: info.dataType)?.doubleValue, number.isFinite {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `FNum` and every fan's hardware `F<n>Mn` / `F<n>Mx` into the session cache.
    private func readHardwareLimits() {
        fanCount = nil
        fanLimits = [:]
        guard let rawCount = try? client.readNumber(.fanCount), rawCount.isFinite, rawCount >= 0 else {
            helperLog.error("Session: cannot read FNum; target writes will be refused")
            return
        }
        let count = Int(min(rawCount, 10))
        fanCount = count
        for i in 0..<count {
            guard let lo = try? client.readNumber(.fanMin(i)), let hi = try? client.readNumber(.fanMax(i)),
                  lo.isFinite, hi.isFinite, lo <= hi else {
                helperLog.error("Session: cannot read hardware Mn/Mx of fan \(i, privacy: .public); its speed writes will be refused")
                continue
            }
            fanLimits[i] = lo...hi
        }
    }
}
#endif
