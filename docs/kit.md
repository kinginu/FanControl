# FanControlKit (app-side layer)

`FanControlKit` is the library a host app links. It depends on `FanControlCore` (models, codec,
engine, curves), `FanControlSMC` (in-process IOKit SMC reads) and `FanControlXPC` (the helper
protocol). Everything except a few pure types (`FanWriteStrategy`, `FanTarget`,
`ApplyGenerationGate`, `HelperInstallStatus`, `HelperConnectionState`, `FanControlKitInfo`,
`FanControlPlatform` and the `Notification.Name` constants) is wrapped in `#if os(macOS)`.

**Apple Silicon only.** The only write scheme is `F<i>Md` + `F<i>Tg`. On a Mac that is not
arm64, the manager logs an error at init, and every SMC open fails with
`FanControlError.unsupportedPlatform`.

<!-- TODO: verify after refactor — FanControlManager is being split into smaller types; the file table and the "Threading model" section name the pre-split layout. -->

| File | Contents |
|---|---|
| `FanControlManager.swift` | The `@MainActor @Observable` singleton `FanControlManager.shared` |
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

## Threading model

Swift 6 language mode with complete strict concurrency. The compiler checks the isolation below.
The code has no `nonisolated(unsafe)`, and the only `@unchecked Sendable` is `HelperClient`,
which is lock-protected and documented.

- **`FanControlManager` is `@MainActor`.** Every observable property, the poll timer, the profile
  store, the pause / live-data-hold state and the wake bookkeeping are isolated to the main
  actor. Views call its synchronous methods directly (`startMonitoring`, `stopMonitoring`,
  `refreshNow`, `setMonitoringPaused`, `setLiveDataHold`, `saveProfile`, `deleteProfile`,
  `clearLastError`, `refreshHelperStatus`) and `await` its async ones. Code off the main actor
  must `await` both kinds. The `nonisolated` members are the static constants
  (`profileStoreDefaultsKey`, `customProfileID`, `writeThresholdRPM`, `wakeReapplyDelays`,
  `helperApprovalInstructions`), `clientTeamID`, `sensorAggregateDefinitions` and both
  `exportSMCDump()` overloads.
- Async methods run on the main actor between their awaits. The SMC work they need is awaited
  on the poll queue, and `SMAppService.register()` runs off the main actor.
- **`FanControlPoller`** (internal actor) owns all poll state: the `SMCClient`, the discovered
  fans, the cached temperature key list (discovered once; later polls call
  `readTemperatures(keys:)`), `AlertEvaluator`, `TemperatureSampleFilter`,
  `TemperatureSmoother`, `FanTargetStabilizer`, `FanWriteStrategy`, the write-throttle baseline,
  the unsettled set, the apply generation, and its own copies of the monitoring and sleep flags.
  Its executor is a private serial `DispatchSerialQueue` with QoS utility, so SMC I/O never runs
  on the main thread. There are two ways in, both FIFO: `enqueue { … }` for ordered
  fire-and-forget work, and `await run { … }` when a result is needed. Poll results are published
  back with `DispatchQueue.main.async`, in the order they were produced.
- A main run-loop `Timer` (`.common` mode, 10 % tolerance) fires every
  `effectivePollingInterval`, which is clamped to 0.5–300 s. On each tick, the main actor takes
  a snapshot of the active profile, `safetyPolicy`, `tuning` and the session flag
  (`PollContext`) and enqueues the poll. The power source monitor and the conflict detector are
  main-actor state too.
- Helper writes go through a FIFO `WriteSerializer` actor, so one write list (mode keys first,
  then targets) never interleaves with another. `FanControlPoller.applyTargets` is
  `nonisolated`: it plans on the poller, writes through the serializer, and never touches the
  main actor. The termination restore blocks the main thread for up to 2 s.
- `HelperClient` is lock-protected. Its `@Sendable onStateChange` callback is mirrored into
  `helperConnectionState` / `isSMCWriteSessionOpen` on the main actor. Every XPC call races
  `HelperClient.callTimeout` (8 s). On timeout the call throws
  `.helperConnectionFailed("timeout")` and invalidates the connection, which ends the session; the
  helper then restores. `ResumeOnce` (first of reply or timeout) is a checked `Sendable` built on
  `Synchronization.Mutex`.
- `stopMonitoring()` cancels pending wake re-apply attempts. Polls that were queued before it and
  run after it are dropped. `refreshNow()` while not monitoring opens the SMC for that single
  poll and closes it again.
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
  manual modes, and `openSMCSession`. The wake re-apply never opens one, so it can never trigger
  the install or approval flow.
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
`substitutedSensorKeys`. The filter resets when the sensors are rediscovered.

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
  `mode(for:) = modes[id] ?? defaultMode ?? .automatic`. Pass
  **`profile.resolved(for: fans)`** to `applyProfile` so that the manager sees explicit per-fan
  modes and opens the session.
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
| `clientTeamID` | `teamIdentifierPlaceholder` | Team ID required of the helper (SMAppService mode; ignored in manual mode) <!-- TODO: verify after refactor --> |

`HelperClient.callTimeout` (8 s; a value ≤ 0 disables it) is set on the `HelperClient` passed to
`FanControlManager.init`.

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
- Other Apple Silicon models: `Ftst`, the meaning of `TG*` / `TC*`, and the default thresholds.
- The battery cost of the 2 s default interval.
