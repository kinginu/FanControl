#if os(macOS)
import Foundation
import FanControlCore
import FanControlSMC
import FanControlXPC

/// Identity of a client connection. The session belongs to the XPC connection that
/// opened it; the pid is kept for liveness checks and logging.
struct SessionOwner: Equatable, Sendable {
    let pid: pid_t
    let connectionID: UInt64
}

/// Result of a registry operation, mapped 1:1 onto XPC replies.
struct HelperResult {
    var code: FanControlHelperErrorCode
    var message: String

    static func ok(_ message: String = "ok") -> HelperResult { HelperResult(code: .ok, message: message) }
}

/// Single-owner SMC write session (design doc §5.3).
///
/// - Only one connection may own the session at a time; others get `notSessionOwner`.
/// - A session whose owner process no longer exists is reclaimed automatically.
/// - The SMC connection is held only while a session is open.
/// - The original bytes of every key written during the session are recorded before
///   the first write (a write is refused if that snapshot cannot be taken). When the
///   session closes or the owner disappears, `HelperWritePolicy.restore` hands the fans
///   back to the SMC: mode keys first (`F<n>Md` = 0, `FS! ` = snapshot with this
///   session's bits cleared), and `F<n>Tg` is written back (clamped into `Mn...Mx`)
///   only for fans without a mode key. The Apple Silicon idle snapshot `Tg` = 0 is
///   therefore never written while `F<n>Md` = 1 (pre-write review 2026-10-20).
/// - Written values are validated by `HelperWritePolicy.validate` (the helper is the
///   safety authority), including the key's write attribute (`0x40`).
/// - Sleep/wake (`PowerObserver` → `prepareForSleep` / `recoverAfterWake`): before
///   sleep the fans the session forces are handed back to the SMC; after wake the
///   client's last writes (`lastWritten`) are re-applied and any other fan left in
///   manual mode is handed back (`PowerTransitionPolicy`, first-write test 4).
public final class SessionRegistry: @unchecked Sendable {
    public static let shared = SessionRegistry()

    private let lock = NSLock()
    private var owner: SessionOwner?
    private var openedAt: Date?
    private var client: SMCClient?
    /// Original values captured before the first write of each key in this session, in write order.
    private var originals: [(key: SMCKey, bytes: [UInt8])] = []
    /// `FNum` read at session open (`nil` if unreadable).
    private var fanCount: Int?
    /// Hardware `F<n>Mn...F<n>Mx` per fan, read at session open (before any write can
    /// change `F<n>Mn`). Fans missing here cannot have speed keys written.
    private var fanLimits: [Int: ClosedRange<Double>] = [:]
    /// `FS! ` bits this session has set; cleared from the snapshot on restore.
    private var touchedForceBits: UInt64 = 0
    /// The client's last successful write per key (its intent), re-applied on wake.
    /// The helper's own sleep/wake writes are not recorded here.
    private var lastWritten: [SMCKey: [UInt8]] = [:]

    private init() {}

    func open(for requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        if let current = owner {
            if current == requester {
                return .ok("session already open")
            }
            if current.pid == requester.pid {
                // Same process on a new connection (e.g. after a client-side timeout
                // invalidated the old one before its invalidation reached us): the old
                // connection is dead to the client, so hand its fans back and start over.
                helperLog.notice("Reclaiming session of pid \(current.pid, privacy: .public) from stale connection \(current.connectionID, privacy: .public)")
                endSessionLocked()
            } else if Self.isProcessAlive(current.pid) {
                return HelperResult(code: .notSessionOwner,
                                    message: "session is owned by pid \(current.pid) since \(openedAt.map { "\($0)" } ?? "?")")
            } else {
                helperLog.notice("Reclaiming session from dead pid \(current.pid, privacy: .public)")
                endSessionLocked()
            }
        }

        let newClient: SMCClient
        do {
            newClient = try SMCClient()
        } catch {
            return HelperResult(code: .smcUnavailable, message: "cannot open AppleSMC: \(error)")
        }
        owner = requester
        openedAt = Date()
        client = newClient
        originals = []
        touchedForceBits = 0
        lastWritten = [:]
        readHardwareLimitsLocked(using: newClient)
        helperLog.info("Session opened by pid \(requester.pid, privacy: .public) (connection \(requester.connectionID, privacy: .public))")
        return .ok("session opened")
    }

    /// Writes `bytes` to `key`. Caller has already validated the key against the allowlist
    /// and the byte count against 1...32.
    func write(_ bytes: [UInt8], to key: SMCKey, from requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        guard let current = owner, let client else {
            return HelperResult(code: .sessionNotOpen, message: "no session is open")
        }
        guard current == requester else {
            return HelperResult(code: .notSessionOwner, message: "session is owned by pid \(current.pid)")
        }
        let result = performWriteLocked(bytes, to: key, using: client)
        if result.code == .ok { lastWritten[key] = bytes }
        return result
    }

    /// Validated write (allowlist already checked by the caller or by construction):
    /// `HelperWritePolicy.validate`, original-value snapshot, `FS! ` bookkeeping, write.
    private func performWriteLocked(_ bytes: [UInt8], to key: SMCKey, using client: SMCClient) -> HelperResult {
        let info: SMCKeyInfo
        do {
            info = try client.keyInfo(key)
        } catch FanControlError.keyNotFound {
            return HelperResult(code: .invalidKey, message: "key '\(key.name)' does not exist on this SMC")
        } catch {
            return HelperResult(code: .smcError, message: "key info for '\(key.name)' failed: \(error)")
        }
        if let rejection = HelperWritePolicy.validate(bytes, for: key, info: info,
                                                      fanCount: fanCount, fanLimits: fanLimits) {
            return HelperResult(code: rejection.code, message: rejection.message)
        }

        if !originals.contains(where: { $0.key == key }) {
            // Without a snapshot the key could not be restored on close: refuse the write.
            let original: [UInt8]
            do {
                original = try client.readBytes(key)
            } catch {
                return HelperResult(code: .smcError,
                                    message: "cannot snapshot original value of '\(key.name)': \(error); write refused")
            }
            guard original.count == info.dataSize else {
                return HelperResult(code: .smcError,
                                    message: "snapshot of '\(key.name)' has \(original.count) bytes, expected \(info.dataSize); write refused")
            }
            originals.append((key, original))
        }
        if key == .forceBits, let bits = HelperWritePolicy.forceBits(of: bytes, type: info.dataType) {
            // Recorded before the write: if the SMC applied it despite an error, restore still clears it.
            touchedForceBits |= bits
        }

        do {
            try client.writeBytes(bytes, to: key)
        } catch {
            return HelperResult(code: .smcError, message: "write to '\(key.name)' failed: \(error)")
        }
        return .ok()
    }

    func close(for requester: SessionOwner) -> HelperResult {
        lock.lock()
        defer { lock.unlock() }

        guard let current = owner else {
            return HelperResult(code: .sessionNotOpen, message: "no session is open")
        }
        guard current == requester else {
            return HelperResult(code: .notSessionOwner, message: "session is owned by pid \(current.pid)")
        }
        endSessionLocked()
        return .ok("session closed")
    }

    /// Ends any open session and restores fans (SIGTERM / helper shutdown).
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard owner != nil || client != nil else { return }
        helperLog.notice("Helper shutting down; ending session and restoring fans")
        endSessionLocked()
    }

    /// Called when a connection is invalidated/interrupted. No-op unless `owner` holds the session.
    func release(owner released: SessionOwner) {
        lock.lock()
        defer { lock.unlock() }
        guard owner == released else { return }
        helperLog.notice("Owner pid \(released.pid, privacy: .public) went away; releasing session")
        endSessionLocked()
    }

    /// Key info lookup; uses the session's SMC connection if open, else a temporary one.
    func keyInfo(_ key: SMCKey) -> Result<SMCKeyInfo, FanControlError> {
        lock.lock()
        defer { lock.unlock() }
        do {
            let reader = try client ?? SMCClient()
            defer { if reader !== client { reader.close() } }
            return .success(try reader.keyInfo(key))
        } catch let error as FanControlError {
            return .failure(error)
        } catch {
            return .failure(.smcUnavailable)
        }
    }

    // MARK: Sleep / wake (called by PowerObserver on its queue)

    /// `kIOMessageSystemWillSleep`: hands every fan the session forces back to the
    /// SMC (`PowerTransitionPolicy.sleepHandBack`). Keeps the session and the client's
    /// intent for `recoverAfterWake`. Returns quickly; failures are only logged.
    func prepareForSleep() {
        lock.lock()
        defer { lock.unlock() }
        guard let owner, let client else {
            helperLog.notice("Power: system will sleep; no session open, nothing to hand back")
            return
        }
        let remembered = rememberedFansLocked(using: client)
        let snapshot = PowerTransitionPolicy.snapshot(using: client, fanCount: fanCount ?? 0)
        let writes = PowerTransitionPolicy.sleepHandBack(remembered: remembered, snapshot: snapshot)
        let done = performPowerWritesLocked(writes, using: client)
        helperLog.notice("Power: system will sleep; session of pid \(owner.pid, privacy: .public) open, handed back to the SMC: \(done, privacy: .public); remembered targets: \(self.describe(remembered, using: client), privacy: .public)")
    }

    /// `kIOMessageSystemHasPoweredOn`, attempt `attempt` of `total`
    /// (`PowerTransitionPolicy.wakeRetryDelays`). With a session: re-applies the
    /// remembered targets and hands back any other manual fan
    /// (`PowerTransitionPolicy.wakeRecovery`). Without one: only logs a warning if a
    /// fan is in manual mode (another tool may own it; nothing is written).
    func recoverAfterWake(attempt: Int, of total: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let owner, let client else {
            guard attempt == 1 else { return }
            guard let reader = try? SMCClient() else {
                helperLog.error("Power: wake check without session: cannot open AppleSMC")
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
            return
        }
        let remembered = rememberedFansLocked(using: client)
        let snapshot = PowerTransitionPolicy.snapshot(using: client, fanCount: fanCount ?? 0)
        let writes = PowerTransitionPolicy.wakeRecovery(remembered: remembered, snapshot: snapshot)
        let observed = snapshot.fans.map { state in
            "F\(state.fan) Md=\(state.modeBytes.map { $0.map(String.init).joined() } ?? "-") Tg=\(state.targetRPM.map { String(Int($0.rounded())) } ?? "-")"
        }.joined(separator: ", ")
        if writes.isEmpty {
            helperLog.notice("Power: wake recovery \(attempt, privacy: .public)/\(total, privacy: .public) (session of pid \(owner.pid, privacy: .public)): fans already match (\(observed, privacy: .public))")
            return
        }
        let done = performPowerWritesLocked(writes, using: client)
        helperLog.notice("Power: wake recovery \(attempt, privacy: .public)/\(total, privacy: .public) (session of pid \(owner.pid, privacy: .public)): observed \(observed, privacy: .public); wrote \(done, privacy: .public)")
    }

    // MARK: Private (lock held)

    private func rememberedFansLocked(using client: SMCClient) -> [PowerTransitionPolicy.RememberedFan] {
        PowerTransitionPolicy.rememberedFans(lastWritten: lastWritten, touchedForceBits: touchedForceBits,
                                             keyInfo: { try? client.keyInfo($0) })
    }

    /// Writes `writes` in order through the validated path (not recorded as client
    /// intent). A failed write does not stop the list. Returns a log summary.
    private func performPowerWritesLocked(_ writes: [PowerTransitionPolicy.Write], using client: SMCClient) -> String {
        guard !writes.isEmpty else { return "nothing" }
        return writes.map { write in
            let value = describeValue(write.bytes, key: write.key, using: client)
            guard FanControlHelperConstants.isWriteAllowed(key: write.key.name) else {
                return "\(write.key.name)=\(value) SKIPPED (not in the write allowlist)"
            }
            let result = performWriteLocked(write.bytes, to: write.key, using: client)
            return result.code == .ok
                ? "\(write.key.name)=\(value)"
                : "\(write.key.name)=\(value) FAILED (\(result.message))"
        }.joined(separator: ", ")
    }

    private func describe(_ remembered: [PowerTransitionPolicy.RememberedFan], using client: SMCClient) -> String {
        guard !remembered.isEmpty else { return "none" }
        return remembered.map { fan in
            "F\(fan.fan) \(fan.targetRPM.map { String(Int($0.rounded())) } ?? "-")"
        }.joined(separator: ", ")
    }

    private func describeValue(_ bytes: [UInt8], key: SMCKey, using client: SMCClient) -> String {
        if let info = try? client.keyInfo(key), let number = SMCCodec.decode(bytes, as: info.dataType)?.doubleValue,
           number.isFinite {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func endSessionLocked() {
        if let client {
            restoreOriginalsLocked(using: client)
            client.close()
        }
        if let owner, let openedAt {
            helperLog.info("Session of pid \(owner.pid, privacy: .public) closed after \(Int(Date().timeIntervalSince(openedAt)), privacy: .public)s")
        }
        owner = nil
        openedAt = nil
        client = nil
        originals = []
        touchedForceBits = 0
        lastWritten = [:]
        fanCount = nil
        fanLimits = [:]
    }

    /// Hands every fan touched in this session back to the SMC (`HelperWritePolicy.restore`).
    private func restoreOriginalsLocked(using client: SMCClient) {
        HelperWritePolicy.restore(
            originals: originals,
            touchedForceBits: touchedForceBits,
            fanLimits: fanLimits,
            keyInfo: { try? client.keyInfo($0) },
            write: { try client.writeBytes($1, to: $0) },
            log: { message in helperLog.error("\(message, privacy: .public)") })
    }

    /// Reads `FNum` and every fan's hardware `F<n>Mn` / `F<n>Mx` into the session cache.
    private func readHardwareLimitsLocked(using client: SMCClient) {
        fanCount = nil
        fanLimits = [:]
        guard let rawCount = try? client.readNumber(.fanCount), rawCount.isFinite, rawCount >= 0 else {
            helperLog.error("Cannot read FNum; FS! writes will be refused")
            return
        }
        let count = Int(min(rawCount, 10))
        fanCount = count
        for i in 0..<count {
            guard let lo = try? client.readNumber(.fanMin(i)), let hi = try? client.readNumber(.fanMax(i)),
                  lo.isFinite, hi.isFinite, lo <= hi else {
                helperLog.error("Cannot read hardware Mn/Mx of fan \(i, privacy: .public); its speed writes will be refused")
                continue
            }
            fanLimits[i] = lo...hi
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
#endif
