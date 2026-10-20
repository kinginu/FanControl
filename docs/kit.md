# FanControlKit (app-side layer)

`FanControlKit` is the library a host app links. It depends on `FanControlCore` (models, codec,
engine, curves), `FanControlSMC` (in-process IOKit SMC reads) and `FanControlXPC` (the helper
protocol). Everything except a few pure types (`FanWriteStrategy`, `FanTarget`,
`ApplyGenerationGate`, `HelperInstallStatus`, `HelperConnectionState`, `FanControlKitInfo`,
`FanControlPlatform` and the `Notification.Name` constants) is wrapped in `#if os(macOS)`.

**Apple Silicon only.** The only write scheme is `F<i>Md` + `F<i>Tg`. On a Mac that is not
arm64, the manager logs an error at init, and every SMC open fails with
`FanControlError.unsupportedPlatform`.

| File | Contents |
|---|---|
| `FanControlManager.swift` | The `@MainActor @Observable` singleton `FanControlManager.shared` |
| `MonitoringService.swift` | Internal: poll-loop driver (monitoring flag, timer, effective interval, pause / holds) |
| `FanController.swift` | Internal: apply / session / restore / selection rollback / termination; `ProfileSelectionRollback` |
| `HelperCoordinator.swift` | Internal: install status, connection handshake, session flag, conflicting controllers |
| `WakeCoordinator.swift` | Internal: sleep / wake re-apply attempts |
| `ErrorRecorder.swift` | Internal: records a user action's error into `lastError` and rethrows |
| `FanControlPoller.swift` | Internal actor on the poll queue: SMC reads, polling, write planning, `WriteSerializer` |
| `HelperInstaller.swift` | `SMAppService.daemon(plistName:)` wrapper that knows about the manual install; `HelperInstallStatus` |
| `HelperClient.swift` | Async `NSXPCConnection` client (`SMCWriter`), `HelperConnectionState`, choice of helper requirement |
| `HelperConnectionGate.swift` | Pure rejection/backoff rules for helper connections |
| `ManualHelperSigning.swift` | Looks up the app's own Team ID and the cdhash of the root-owned manual helper |
| `FanWriteStrategy.swift` | Pure `F<i>Md` + `F<i>Tg` write sequences |
| `ApplyGenerationGate.swift` | Pure rule that drops stale poll write batches |
| `UnsettledFanDetector.swift` | Pure detection of fan-state drift |
| `MonitoringPauseState.swift` | Pause / live-data-hold state machine |
| `PowerSourceMonitor.swift` | `PowerSourceProviding` and the IOKit `PowerSourceMonitor` (AC / battery) |
| `ConflictingControllerDetector.swift` | Detects other fan-control apps and their helpers |
| `TemperatureHistory.swift` | Per-key ring buffers of recent temperatures |
| `FanControlPlatform.swift` | arm64 check (`isSupported` / `requireSupported()`), `defaultSafetyPolicy`, `sensorAggregateDefinitions` |
| `FanControlKit.swift` | Module overview and `FanControlKitInfo.version` |

## Architecture

`FanControlManager` is a thin `@MainActor @Observable` facade. The public API (names, signatures,
isolation, observable properties) is the same as before the split (2026-10-20); behind it, each
concern is an internal component that can be built and tested on its own:

```
host app / views ── public API ──► FanControlManager  (facade, @MainActor @Observable)
                                   owns: poll snapshot, profileStore, safetyPolicy,
                                         tuning, temperature history, lastError
                                          │ forwards state and actions
        ┌───────────────────┬─────────────┴──────┬────────────────────┐
        ▼                   ▼                    ▼                    ▼
 MonitoringService     FanController       HelperCoordinator     WakeCoordinator
 timer, interval,      apply, session,     install status,       sleep / wake
 power source,         restore, rollback,  handshake, session    re-apply attempts
 pause / holds         termination         flag, conflicts       (host: the facade)
        │ poll hook         │      └── uses ──────►│
        ▼                   ▼                      ▼
 FanControlPoller (actor on the poll queue) ──► HelperClient (XPC) ──► root helper
        └── publishes the poll snapshot to the facade (main queue)
```

| Component | Owns | Talks to |
|---|---|---|
| `MonitoringService` | `isMonitoring`, `isMonitoringPaused`, `isPauseInEffect`, `isOnBattery`, `effectivePollingInterval`, the interval settings, `keepAlertsWhilePaused`, the `Timer`, `MonitoringPauseState`, the `PowerSourceProviding` | the poller (monitoring flag, reader close); hooks `poll` (facade's `refreshNow()`), `beforePoll` (conflict check if due), `isSessionOpen` (slow poll while paused) |
| `FanController` | apply with selection rollback (`ProfileSelectionRollback`), open / close session, `restoreDefaultControl`, wake re-apply task, termination restore (`willTerminate` observer), `customProfileID`, `profile(changing:…)` | the poller, `HelperCoordinator`, and its `FanControllerHost` (the facade: profile store, active profile, policy, tuning, monitoring start, apply result) |
| `HelperCoordinator` | `helperStatus`, `helperConnectionState`, `isSMCWriteSessionOpen`, `conflictingControllers(Statuses)`, `HelperClient`, `HelperInstaller`, `ConflictingControllerDetector`, app launch / terminate observers | `HelperClient`; hooks `onSessionFlagChange` (reschedules a paused timer), `onConflictingControllersChange` (facade posts the notification) |
| `WakeCoordinator` | `reapplyProfileAfterWake`, the pending attempts at `[0, 2, 5]` s, will-sleep / did-wake observers | its `WakeCoordinatorHost` (the facade: session flag, poll, poller sleep flag, close / re-apply via `FanController`); the scheduler is injectable |
| `FanControlPoller` | all poll-queue state (unchanged) | publishes into the facade |

- The facade keeps the poll snapshot because `FanControlPoller` publishes into it, and the
  notifications keep the manager as their `object`. State owned by a component is exposed through
  forwarding computed properties; the components are `@Observable` themselves, so observation
  through the facade (SwiftUI, `withObservationTracking`) still works. Settings forward both
  `get` and `set` (`@Bindable` bindings keep working).
- Errors: `FanController` and `HelperCoordinator` wrap the former recording methods in an
  `ErrorRecorder` the facade installs at init, so `lastError` is set exactly where it was before
  (nested user actions record the same error more than once, as before).
- Component hooks and host references are wired at the end of the facade's `init` and are weak,
  so the facade still owns everything and is deallocated as before.
- Component tests: `Tests/FanControlKitTests/ManagerComponentsTests.swift` (timer / pause rules,
  wake attempt schedule with a fake host and scheduler, selection rollback, applies that must not
  write without a session, conflict-check throttle, install status → error mapping).

## Threading model

Swift 6 language mode with complete strict concurrency. The compiler checks the isolation below.
The code has no `nonisolated(unsafe)`, and the only `@unchecked Sendable` is `HelperClient`,
which is lock-protected and documented.

- **`FanControlManager` and its components (`MonitoringService`, `FanController`,
  `HelperCoordinator`, `WakeCoordinator`) are `@MainActor`.** Every observable property, the poll
  timer, the profile store, the pause / live-data-hold state and the wake bookkeeping are
  isolated to the main actor. Views call its synchronous methods directly (`startMonitoring`, `stopMonitoring`,
  `refreshNow`, `setMonitoringPaused`, `setLiveDataHold`, `saveProfile`, `deleteProfile`,
  `clearLastError`, `refreshHelperStatus`) and `await` its async ones. Code off the main actor
  must `await` both kinds. The `nonisolated` members are the static constants
  (`profileStoreDefaultsKey`, `customProfileID`, `writeThresholdRPM`, `wakeReapplyDelays`,
  `conflictCheckInterval`, `helperApprovalInstructions`), `clientTeamID`,
  `sensorAggregateDefinitions` and both `exportSMCDump()` overloads.
- Async methods run on the main actor between their awaits. The SMC work they need is awaited
  on the poll queue, and `SMAppService.register()` runs off the main actor.
- **`FanControlPoller`** (internal actor) owns all poll state: the `SMCClient`, the discovered
  fans, the temperature keys (discovered once as `TemperatureSensorKey`s with the key and name
  resolved; later polls call `SensorCatalog.readTemperatures(_:using:)` through
  `readSensors(using:)`, which also filters and aggregates), `AlertEvaluator`, `TemperatureSampleFilter`,
  `TemperatureSmoother`, `FanTargetStabilizer`, `FanWriteStrategy`, the write-throttle baseline,
  the unsettled set, the apply generation, and its own copies of the monitoring and sleep flags.
  Its executor is a private serial `DispatchSerialQueue` with QoS utility, so SMC I/O never runs
  on the main thread. There are two ways in, both FIFO: `enqueue { … }` for ordered
  fire-and-forget work, and `await run { … }` when a result is needed. Poll results are published
  back with `DispatchQueue.main.async`, in the order they were produced.
- A main run-loop `Timer` (`.common` mode, 10 % tolerance) fires every
  `effectivePollingInterval`, which is clamped to 0.5–300 s. On each tick, the main actor takes
  a snapshot of the active profile, `safetyPolicy`, `tuning` and the session flag
  (`PollContext`) and enqueues the poll. The timer, the power source monitor
  (`MonitoringService`) and the conflict detector (`HelperCoordinator`) are main-actor state too.
- Helper writes go through a FIFO `WriteSerializer` actor, so one write list (mode keys first,
  then targets) never interleaves with another. `FanControlPoller.applyTargets` is
  `nonisolated`: it plans on the poller, writes through the serializer, and never touches the
  main actor. The termination restore blocks the main thread for up to 2 s.
- `HelperClient` is lock-protected. Its `@Sendable onStateChange` callback is mirrored into
  `helperConnectionState` / `isSMCWriteSessionOpen` on the main actor (by `HelperCoordinator`). Every XPC call races
  `HelperClient.callTimeout` (8 s). On timeout the call throws
  `.helperConnectionFailed("timeout")` and invalidates the connection, which ends the session; the
  helper then restores. `ResumeOnce` (first of reply or timeout) is a checked `Sendable` built on
  `Synchronization.Mutex`.
- `stopMonitoring()` cancels pending wake re-apply attempts. Polls that were queued before it and
  run after it are dropped. `refreshNow()` while not monitoring opens the SMC for that single
  poll and closes it again. `setFanControlMode`, `setFanCurve` and `restoreDefaultControl` also
  close a reader they opened while monitoring is off and no session is open
  (`FanControlPoller.closeReaderIfIdle`).
- `exportSMCDump()` (sync) blocks the caller until the poll in flight and the dump finish. Never
  call it on the main thread; UIs use `await exportSMCDump()`.
- In `FanControlSMC`, `SMCConnection` (its handle is in a `Mutex`) and `SMCClient` (its key-info
  cache is in a `Mutex`) are checked `Sendable`.

## Polling and control

Every poll reads `F<i>Ac`, `F<i>Tg` and the cached temperature keys. It runs the temperatures
through the **sample filter**, appends the **aggregate sensors**, and runs `AlertEvaluator`:
the high-temperature alert and the emergency latch, both with hysteresis, plus the fan anomaly
"target > 0 but 0 RPM for 3 polls". It then smooths the control temperatures and publishes. Only
if a write session is open does it also plan, stabilise and write.

### Control loop (anti-hunting)

```
SMC read → TemperatureSampleFilter → SensorAggregator → TemperatureSmoother → FanControlEngine.plan
          (implausible Tp/Te/Tg/TC)   (agg:cpu …)        (per control key)     (FanCurve, PCHIP)
        → FanTargetStabilizer → changedTargets (25 RPM throttle, unsettled fans) → helper write
          (deadband / dwell / slew)
```

The problem this loop solves: a noisy max-of-cores input mapped straight onto a ramp and written
on every 2 s poll made the fans audibly hunt. All parameters live in `FanControlTuning` (Core,
Codable; missing keys decode to the defaults). `FanControlManager.tuning` defaults to
`.default`; `.disabled` gives the raw behaviour back.

| Stage | Parameter | Default | Rule |
|---|---|---|---|
| Smoothing | `riseTimeConstant` | 3 s | `y += (1 − e^(−dt/τ))·(x − y)`, τ = rise when `x > y` |
| | `fallTimeConstant` | 25 s | τ = fall otherwise: fans slow down only once the load is really gone |
| Deadband | `deadbandRPM` | 150 RPM | A planned target within ±150 RPM of the last stabilised one is not rewritten. Targets equal to `Mn` / `Mx` are always reached. |
| Dwell | `minimumDwell` | 10 s | A decrease or reversal waits 10 s after the last change, **and** a decrease must have been planned on every poll for 10 s |
| | `dwellAppliesToIncreases` | `false` | Consecutive increases skip the dwell |
| Slew | `maximumStepRPM` | 500 RPM / poll | Full range (2317 → 6800) in about 18 s |

- **Smoothing** (`TemperatureSmoother`) applies only to the keys the active profile's `.sensor`
  modes follow (`FanControlEngine.controlSensorKeys(profile:fans:)`). It runs on every poll, with
  or without a session. A key that drops out of use is forgotten, and a sample that is not finite
  leaves the state alone. The smoothed values are published as `controlTemperatures` and
  `controlTemperature(for:)`; `sensorReadings` stays raw (filtered). Alerts and the emergency
  latch use the raw values, so they are never delayed.
- **Stabiliser** (`FanTargetStabilizer`, a pure per-fan state machine): automatic passes through
  and drops the state, and the first manual target after automatic is used as is. The
  **emergency override bypasses it** and goes straight to max. **Explicit applies**
  (`applyProfile`, `setFanRPM`, `setFanControlMode`, `setFanCurve`, the wake re-apply) **seed**
  it with their plan. It is reset whenever a session opens or closes. After an emergency ends,
  the way back down is gradual. The 25 RPM throttle and the unsettled-fan rewrite still apply
  after the stabiliser.
- **Expected behaviour** (unit tests in `FanControlTuningTests`): a hottest core flapping
  58 ↔ 66 °C on every poll at a curve point settles in at most 2 writes and never reverses. Heavy
  random noise (±4 °C) still moves the target occasionally, in steps of at least 150 RPM within a
  band of at most 600 RPM. A step from 55 to 80 °C reaches the curve value within about 20 s.

### Fan curves (multi-point)

`FanCurve` (Core) is `points: [Point(temperature: °C, rpm: Int)]`, evaluated with **monotone
cubic interpolation (PCHIP, Fritsch–Carlson)**. The curve passes through every point without
overshoot, is monotone where the points are, and is linear with two points. It is flat before the
first point and after the last. Each point's RPM, and the result, are clamped to the fan's
`Mn…Mx`, so curves that work for any fan can use `FanCurve.fanMinimumRPM` (0, meaning "this fan's
minimum") and `fanMaximumRPM` (65 535, "its maximum"). An empty curve, or a temperature that is
not finite, gives **max** (fail loud).

API overview:

- Evaluation: `rpm(at:for:)` / `rpm(at:in:)`; `value(at:in:)` (unrounded, for charts).
- Sampling for charts: `sample(count:rpmRange:temperatureDomain:)`.
- Clean-up and resolving: `normalized()` (sorted, deduplicated, 0–130 °C); `resolved(for:)`.
- Validation: `validationIssues(rpmRange:)` / `isValid(rpmRange:)` (at least 2 points, finite,
  0–130 °C, strictly increasing, RPMs in range).
- Builders: `linear(startTemperature:maxTemperature:)`, `FanCurve.boost`.
- 10 °C grid: `gridTemperatures(from:through:step:)` (30–100 °C), `resampled(at:rpmRange:rpmStep:)`,
  and the `GridPreset`s `quiet`, `balanced`, `boost`, `fullSpeed`.

**How a curve attaches to a profile.** `FanControlMode` keeps exactly three cases (`.automatic`,
`.manual(rpm)`, `.sensor(sensorKey:startTemperature:maxTemperature:)`), so exhaustive switches
keep compiling. The curve is a payload of the profile: `FanProfile.curves: [fanID: FanCurve]`
and `FanProfile.defaultCurve`, both optional in JSON. A `.sensor` mode follows its stored curve
when the curve's first and last temperatures match the mode's start and max (±0.05 °C,
`FanCurve.matches`). Otherwise it follows the linear ramp, which is the two-point curve.
`FanProfile.curve(for:)` returns the effective curve; `setCurve(_:sensorKey:forFan:)` sets the
mode and the curve together; `removeStaleCurves()`; `resolved(for:)` fills in curves along with
modes. `FanControlEngine.plan` and `targetRPM(for: profile, fan:, sensorTemperature:policy:)` honour
curves. `FanControlManager.setFanCurve(fanIndex:sensorKey:curve:)` edits the active profile.

### Temperature history

`FanControlManager.temperatureHistory` keeps recent **raw** (filtered) readings for each key:
the `TemperatureHistory.defaultKeys` (`agg:cpu`, `agg:gpu`, `TH0x`) plus any keys a view requests
with `setTemperatureHistoryKeys(_:for:)` (pass `[]` to release them). Each key gets a ring buffer
of 1024 samples (about 34 min at 2 s), for at most 32 keys (about 0.5 MB in the worst case).
Samples that arrive out of order or are not finite are ignored. Queries: `history(for:window:now:)`,
`latest(for:)`, `range` / `minimum` / `maximum(for:window:now:)`. The history is not persisted,
and nothing is recorded while monitoring is paused.

### Emergency override

`AlertEvaluator.evaluateEmergency(sensors:policy:)` runs on every poll, with or without a session.
The latch turns **on** when the hottest emergency sensor
(`safetyPolicy.emergencySensorPrefixes`) reaches `emergencyTemperature` (95 °C), and turns **off**
only at `emergencyTemperature − alertHysteresis` (90 °C). While it is on, every fan is planned at
`maxRPM`, even under the Automatic profile. User applies evaluate the same latch, so they cannot
drop an active override inside the hysteresis band. The state is published as
`emergencyOverrideActive`. Fans are forced only while a session is open; the override never opens
a session itself. The latch resets when the SMC reader is reopened.

### Write throttle

After the stabiliser, a poll-driven write skips a fan unless its mode changes or its target has
moved by more than `writeThresholdRPM` (25 RPM) from the last value written successfully. The
poll loop never "returns" to automatic a fan it never forced. User actions bypass the throttle.
At most one poll-driven batch is in flight at a time.

### Partial failure of a write list

A list such as `[F0Md ← 1, F0Tg ← rpm]` can fail after its first write, for example because the
helper rejected it or the call timed out. That would leave the fan forced at a stale target,
which at idle is `Tg = 0`, i.e. stopped. There are two defences:

- `FanWriteStrategy` reads each fan's `Mn…Mx` at init and throws `.rpmOutOfRange` for a manual
  target outside that range (±1 RPM) **before producing any write**.
- On any failure, every fan in the list loses its baseline and is marked *unsettled*, so the
  next poll rewrites it. If the session is still open, the client immediately writes
  `FanWriteStrategy.rollbackWrites(afterFailureOf:)`, which is `F<i>Md ← 0` for the forced fans.
  If the rollback succeeds, those fans get an `.automatic` baseline. The original error is
  rethrown and stored in `lastError`. A timeout ends the session, so the helper restores
  instead.

### State drift (unsettled detection)

While a session is open, each poll also reads every fan's mode and compares it with the
throttle baseline (`UnsettledFanDetector`). A fan is marked unsettled, and rewritten by the same
poll, when any of these holds:

1. It is manual with `F<i>Tg` below `Mn − 50` (stopped in manual mode, the post-wake state),
   whatever was applied, including fans never written in this session.
2. It was applied `.manual(rpm)` but reads back as automatic, or its `Tg` is more than 50 RPM
   from `rpm`.
3. It was applied `.automatic` but reads back as manual.

Only fans with `F<i>Md` are checked. Each fan that becomes unsettled is logged at notice level
(category `fancontrol-kit`), for example
`Unsettled fan(s) detected, rewriting: F0 manual=true Tg=0 applied=manual(rpm: 3000)`. Between
the will-sleep notification and wake, polls neither flag nor write. This suspension lapses after
30 s if no wake arrives.

### Apply generation: no poll can undo a user apply

`applyProfile`, `setFanControlMode` and `setFanRPM` work in this order:

1. Store and select the profile on the main actor.
2. Bump the apply generation on the poller.
3. Plan and write.

Each poll records the generation it planned with. When its batch reaches the front of the
`WriteSerializer`, the batch is dropped if a newer apply has started
(`ApplyGenerationGate.isStale`). If the apply's writes fail, the previous selection and the
previously stored profile are restored. `restoreDefaultControl`, `closeSMCSession` and the
termination restore also bump the generation, so no stale manual target can be written after
"Restore automatic".

If no session is open but the SMC reports a fan in manual mode, `restoreDefaultControl` opens a
session only to write automatic, then closes it. This covers a helper that was killed
mid-session, or another tool that forced a fan. It is an explicit user action, and it also hands
back fans forced by other tools.

### Helper session rules

- Only user actions open the session: `setFanRPM`, `setFanControlMode`, `applyProfile` with
  manual modes (in `modes` or as `defaultMode`), and `openSMCSession`. The wake re-apply never
  opens one, so it can never trigger the install or approval flow.
- Applying a profile with manual modes while monitoring is stopped starts monitoring first.
- `openSMCSession` registers the termination and wake observers, so a session opened without
  monitoring is still restored on quit.
- Installation flow: on the first write, `installHelper()` calls `SMAppService.register()`. If
  the status is `.requiresApproval`, Login Items is opened and `.helperNotInstalled` is thrown;
  show `helperApprovalInstructions` in that case.
- `openSMCSession` compares `version()` with `protocolVersion` and re-registers a mismatched
  helper once.

`setFanControlMode` / `setFanRPM` edit the active profile. A user profile is updated in place. If
a preset is active, its effective modes for the discovered fans (`profile.resolved(for:)`) are
copied into a user profile named "Custom" (`customProfileID`), which becomes active, so the other
fans keep their mode. RPMs are validated against `fan.rpmRange` (`.rpmOutOfRange`).

### Pausing and live-data holds

`setMonitoringPaused(true)` slows polling to `max(5 × effectivePollingInterval, 10 s)` if a
session is open, or if `keepAlertsWhilePaused` is true (the default). Otherwise polling stops.
The host drives the pause from its own visibility. Views that must show live data whatever the
state, such as a settings window, call `setLiveDataHold(true, for: <name>)` on appear and `false`
on disappear. While any hold exists, the pause is not in effect, but `isMonitoringPaused` keeps
the host's request. `isPauseInEffect` is what the timer uses.

### Power-aware polling

`PowerSourceMonitor` reads `IOPSGetProvidingPowerSourceType` (on battery means
`kIOPSBatteryPowerValue`) and observes changes on the main run loop. The rule is
`PollingIntervalPolicy.effectiveInterval`:

`slowPollingOnBattery && isOnBattery ? max(pollingInterval, batteryPollingInterval) : pollingInterval`,

clamped to 0.5–300 s. The timer is rescheduled whenever the result changes. The paused interval
is `max(5 × effective, 10 s)`, which is 50 s on battery with the defaults. Tests inject a mock
source (`init(powerSource:)`).

### Other fan-control apps

Our helper has its own Mach service, so it does not collide with another app's helper. However,
two apps writing `F<n>Md` / `F<n>Tg` override each other. `ConflictingControllerDetector` checks
each known `ConflictingController`. The built-in entry is `.fanFi`: the app `com.fanfi.fanfi` with
the helper label `com.fanfi.fanfi.smcwrite`. A controller counts as running if its app is running
(`NSRunningApplication`), and as installed if `/Library/LaunchDaemons/<label>.plist` or
`/Library/PrivilegedHelperTools/<label>` exists. The manager publishes
`conflictingControllerStatuses` (everything found) and `conflictingControllers` (display names of
**running** apps), and posts `.fanControlConflictingControllersChanged`. Detection is refreshed
on `startMonitoring()`, on workspace launch and terminate notifications for a known bundle id, at
most once every 60 s from the poll timer, and on `refreshConflictingControllers()`. **It only
warns; it never blocks writes.**

### Sleep/wake

Across sleep, the SMC resets `F<i>Tg` to 0 but keeps `F<i>Md`, and at wake it briefly reports
`Md = 3`. **The helper is the safety authority:** before sleep it hands forced fans back, and it
re-applies the last targets at 0, 1 and 3 s after wake on its own ([helper.md](helper.md) §5).
The manager adds its own policy on top:

- On `willSleepNotification`, nothing is written. Pending wake attempts are cancelled, and
  poll-driven writes are suspended until wake.
- On `didWakeNotification` with a session open:
  - If `reapplyProfileAfterWake` is true (the default), the active profile is re-applied
    **immediately** and again at 2 s and 5 s (`wakeReapplyDelays` = `[0, 2, 5]`), each time with
    `force: true` and `allowOpeningSession: false`. Only the last attempt records an error.
  - If it is false, the session is **closed** immediately and the helper hands the fans back.
  - A poll runs at once and before each later attempt, so the unsettled detection also catches a
    stopped fan.

The host must not add its own wake re-apply.

### Termination

On `NSApplication.willTerminateNotification`, every fan is set to automatic and the session is
closed. Both steps go through the `WriteSerializer` after the generation bump, and the main thread
waits at most 2 s. Separately, the helper restores when the connection goes away.

### Temperature sample filter

On Mac14,9 the `Tp*` (P-core) keys read either their real value or a fixed near-zero pattern
(`0.00 / 6.70 / 8.43` and similar), alternating per read or staying that way for a whole
power-gated cluster. Every batch is filtered on the poll queue before alerts, planning and
publishing: discovery, each poll, and the fresh read of a user apply. For keys starting with
`Tp`, `Te`, `Tg` or `TC`, a finite sample below **10 °C** is rejected. It is replaced first by the
key's last accepted value, for up to **5** consecutive rejections; after that by the hottest
accepted sample of the same prefix group in that batch; and only if the whole group is implausible
is the raw value passed through.

A substitute is always hotter than the rejected sample, so the emergency maximum can only rise,
and a sensor-linked fan never runs slower than it would without the filter. Values that are not
finite pass through, which fails hot. Sudden drops above the floor are kept, because real cores
can fall 10–20 °C in one poll. The keys substituted in the latest poll are published as
`substitutedSensorKeys`. The filter resets when the sensors are rediscovered. Its per-key memory
is one `KeyState` (last accepted value, current rejection run) in `states`; the rule for one
sample is the pure `decide(_:state:groupMaximum:)`, which returns a `Decision` (`accepted`,
`substitutedLastAccepted`, `substitutedGroupMaximum`, `rejectedUnreplaced`, `ignored`).

### Aggregate sensors

Apple Silicon has no single CPU temperature key. After filtering, each batch gets synthetic
readings appended, each the **maximum** of its finite members. An aggregate with no finite member
is omitted, and a profile bound to a missing aggregate fails hot. `sensorType` is the existing
`.greatest`. Ids start with `agg:`, which cannot collide with a 4-character SMC key
(`SensorReading.isAggregate`).

| id | Name | Members | In the overview |
|---|---|---|---|
| `agg:cpu` | CPU (max) | `Tp` `Te` `TC` | yes |
| `agg:cpu.p` | CPU Performance Cores (max) | `Tp` | no |
| `agg:cpu.e` | CPU Efficiency Cores (max) | `Te` | no |
| `agg:gpu` | GPU (max) | `Tg` | yes |

`FanControlEngine.plan` resolves `.sensor(sensorKey: "agg:cpu", …)` by id. Aggregate ids match no
emergency prefix, so emergency handling is unchanged. `SensorAggregator.overview(_:definitions:)`
keeps the overview aggregates plus the readings they do not cover, and
`hottestOverview(_:definitions:limit:)` picks the hottest of those for an automatic "hottest N"
display.

### Keys excluded from ranking

`SensorCatalog.isExcludedFromRanking(_:)` lists keys that must never win an automatic "hottest"
selection: the prefix `Tf` (meaning unknown; on Mac14,9 these keys hold constants, some as high as
79–105) and, by exact key, the keys that read a constant on Mac14,9 (`TH1a`, `TH1b`, `TVMD`,
`Ta0C/D/G/H/K/L/V`, `Tz11`…`Tz18`, `Tz1j`). These keys are still discovered, published and
selectable. None of them matches an emergency prefix or an aggregate member.

### Safety policy and thresholds

`safetyPolicy` starts as `SafetyPolicy.default`. Its emergency prefixes are `Tp`, `Te`, `TC` and
`Tg`. `TG*` is excluded because on Mac14,9 those keys are battery-area `ioft` sensors at about
33 °C; the GPU is `Tg*`.

`SafetyThresholds` (Codable) holds the three adjustable values: `highTemperatureAlert` (90 °C),
`emergencyTemperature` (95 °C) and `alertHysteresis` (5 °C). `ThresholdBounds` clamps them:

| Value | Range |
|---|---|
| Alert | 70–100 °C |
| Emergency | (alert + 1)–105 °C |
| Hysteresis | 1–10 °C |

A value that is not finite becomes the default. Changing one value re-clamps the others: raising
the alert pushes the emergency threshold up, and lowering the emergency threshold (down to 71 °C)
pulls the alert down. `FanControlManager.applySafetyThresholds(_:)` copies clamped values into
`safetyPolicy`, and the next poll uses them. The hysteresis applies to both the alert and the
emergency latch.

### Sensor names

Names, groups and ranking exclusions come from one table, `SensorCatalog.entries`
(`SensorCatalogEntry`: exact key or prefix → label → `SensorGroup` → excluded). Per key, the name
is the most specific labelled row (exact, then the longest prefix; prefix rows never overlap), the
group the most specific grouped row, and the key is excluded if any matching row says so (`TH1a`
is excluded by an exact row and still named "Storage 1a" by the `TH` row). `knownNames`,
`labelKeys`, `rankingExcludedPrefixes` / `rankingExcludedKeys`, the sample filter's default
prefixes (the die groups) and the aggregate members (`SensorAggregateDefinition(groups:)`) are
derived from it.

`SensorCatalog.nameComponents(for:)` returns `SensorNameComponents` (`labelKey`, `suffix`,
`isFallback`), so a UI can localise the label and append the suffix verbatim. Examples: `TB1T` →
"Battery" + "1"; `TH0x` → "NAND (SSD)"; `Tp09` → "CPU Performance Core" + "09"; `agg:cpu` →
"CPU (max)"; unknown keys → "Sensor" + key. `displayName(for:)` returns the English name and is
the value of `SensorReading.name`.

### Platform check

`FanControlPlatform.isSupported` uses `sysctl hw.optional.arm64`, which is also true under
Rosetta. `requireSupported()` runs before every SMC open. A fan with `F<i>Tg` but no `F<i>Md` is
listed in `FanWriteStrategy.fansMissingModeKey`, and writes to it throw `fanModeKeyMissing`.

The persisted active profile is **not** re-applied at launch; the session stays closed until the
user acts.

## Charge limit

`FanControlManager.chargeLimit` (`ChargeLimitController`, `@MainActor @Observable`) backs
"Limit charging to 80 %" (`CHWA`, [helper.md](helper.md) "Charge limit (CHWA)").

- `refresh(ifOlderThan:)` reads `CHWA` **unprivileged** on a background task with a short-lived
  `SMCClient` (`classify`: absent or unexpected layout → `.unsupported`, 0/1 → `.off` / `.on`,
  other values → `.unreadable`) and re-reads the helper install status. Nothing is written.
- A `refresh` whose read started before a `setEnabled` (even one that finished while the read
  was in flight) does not publish its older value: every change bumps a generation counter.
- `setEnabled(_:)` is an explicit user action only. It takes the same "requires helper" path as a
  fan write — `HelperCoordinator.prepareHelper()` (install if needed, protocol version check;
  `openSession()` now calls it) — and then `HelperClient.setChargeLimitEnabled(_:)`. It does
  **not** open the fan write session. The helper's read-back becomes `reading`.
- `status` combines `reading` with whether the helper is usable: `.on`, `.off`, `.unsupported`,
  `.unreadable`, `.needsHelper(isOn:)`, `.unknown`.
- Errors are kept in the controller's own `lastError` (not the fan `lastError`) and mapped to
  text by `message(for:)`; a helper `invalidKey` turns `reading` into `.unsupported`.
- The kit never writes `CHWA` on its own (no re-apply at launch, wake or session open) and never
  reverts it.

## Persistence

`ProfileStore` holds the fixed profiles, any additional programmatic profiles and
`activeProfileID`, with `schemaVersion` 3. It is stored as JSON in `UserDefaults` under
**`fanControl.profileStore`** (`FanControlManager.profileStoreDefaultsKey`) on every change. The
kit does **not** persist `pollingInterval`, `slowPollingOnBattery`, `batteryPollingInterval`,
`reapplyProfileAfterWake`, `safetyPolicy` or `tuning`; the host's settings layer owns those.

## Profiles

There is a fixed set of seven profiles (`FanProfile.fixedProfileIDs`), with fixed UUIDs
(`FanProfile.BuiltInID`). Users cannot create or delete profiles. The preset values are
provisional.

| Profile | id `6F1A0000-0000-4000-8000-…` | Content | Editable |
|---|---|---|---|
| Automatic | `…000000000001` | SMC default (no override) | no |
| Constant Quiet | `…000000000011` | Every fan at 3000 RPM | no |
| Constant High | `…000000000012` | Every fan at 5000 RPM | no |
| Boost | `…000000000013` | Every fan `.sensor(agg:cpu, 50 → 85 °C)` with `FanCurve.boost`: 50 °C min, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800 | no |
| Max | `…000000000014` | Every fan at 6800 RPM (clamped to each fan's max) | no |
| Custom 1 | `…000000000021` | Default: a copy of Boost, curve included | per-fan modes, curves and name |
| Custom 2 | `…000000000022` | Default: every fan at 3500 RPM | per-fan modes, curves and name |

- Constant RPMs are clamped to each fan's `Mn…Mx` when applied. The emergency override still
  forces max when the Mac is hot, whatever the profile.
- **Boost runs loud at idle by design.** `agg:cpu` is the hottest core, which idles at about
  72–78 °C on Mac14,9, so Boost runs at about 5500–6100 RPM at idle. It reaches full speed 10 °C
  below the emergency threshold. To retune it, copy it into a custom slot.
- **"Every fan" presets** use `FanProfile.defaultMode`, so that
  `mode(for:) = modes[id] ?? defaultMode ?? .automatic`. `applyProfile` opens the session when
  `modes` **or** `defaultMode` holds a manual mode, so a preset applied before the fans are known
  (or passed unresolved) is written, not just selected. Passing `profile.resolved(for: fans)`
  remains the way to get explicit per-fan modes.
- Presets are read-only and regenerated from code on every decode, so a changed preset value
  reaches existing installs. Only the custom slots persist edits. Every `.sensor` mode in a
  custom slot has a matching curve; if a mode has none, the equivalent linear curve is filled in.
- API: `upsert` (custom slots and additional profiles), `rename(id:to:)`, `reset(id:)`,
  `isModified(id:fans:)`, `delete(id:)` (a no-op for the seven).
- **Additional profiles** that the manager or tools create, such as "Custom" from `setFanRPM`, are
  kept after the seven, so they stay active across polls, wake and relaunch. A UI that lists
  `fixedProfiles` does not show them.
- **Migrations.** Legacy JSON without `schemaVersion` keeps the first sensor-linked user profile
  as Custom 1 and drops the other user profiles. Schema 2 → 3 adds Max and upgrades an unchanged
  old Custom 1 to the Boost curve. Nothing is re-applied by a migration.

## Profile precedence and automation

Two automatic features choose the active fan profile: power profiles (F2) and workload
automation (F3). Both go through one arbiter; neither calls `applyProfile` itself.

### Precedence and power profiles

<!-- F2 (DynamicNotchApp/docs/power-profiles.md). -->

- **Rules** (`FanControlCore/PowerProfileRules.swift`): `PowerProfileRule` = conditions (power
  source any / AC / battery, lid any / open / closed, optional daily `PowerTimeWindow` with
  weekdays, wrapping past midnight) → actions (fan profile id or none, Low Power Mode
  unchanged / on / off). `PowerProfileConfiguration.firstMatch` returns the first **enabled**
  rule whose conditions all hold (nothing while the configuration is off). Decoding is
  tolerant (unknown values fall back to defaults). macOS Focus is not a condition (no public API).
- **Precedence** (`FanControlCore/ProfileArbitration.swift`): `manual > emergency > workload >
  power > default`. Automatic features claim a layer (`.power`: power profiles, `.workload`:
  per-app profiles, `.emergency`: reserved). A profile change the arbiter did not make is a
  manual selection: it wins until the automatic winner changes to another profile (the next
  transition) or `resumeAutomation()`, and becomes the new default (baseline). The
  manager's 95 °C emergency override is independent of this and always forces every fan to maximum.
- **`FanProfileArbiter`** (Kit, `@MainActor @Observable`, `.shared`): applies the decision
  through `FanProfileHosting` (`FanControlManager` conforms: `applyProfile(profile.resolved(for: fans))`)
  only when it differs from the active profile; a failed decision is not retried until it
  changes or `retry()`; `isApplyAllowed` gates applying (the app: Fan Control enabled). It
  observes `activeFanProfileID` (`withObservationTracking`) to detect manual picks.
- **Other observers of `activeFanProfileID`** (e.g. `WorkloadProfileCoordinator`): the arbiter is
  the single classifier of automatic vs manual changes. Either subscribe to
  `FanProfileArbiter.manualSelectionNotification` (posted when a change the arbiter did not make is
  classified as the user's pick; `userInfo["profileID"]`), or ignore a change while
  `arbiter.isApplying` is `true` or when the new id equals `arbiter.lastAutomaticApplyID` (set
  *before* `applyFanProfile` is called, so observers running during the apply already see it;
  cleared by the next manual pick). `automaticApplyNotification` is posted after every successful
  automatic switch (`userInfo`: `profileID`, `layer` raw value, `reason`). Workload profiles should
  claim `.workload` (`setClaim(_:for: .workload)`) instead of calling `applyProfile` themselves.
- **`PowerProfileEngine`** (Kit, `@MainActor @Observable`, `.shared`): persists the configuration
  (`fanControl.powerProfiles`), evaluates on every `PowerContextProviding` change
  (`SystemPowerContextProvider`: IOPS power source, `AppleClamshellState` of `IOPMrootDomain`,
  wake, `NSProcessInfoPowerStateDidChange`, a 30 s tick for time windows), chains evaluations
  (never concurrent), claims the matched rule's fan profile on `.power` and drives Low Power
  Mode on **transitions** only. Before its first change it remembers the user's settings per
  power source (`pmset -g custom`, unprivileged: battery and AC, so "Only on Battery" survives;
  the in-use value as fallback) and then sets every source (`-a`). Once no rule asks for a
  value they are given back (`-b` / `-c`, or `-a` when equal), unless the user changed them
  meanwhile (`LowPowerModeMemory`, persisted under `fanControl.powerProfiles.lowPowerModeMemory`
  so a relaunch does not lose it; older memories without per-source values still decode). The
  memory is dropped only after the restore succeeded (or is moot), and the first evaluation
  after launch always syncs, so a persisted memory is restored even if no rule ever matches
  again. A failed change or restore is retried on later evaluations, at most every
  `lowPowerModeRetryInterval` (60 s).
- **Low Power Mode**: `FanControlManager.setLowPowerMode(battery:ac:)` (and `setLowPowerMode(_:)`
  for both) → `HelperClient.setLowPowerMode(battery:ac:)` → the helper's dedicated request
  ([helper.md "Low Power Mode request"](helper.md#low-power-mode-request)). It never registers
  the helper and needs no write session. The request goes over a **separate, short-lived
  client** (`HelperClient.makeIndependentClient`, timeout `LowPowerModeCommand.clientCallTimeout`
  = 30 s, invalidated afterwards): a slow pmset never queues the session connection's writes,
  and its timeout cannot invalidate that connection (which would make the helper restore the
  fans). A sticky rejection of the main client is reported without connecting. Reads:
  `LowPowerModeReader` (`ProcessInfo.isLowPowerModeEnabled`, `pmset -g`, `pmset -g custom`).
- UI (`FanControlUI/PowerProfiles/`): `FanControlPowerProfilesSettingsView` (rules editor),
  `FanControlPowerProfileStatusLine` (one line for a widget), `FanControlPowerProfiles.start()`
  (host start-up hook; gates fan switching on `FanControlSettingKey.general.isEnabled`).
- Tests: `PowerProfileRulesTests` / `ProfileArbitrationTests` (Core), `PowerProfileEngineTests`
  (Kit, injected context + fake Low Power Mode + fake fan host), `LowPowerModeCommandTests`
  (XPC, fake pmset), `LowPowerModeEndToEndTests` (real XPC, `FakeHelper`).

### Workload automation

`WorkloadProfileEngine` (pure value type; time is passed in) switches the active profile by
workload; the host drives it (DynamicNotch: `WorkloadProfileCoordinator`, a 2 s tick plus
`NSWorkspace` launch / terminate / activate notifications) and turns each `WorkloadDecision`
into a claim on the arbiter's `.workload` layer (below). Settings are
`WorkloadAutomationSettings` (Codable, unknown / missing keys fall back to defaults), stored by
FanControlUI under `fanControlWorkloadAutomation` (`FanControlSettingKey.automation`). The UI
(`FanControlAutomationTabView`, `FanControlAutomationIndicator`) shows
`FanControlAutomationState.shared`, which the host's driver writes (`status`, loads, last apply
error) and whose `onResume` it sets.

**Precedence** is the arbiter's (above); the engine's own view (`WorkloadProfilePrecedence`):

| Layer | Behaviour |
|---|---|
| Manual | A profile the user picks by hand (classified by the arbiter, `manualSelectionNotification`) is never replaced. The engine disengages *without* returning and pauses for `manualOverrideMinutes` (15 / 30 / 60 / 120, or 0 = until resumed / disabled and re-enabled); its `.workload` claim is kept meanwhile, so withdrawing it does not end the user's override. |
| Emergency | While `emergencyOverrideActive`, decisions are held (no switch either way). The override itself forces max under any profile, the manual one included (see "Emergency override"). |
| Workload | Enabled app rules in list order (`running` or `frontmost`), then the sustained-load rule. |
| Power (F2) | Its own `.power` claim; it wins whenever no workload claim is set. |
| Default | The arbiter's baseline (the profile active at the first claim, or the last manual pick). |

**Rules and hysteresis.**

- App rules stay matched `appReleaseDelay` s (default 10) after the app quits or loses focus.
- Load rule (`cpu`, `gpu`, or `either` = the higher): engage after `highDuration` s
  continuously above `highThreshold` (default 20 s above 70 %); release after `lowDuration` s
  continuously below `lowThreshold` (default 60 s below 40 %); in between the state holds. A
  missing sample (`nil`) leaves the phase and its timers unchanged.
- While engaged, a different winning rule switches directly and keeps the baseline. When no rule
  is active any more, the decision names the baseline once (`nil` baseline = Automatic).
- Turning automation off while engaged returns to the baseline once and clears the manual lock.
  `reset()` forgets everything without returning (used when fan control itself is off).
- Rules whose profile is not in `WorkloadSnapshot.availableProfileIDs` are skipped.

**Load sampling.** `SystemLoadSampler`: CPU busy share from `host_statistics(HOST_CPU_LOAD_INFO)`
tick deltas between calls (`CPULoadTicks.usage`, 32-bit wrap-safe; `nil` on the first call), GPU
from the highest IOAccelerator `PerformanceStatistics` "Device Utilization %".

**Arbiter wiring** (`WorkloadProfileCoordinator`, the adapter closure `applyWorkloadProfile`):

- `engaged(profile, reason)` → `FanProfileArbiter.shared.setClaim(ProfileClaim(profile, reason), for: .workload)`.
  When the engine re-engages after a manual pause, the coordinator also calls
  `resumeAutomation()` so the arbiter's manual layer ends at the same time as the engine's pause.
- `idle` / `disabled` (the engine names the baseline once) → `setClaim(nil, for: .workload)`; the
  arbiter then picks the next layer (power, else the baseline). The engine's own baseline id is
  not applied.
- `pausedByManualSelection` / `heldForEmergency` → the claim is left as it is.
- Fan control off → `reset()` and the claim is withdrawn.
- A failed apply is the arbiter's (`lastError`, not retried until the decision changes); the
  coordinator mirrors it into `FanControlAutomationState.lastApplyError`.
- `noteLowerLayerSelection` and the old `requestLowerLayerProfile` entry point are not used: power
  profiles claim `.power` directly.


## Settings owned by the app

The kit does not depend on the app's settings store. The app copies its settings into these
main-actor properties at launch, before `startMonitoring()`, and again on every change:

| Property | Default | Effect |
|---|---|---|
| `pollingInterval` | 2.0 s | Timer interval (0.5–300 s) |
| `slowPollingOnBattery` | `true` | On battery, poll every `max(pollingInterval, batteryPollingInterval)` |
| `batteryPollingInterval` | 10 s | The battery interval |
| `reapplyProfileAfterWake` | `true` | `true`: re-apply at 0 / 2 / 5 s after wake; `false`: close the session on wake |
| `keepAlertsWhilePaused` | `true` | Keep a slow poll while paused without a session |
| `safetyPolicy` | `FanControlPlatform.defaultSafetyPolicy` | Read on every poll; set thresholds with `applySafetyThresholds(_:)` |
| `tuning` | `.default` | Control-loop parameters |
| `clientTeamID` | `FanControlClientTeamID` from the app's Info.plist, else `teamIdentifierPlaceholder` (`TEAMID0000`) | Team ID required of the helper (SMAppService mode; ignored in manual mode). `nonisolated`; set it before the first helper call |

`HelperClient.callTimeout` (8 s; a value ≤ 0 disables it) is set on the `HelperClient` passed to
`FanControlManager.init`.

## UI layer (`FanControlUI`)

`FanControlUI` (depends on `FanControlCore` + `FanControlKit`) is the SwiftUI layer on top of the
manager, for hosts that want the stock settings and editors:

| Area | Public API |
|---|---|
| Settings pane | `FanControlSettingsView` (fixed `contentSize` 740×600; General / Profiles / Sensors / Automation as a segmented control), and each tab on its own: `FanControlGeneralTabView(actionError:)`, `FanControlProfilesTabView(actionError:initialSelection:)`, `FanControlSensorsTabView()`, `FanControlAutomationTabView()` |
| Workload automation | `FanControlAutomationState.shared` (host-written state, `indicatorText`, `statusText`), `FanControlAutomationIndicator` (one line for a widget header), `FanControlAutomationProfiles` ("Workload automation") |
| Curves and charts | `FanCurveView` (read-only curve of a profile, live operating point), `FanCurveEditorView` (multi-point editor, `hasErrors` / `messages` validation), `FanCurveLegend`, `FanControlTemperatureChart` + `FanControlTemperatureSeries` (history chart), `FanControlKeyTemperaturesView`, `FanControlSelectionPill` |
| Alerts | `FanControlAlertCoordinator.shared` (`currentAlert`, `onAlertChange`, `transientNotificationName`); it also mirrors the stored general settings and thresholds into the manager ("Settings owned by the app") |
| Power profiles (F2) | `FanControlPowerProfilesSettingsView` (rules editor pane), `FanControlPowerProfileStatusLine(isCompact:)`, `FanControlPowerProfiles.start()` ("Power profiles and profile precedence") |
| Errors | `FanControlErrorFooter`, `fanControlPerform`, `fanControlErrorMessage`, `fanControlRejectionHelp` |
| Formatting | `FanControlFormatting`, `FanControlSensorNames`, `FanControlProfiles` (the seven fixed profiles, `apply`) |
| Stored settings | `FanControlWidgetSettings`, `FanControlGeneralSettings`, `FanControlThresholdSettings`, `FanControlTemperatureWidgetSettings`; keys `FanControlSettingKey` (`.widget`, `.general`, `.thresholds`, `.temperatureWidget`, `.automation`: `value`, `updates()`, `name`) and the property wrapper `@FanControlSetting(.widget)` |

Settings live in `UserDefaults.standard` under the former sindresorhus/Defaults key names, as
sorted-key JSON strings (byte-compatible with Defaults 8.2; `Tests/FanControlUITests`). The store
(`SettingsStore`, `StoredKey`, `@StoredSetting`; `Sources/FanControlUI/Storage/SettingsStore.swift`)
is internal; a host may compile the same file into its own module for its own settings
(DynamicNotchApp does, by symlink) — both copies observe the same keys by KVO. Labels are looked up
in the host's `Localizable.strings` (`Bundle.main`); some strings still name DynamicNotch and the
Nook. Host-specific glue (DynamicNotch's Nook widgets, Live Activity view, Nook visibility hook)
stays in `DynamicNotchIntegration/` (`PATCHES.md`).

## Helper requirement and install status

**Requirement selection**, made for every new connection by
`FanControlHelperConstants.helperRequirementMode(appTeamID:manualInstallDetected:)`:

| Condition | Requirement on the helper |
|---|---|
| The app's signature has a Team ID **and** no manual-install files exist | `helperCodeSigningRequirement(teamID: clientTeamID)` |
| The app has no Team ID (ad-hoc) **or** manual-install files exist | `identifier "<helper label>" and cdhash H"<installed helper cdhash>"` |

In manual mode, the cdhash is read at connect time from `/Library/PrivilegedHelperTools/<label>`,
after checking that the file and its directory are owned by root and are not group- or
other-writable. If the cdhash cannot be read, the call fails without connecting. Transport errors
in manual mode get a hint appended: "re-run sudo install.sh <app>".

**`HelperInstaller`** checks the manual files first:

| LaunchDaemon plist | Helper binary | `status()` | `register()` | `unregister()` |
|---|---|---|---|---|
| present | present | `.installedManually` | no-op | throws ("use sudo uninstall.sh") |
| present, but pins another app cdhash | present | `.installedManuallyMismatch(pinnedCDHash:appCDHash:)` | no-op | throws |
| exactly one of the two present | | `.unknown("manual installation incomplete …")` | throws | throws |
| absent | absent | `SMAppService` status | `register()` | `unregister()` |

`.installedManually` counts as `.enabled`. A protocol mismatch with a manually installed helper
throws "Re-run sudo install.sh…" instead of re-registering.

## Helper connection lifecycle

**Read-only monitoring never touches the helper.** `HelperClient` connects lazily, and only for
these:

| Trigger | Calls |
|---|---|
| User applies a profile with a manual mode, or calls `setFanRPM` / `setFanControlMode` | `version()`, `openSession()`, then `write`s |
| User chooses "Restore automatic control" or turns the feature off | With a session: writes, then `closeSession()`. Without one: only if the SMC reports a manual fan |
| User chooses "Check Again" (`retryHelperConnection()`) | `version()` once |
| An open session only: poll writes, wake re-apply, ⌘Q restore | `write`, `closeSession()` |

**Retry policy** (`HelperConnectionGate`, pure and tested; one gate per client):

1. **Pin pre-check (manual mode, no connection).** The client compares the client cdhash pinned in
   the root-owned plist with its own (`manualClientPinCheck`). A mismatch is a rejection,
   `.clientNotPinned`. If the check cannot decide, the client goes on to step 2.
2. **Runtime classification** of proxy errors:
   - `NSXPCConnectionCodeSigningRequirementFailure` (4102) → immediate rejection,
     `.helperSignatureMismatch`.
   - `NSXPCConnectionInterrupted` (4097) before any reply, **twice in a row** → `.droppedByHelper`.
   - Anything else is transient.
3. **A rejection is sticky.** `connectionState = .rejected(reason:)`, and every later call throws
   `.helperConnectionRejected` **without connecting** until one of these happens:
   `resetRejection()` (the "Check Again" button), the app relaunches, or the install fingerprint
   (size and mtime of the plist and the helper) changes.
4. **Transient failures back off.** After the n-th consecutive failure, calls fail fast for
   `min(2 s × 2^(n−1), 300 s)`. Any reply resets the counters.

`HelperConnectionState` is `.disconnected`, `.connecting`, `.connected`, `.error(String)` or
`.rejected(reason:)`. `HelperRejectionReason.description` is English and names the remedy.

## Errors

Failures of async actions are rethrown **and** stored in `lastError`. Poll-loop failures are
stored too, and `lastError` is re-published only when its value changes. A failed fan discovery
leaves `fans` empty and is retried. The manager never clears `lastError` itself; call
`clearLastError()` when the user dismisses it. Error meanings:

- `.helperNotInstalled` while `helperStatus == .requiresApproval`: the helper is waiting for
  approval.
- `.helperConnectionRejected`: the helper refuses this app.

## Notifications

All of these are posted on the main thread, with the manager as the object.

| Name | When | userInfo |
|---|---|---|
| `.fanControlHighTemperatureChanged` | `highTempAlertActive` changed | `"active": Bool` |
| `.fanControlFanAnomalyChanged` | `anomalousFanIDs` changed | `"fanIDs": Set<Int>` |
| `.fanControlDidUpdate` | After every published poll | none |
| `.fanControlConflictingControllersChanged` | `conflictingControllers` changed | `"names": [String]` |

## Helper-side checks

The helper is the safety authority ([helper.md](helper.md) §4). Independently of the kit, it
rejects:

- keys outside the allowlist (`F<n>Tg`, `F<n>Md`);
- keys whose attributes lack `0x40`;
- payloads that are not 1–32 bytes or do not match `dataSize`;
- `Md` values other than 0 or 1;
- `Tg` values outside the hardware `Mn…Mx` (±1 RPM).

## Write sequences (`FanWriteStrategy`)

A fan is controllable when both `F<i>Tg` and `F<i>Md` have key info.

| Fan | Manual | Automatic |
|---|---|---|
| `F<i>Md` exists | `F<i>Md ← 1`, then `F<i>Tg ← rpm` (`flt `) | `F<i>Md ← 0` |
| `F<i>Tg` without `F<i>Md` | throws `.fanModeKeyMissing` | throws `.fanModeKeyMissing` |
| No `F<i>Tg` | throws `.keyNotFound("F<i>Tg")` | throws `.keyNotFound("F<i>Tg")` |

All mode writes come before all target writes. A list that contains any failing fan throws before
it produces a single write. On Mac14,9, `F<i>Md` is `ui8 ` (`01` / `00`) and `F<i>Tg` is a
little-endian `flt ` (2317 RPM = `00 d0 10 45`, the same bytes as `F<i>Mn`). `F<i>Mn` is never
written.

## Testing

Unit tests use Swift Testing (`swift test`; with Xcode installed but `xcode-select`
on the Command Line Tools, prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).

**End-to-end helper contract** (`Tests/FanControlKitTests/EndToEnd/`, suite
"Helper end-to-end (in-process XPC)", run alone with
`swift test --filter HelperEndToEnd`, about 5 s): a real `NSXPCConnection` from
`HelperClient` to an in-process `FakeHelper` served by `NSXPCListener.anonymous()`,
backed by a thread-safe `FakeSMC` (Mac14,9 layout: `F<n>Md` ui8 0xd0, `F<n>Tg` flt
0xd4, read-only `Mn`/`Mx`). No root, launchd, signing or SMC hardware. The client is
built with the internal test seam `HelperClient(connectionFactory:)` (`@testable`),
which skips only the install-dependent parts (manual pin check, helper code-signing
requirement, install fingerprint); gate, timeout, session flag and state handling
are the production code.

- Covered: version handshake, open/close session, `FanWriteStrategy` write order
  (`Md` before `Tg`), helper validation (allowlist, `Mn...Mx`, mode 0/1), partial
  failure + rollback (`Md`=1 accepted, `Tg` failed → `Md`=0), restore on close /
  disconnect / client deallocation / helper shutdown (`Md`=0 only, `Tg` not written
  back), call timeout (hung helper → connection invalidated → session released),
  protocol-version mismatch surfaced by `version()`, `notSessionOwner` and same-pid
  reclaim, sleep hand-back and wake re-apply (`PowerTransitionPolicy`), and the
  rejection paths with **real** code-signing requirements: a requirement on the
  helper the peer does not meet → `.rejected(.helperSignatureMismatch)` (sticky,
  later calls do not connect, `resetRejection()` clears it); the helper's client
  requirement (as `HelperListenerDelegate` sets it) or a helper dropping the
  connection on the first message → transient first, `.rejected(.droppedByHelper)`
  on the second attempt after the 2 s backoff; a listener refusing the connection
  → transient `.error` with backoff, never a rejection.
- Not covered: `FanControlManager` / `FanControlPoller` (their reader is the IOKit
  `SMCClient`; the tests replay `applyTargets` + `rollBackFailedWrites` with the same
  `FanWriteStrategy` calls), the helper executable's own `SessionRegistry` /
  `HelperService` / `PowerObserver` (the fake duplicates their glue around the real
  `HelperWritePolicy` / `PowerTransitionPolicy`; keep it in step), the privileged
  Mach service, launchd, `SMAppService`, manual-install cdhash pinning, and process
  death (`kill -9`) — all verified on hardware instead (`docs/verification/`).
- Observed: with a failing client-side requirement on the helper, the first message
  still reaches the peer and only its reply is discarded.

## Still to verify on hardware

- The `SMAppService` registration and approval flow, and both code-signing requirements, with
  real Team ID signing.
- Whether 8 s is a good XPC timeout on a loaded machine, and whether 2 s is enough for the
  termination restore.
- Other Apple Silicon models: whether `F<i>Md` + `F<i>Tg` is enough to control the fans, the
  meaning of `TG*` / `TC*`, and the default thresholds.
- The battery cost of the 2 s default interval.
