#if os(macOS)
import Foundation
import os
import FanControlCore
import FanControlSMC
import FanControlXPC

/// The poll-queue half of `FanControlManager` (docs/kit.md "Threading model").
///
/// An actor whose executor is the serial dispatch queue `queue` (QoS utility), so
/// the compiler checks that the SMC reader, the discovered fans, the alert latch,
/// the sample filter, the write strategy, the throttle baseline and the apply
/// generation are only touched on that queue. Two ways in, both FIFO with each other:
/// - `enqueue(_:)` (fire-and-forget, `queue.async`) from the main actor, for work
///   whose order relative to later work matters (monitoring flag, polls, sleep flag);
/// - `await run(_:)` for a result (the job is enqueued on `queue` when awaited).
///
/// Results are published to the main actor with `DispatchQueue.main.async`, in the
/// order they were produced.
actor FanControlPoller {
    /// The actor's executor. `exportSMCDump()` (sync) blocks on it with `queue.sync`.
    nonisolated let queue: DispatchSerialQueue
    nonisolated let helperClient: HelperClient
    /// Helper writes, strictly FIFO (a write list is never interleaved with another).
    nonisolated let serializer = WriteSerializer()
    /// Immutable, so it may be read from any isolation.
    nonisolated let aggregateDefinitions = FanControlPlatform.sensorAggregateDefinitions

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Receives the published state. Set by `attach(_:)`, enqueued by the manager's init.
    private weak var manager: FanControlManager?

    var reader: SMCClient?
    var strategy: FanWriteStrategy?
    var polledFans: [FanDevice] = []
    var sensorKeys: [String] = []
    var alertEvaluator = AlertEvaluator()
    /// Applied to every sensor batch before alerts, planning and publishing;
    /// reset whenever sensors are rediscovered.
    var sampleFilter = TemperatureSampleFilter()
    /// Asymmetric smoothing of the control temperatures (keys followed by the profile's
    /// `.sensor` modes), applied after the filter and the aggregates, before planning.
    var smoother = TemperatureSmoother()
    /// Deadband / dwell / slew limit on poll-planned targets. Seeded by user applies,
    /// reset when a session opens or closes.
    var stabilizer = FanTargetStabilizer()
    /// Last successfully written state per fan (throttle baseline).
    var appliedTargets: [Int: FanTarget] = [:]
    /// Fans whose SMC state is unknown after a failed write list (e.g. `F<i>Md`
    /// accepted, `F<i>Tg` rejected) and whose rollback did not succeed: the next
    /// planned state is written for them regardless of the throttle.
    var unsettledFans: Set<Int> = []
    var pollWriteInFlight = false
    /// Bumped by every user apply / restore / session close before it writes;
    /// poll batches planned at an older generation are dropped.
    var applyGate = ApplyGenerationGate()
    /// The queue's view of `isMonitoring` (set in order with the queued work),
    /// so queued polls do not reopen the reader after `stopMonitoring()`.
    var monitoringActive = false
    /// Between `NSWorkspace.willSleepNotification` and `didWakeNotification`:
    /// polls write nothing and do not flag unsettled fans (the helper has handed
    /// the forced fans back to the SMC for the sleep; a poll must not re-force them).
    /// Cleared on wake, or by a poll more than `sleepSuspendTimeout` after it was
    /// set (a missed wake notification must not disable poll writes, and with them
    /// the emergency override, for good).
    var systemSleeping = false
    var systemSleepStartedAt: Date?
    static let sleepSuspendTimeout: TimeInterval = 30

    init(helperClient: HelperClient,
         label: String = "com.example.dynamicnotch.DynamicNotch.fanfi.poll") {
        self.queue = DispatchSerialQueue(label: label, qos: .utility)
        self.helperClient = helperClient
    }

    // MARK: - Entry points

    /// Runs `body` on `queue` after everything enqueued before it (`queue.async`).
    nonisolated func enqueue(_ body: @escaping @Sendable (isolated FanControlPoller) -> Void) {
        queue.async {
            // `queue` is this actor's executor, so we are isolated here.
            self.assumeIsolated { body($0) }
        }
    }

    /// Runs `body` isolated to the poller (on `queue`) and returns its result.
    func run<T: Sendable>(_ body: @Sendable (isolated FanControlPoller) throws -> T) rethrows -> T {
        try body(self)
    }

    func attach(_ manager: FanControlManager) {
        self.manager = manager
    }

    // MARK: - Publishing

    /// Hands `update` to the main queue (FIFO with the other publications).
    private func publish(_ update: @escaping @MainActor @Sendable (FanControlManager) -> Void) {
        guard let manager else { return }
        DispatchQueue.main.async {
            update(manager)
        }
    }

    /// Publishes `error` to `lastError` only if it differs from the current
    /// value (a failing poll would otherwise re-publish it every tick).
    func publishError(_ error: FanControlError) {
        publish { manager in
            if manager.lastError != error { manager.lastError = error }
        }
    }

    // MARK: - Reader

    /// Opens the SMC and discovers sensors once; fan discovery is retried on
    /// every call while no fan is known (a failed or empty discovery, e.g. a
    /// transient `FNum` read error; on a fanless Mac this costs one `FNum` read per poll).
    func prepareReader() throws {
        if let reader {
            if polledFans.isEmpty { discoverFans(using: reader) }
            return
        }
        let client: SMCClient
        do {
            try FanControlPlatform.requireSupported()
            client = try SMCClient()
        } catch {
            publish { $0.isSMCConnected = false }
            throw error
        }
        let discovered = (try? SensorCatalog.discoverTemperatureSensors(using: client)) ?? []
        reader = client
        sensorKeys = discovered.map(\.id)
        alertEvaluator = AlertEvaluator()
        sampleFilter.reset()
        smoother.reset()
        let sensors = SensorAggregator.appendingAggregates(to: sampleFilter.filter(discovered),
                                                           definitions: aggregateDefinitions)
        let substituted = sampleFilter.substitutedKeys
        strategy = nil
        discoverFans(using: client)
        publish { manager in
            manager.isSMCConnected = true
            manager.sensorReadings = sensors
            manager.substitutedSensorKeys = substituted
        }
    }

    /// Re-reads `sensorKeys`, runs them through `sampleFilter` and appends the
    /// aggregates computed from the filtered values.
    func readFilteredTemperatures(using reader: SMCReader) -> [SensorReading] {
        SensorAggregator.appendingAggregates(
            to: sampleFilter.filter(SensorCatalog.readTemperatures(keys: sensorKeys, using: reader)),
            definitions: aggregateDefinitions)
    }

    /// Runs `FanDiscovery.discoverFans`; a failure is published to `lastError`
    /// and leaves `fans` empty (retried by later polls).
    private func discoverFans(using client: SMCClient) {
        let fans: [FanDevice]
        do {
            fans = try FanDiscovery.discoverFans(using: client)
        } catch {
            fans = []
            publishError(Self.fanControlError(from: error))
        }
        guard fans != polledFans || strategy == nil else { return }
        polledFans = fans
        strategy = FanWriteStrategy(reader: client, fans: fans)
        publish { $0.fans = fans }
    }

    func closeReader() {
        reader?.close()
        reader = nil
        strategy = nil
    }

    /// Fans after `prepareReader()`.
    func discoveredFans() throws -> [FanDevice] {
        try prepareReader()
        return polledFans
    }

    /// The SMC dump for `FanControlManager.exportSMCDump()`.
    func dump() -> String {
        let header = "# FanControlKit \(FanControlKitInfo.version) SMC dump, \(ISO8601DateFormatter().string(from: Date()))\n"
        if let reader { return header + reader.dump() }
        do {
            let client = try SMCClient()
            defer { client.close() }
            return header + client.dump()
        } catch {
            return header + "SMC dump failed: \(error)"
        }
    }

    // MARK: - Polling

    func poll(_ context: PollContext) {
        // Queued while monitoring, but monitoring has stopped since: drop it
        // rather than reopening the reader that `stopMonitoring()` closed.
        if context.requiresMonitoring && !monitoringActive { return }
        // Explicit refresh while not monitoring: open the SMC for this poll only.
        let oneShot = !monitoringActive && reader == nil && !context.sessionOpen
        do {
            try prepareReader()
        } catch {
            publishError(Self.fanControlError(from: error))
            return
        }
        defer { if oneShot { closeReader() } }
        guard let reader else { return }
        let fans = polledFans
        let current = FanDiscovery.readCurrentRPMs(fans: fans, using: reader)
        let targets = FanDiscovery.readTargetRPMs(fans: fans, using: reader)
        let sensors = readFilteredTemperatures(using: reader)
        let substituted = sampleFilter.substitutedKeys
        let highTemp = alertEvaluator.evaluateHighTemperature(sensors: sensors, policy: context.policy)
        // Evaluated every poll (session or not) so the latch's hysteresis state
        // is current when a session opens.
        let emergency = alertEvaluator.evaluateEmergency(sensors: sensors, policy: context.policy)
        let anomalies = alertEvaluator.evaluateFanAnomaly(fans: fans, currentRPMs: current, targetRPMs: targets)
        let now = Date()
        // Smoothed every poll (session or not) so the UI can show the control
        // temperature and the state is warm when a session opens.
        let controlSensors = smoother.smooth(
            sensors, keys: FanControlEngine.controlSensorKeys(profile: context.profile, fans: fans),
            at: now, tuning: context.tuning)
        let controlTemperatures = smoother.values

        if systemSleeping, let started = systemSleepStartedAt,
           Date().timeIntervalSince(started) > Self.sleepSuspendTimeout {
            systemSleeping = false
            systemSleepStartedAt = nil
        }
        let modes: [Int: FanControlMode]
        if context.sessionOpen {
            modes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, context.profile.mode(for: $0)) })
            let plan = FanControlEngine.plan(profile: context.profile, fans: fans, sensors: controlSensors,
                                             policy: context.policy, isEmergency: emergency)
            // The emergency override is never delayed (bypass).
            let stabilized = stabilizer.stabilize(plan, fans: fans, at: now, tuning: context.tuning,
                                                  bypass: emergency)
            let desired = Self.targets(from: stabilized)
            if !systemSleeping { flagUnsettledFans(fans: fans, targets: targets, using: reader) }
            if !systemSleeping, !pollWriteInFlight, !changedTargets(desired, force: false).isEmpty {
                pollWriteInFlight = true
                let generation = applyGate.current
                // Inherits this actor's isolation: back on `queue` after each await.
                Task {
                    do {
                        try await self.applyTargets(desired, force: false, pollGeneration: generation)
                    } catch {
                        self.publishError(Self.fanControlError(from: error))
                    }
                    self.pollWriteInFlight = false
                }
            }
        } else {
            modes = FanDiscovery.fanControlModes(fans: fans, using: reader)
        }

        publish { manager in
            manager.fans = fans
            manager.currentRPMs = current
            manager.targetRPMs = targets
            manager.sensorReadings = sensors
            manager.substitutedSensorKeys = substituted
            manager.controlTemperatures = controlTemperatures
            manager.recordTemperatureHistory(sensors, at: now)
            manager.fanControlModes = modes
            manager.highTempAlertActive = highTemp
            manager.emergencyOverrideActive = emergency
            manager.anomalousFanIDs = anomalies
            manager.isSMCConnected = true
            manager.lastUpdate = now
            NotificationCenter.default.post(name: .fanControlDidUpdate, object: manager)
        }
    }

    /// Session open. Compares the SMC state with `appliedTargets`
    /// (`UnsettledFanDetector`: manual at a target below `F<n>Mn`, manual control
    /// dropped, target reset, or forced although applied automatic) and adds such
    /// fans to `unsettledFans`, so this poll rewrites them regardless of the throttle.
    private func flagUnsettledFans(fans: [FanDevice], targets: [Int: Int], using reader: SMCReader) {
        guard let strategy, !fans.isEmpty else { return }
        let modes = FanDiscovery.fanControlModes(fans: fans, using: reader)
        var observed: [Int: UnsettledFanDetector.Observation] = [:]
        for fan in fans {
            observed[fan.id] = .init(isManual: modes[fan.id]?.isManual, targetRPM: targets[fan.id])
        }
        let found = UnsettledFanDetector.unsettledFans(fans: fans, controllable: Set(strategy.fans.keys),
                                                       applied: appliedTargets, observed: observed)
        let newly = found.subtracting(unsettledFans)
        guard !newly.isEmpty else { return }
        unsettledFans.formUnion(newly)
        let detail = newly.sorted().map { fan in
            "F\(fan) manual=\(observed[fan]?.isManual.map(String.init) ?? "?") Tg=\(observed[fan]?.targetRPM.map(String.init) ?? "?") applied=\(appliedTargets[fan].map { "\($0)" } ?? "none")"
        }.joined(separator: ", ")
        kitLog.notice("Unsettled fan(s) detected, rewriting: \(detail, privacy: .public)")
    }

    /// User apply / wake re-apply (on `queue`): reads fresh sensors, updates the
    /// emergency latch and the smoother, plans `profile` and seeds the stabilizer with
    /// the plan (explicit applies are not rate-limited). Bumps the apply generation first.
    func planApply(profile: FanProfile, policy: SafetyPolicy,
                   tuning: FanControlTuning) throws -> (fans: [FanDevice], plan: [Int: Int?], emergency: Bool) {
        // Polls enqueued before this point were snapshotted with the old
        // selection; their batches now carry a stale generation.
        applyGate.advance()
        try prepareReader()
        let sensors = reader.map { readFilteredTemperatures(using: $0) } ?? []
        // Same latch as the poll loop, so a user action cannot drop an
        // active emergency override inside the hysteresis band.
        let emergency = alertEvaluator.evaluateEmergency(sensors: sensors, policy: policy)
        let now = Date()
        let fans = polledFans
        let controlSensors = smoother.smooth(
            sensors, keys: FanControlEngine.controlSensorKeys(profile: profile, fans: fans), at: now, tuning: tuning)
        let plan = FanControlEngine.plan(profile: profile, fans: fans, sensors: controlSensors, policy: policy,
                                         isEmergency: emergency)
        stabilizer.seed(plan, fans: fans, at: now)
        return (fans, plan, emergency)
    }

    /// Forgets the write baseline, unsettled fans and the stabilizer (session opened / closed).
    func resetWriteState() {
        appliedTargets = [:]
        unsettledFans = []
        stabilizer.reset()
    }

    // MARK: - Writing

    /// Filters `desired` down to controllable fans whose state differs from
    /// `appliedTargets` by a mode change or more than `writeThresholdRPM`
    /// (always included: `force`, or the fan is unsettled).
    func changedTargets(_ desired: [Int: FanTarget], force: Bool) -> [Int: FanTarget] {
        // Fans without `F<n>Md` are passed through so `FanWriteStrategy.writes`
        // fails with `.fanModeKeyMissing` instead of silently skipping them.
        let controllable = Set((strategy?.fans ?? [:]).keys).union(strategy?.fansMissingModeKey ?? [])
        var result: [Int: FanTarget] = [:]
        for (fan, target) in desired where controllable.contains(fan) {
            if force || unsettledFans.contains(fan) {
                result[fan] = target
                continue
            }
            switch (target, appliedTargets[fan]) {
            case (.automatic, .some(.manual)):
                result[fan] = target
            case (.automatic, _):
                break // never forced by us (or already automatic): leave it alone
            case (.manual(let rpm), .some(.manual(let old))):
                if abs(rpm - old) > FanControlManager.writeThresholdRPM { result[fan] = target }
            case (.manual, _):
                result[fan] = target
            }
        }
        return result
    }

    /// Serialized: plans the write list on `queue` (dropping fans that did not
    /// change enough unless `force`), sends it to the helper, then records the
    /// applied state. A failed write leaves the baseline untouched so the next
    /// poll retries. `pollGeneration` is set only for poll-driven batches: such a
    /// batch is dropped (nothing written) if a user apply started after it was
    /// planned (`ApplyGenerationGate.isStale`). Never hops to the main actor
    /// (the termination restore blocks the main thread while it runs this).
    nonisolated func applyTargets(_ desired: [Int: FanTarget], force: Bool,
                                  pollGeneration: UInt64? = nil) async throws {
        let helperClient = self.helperClient
        try await serializer.run { [self] in
            let (writes, pending) = try await run { poller throws -> ([SMCWrite], [Int: FanTarget]) in
                if let pollGeneration, poller.applyGate.isStale(pollGeneration) { return ([], [:]) }
                try poller.prepareReader()
                guard let strategy = poller.strategy else { throw FanControlError.smcUnavailable }
                let pending = poller.changedTargets(desired, force: force)
                guard !pending.isEmpty else { return ([], [:]) }
                return (try strategy.writes(for: pending).map { SMCWrite(key: $0.0, bytes: $0.1) }, pending)
            }
            do {
                for write in writes {
                    try await helperClient.write(key: write.key, bytes: write.bytes)
                }
            } catch {
                await rollBackFailedWrites(pending)
                throw error
            }
            if !pending.isEmpty {
                await run { poller in
                    poller.appliedTargets.merge(pending) { _, new in new }
                    poller.unsettledFans.subtract(pending.keys)
                }
            }
        }
    }

    /// Inside `serializer.run` only. A write list failed part-way (e.g. the
    /// helper accepted `F<i>Md` = 1 and then rejected or timed out on `F<i>Tg`,
    /// leaving the fan forced at a stale target, at idle 0 RPM). Best effort:
    /// returns the fans that were to be forced to automatic
    /// (`FanWriteStrategy.rollbackWrites`). On success their baseline becomes
    /// `.automatic`; otherwise they are marked unsettled so the next poll writes
    /// their planned state unconditionally. Errors here are not reported (the
    /// original error is).
    private nonisolated func rollBackFailedWrites(_ pending: [Int: FanTarget]) async {
        guard !pending.isEmpty else { return }
        let rollback = await run { poller -> [SMCWrite] in
            for fan in pending.keys { poller.appliedTargets[fan] = nil }
            poller.unsettledFans.formUnion(pending.keys)
            let writes = (try? poller.strategy?.rollbackWrites(afterFailureOf: pending)) ?? []
            return writes.map { SMCWrite(key: $0.0, bytes: $0.1) }
        }
        guard !rollback.isEmpty, helperClient.isSessionOpen else { return }
        for write in rollback {
            do {
                try await helperClient.write(key: write.key, bytes: write.bytes)
            } catch {
                return
            }
        }
        let rolledBack = pending.filter { if case .manual = $0.value { return true } else { return false } }.keys
        await run { poller in
            for fan in rolledBack {
                poller.appliedTargets[fan] = .automatic
                poller.unsettledFans.remove(fan)
            }
        }
    }

    // MARK: - Helpers

    static func targets(from plan: [Int: Int?]) -> [Int: FanTarget] {
        var result: [Int: FanTarget] = [:]
        for (fan, rpm) in plan {
            if let rpm { result[fan] = .manual(rpm: rpm) } else { result[fan] = .automatic }
        }
        return result
    }

    static func allAutomatic(_ fans: [FanDevice]) -> [Int: FanTarget] {
        Dictionary(uniqueKeysWithValues: fans.map { ($0.id, FanTarget.automatic) })
    }

    static func fanControlError(from error: Error) -> FanControlError {
        (error as? FanControlError) ?? .helperConnectionFailed(error.localizedDescription)
    }
}

/// Settings snapshot taken on the main actor for one poll.
struct PollContext: Sendable {
    var profile: FanProfile
    var policy: SafetyPolicy
    var tuning: FanControlTuning
    var sessionOpen: Bool
    /// `isMonitoring` at snapshot time: such a poll is dropped if monitoring
    /// stopped before it ran.
    var requiresMonitoring: Bool
}

/// One SMC write (Sendable stand-in for the `(SMCKey, [UInt8])` tuple).
struct SMCWrite: Sendable {
    var key: SMCKey
    var bytes: [UInt8]
}

/// Runs async operations strictly one after another (FIFO), unlike plain actor
/// methods, which interleave at suspension points.
actor WriteSerializer {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
#endif
