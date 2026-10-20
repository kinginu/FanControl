# FanControlKit (app-side layer)

**Apple Silicon only (Intel dropped 2026-10-20).** The only write scheme is `F<i>Md` + `F<i>Tg`;
the Intel `FS! ` force-bit path, per-architecture sensor/policy tables and the
`FanControlPlatform.isAppleSilicon` branching were removed. On a non-arm64 Mac the manager logs an
error at init and every SMC open fails with `FanControlError.unsupportedPlatform`.

`FanControlKit` is what DynamicNotch links. It depends on `FanControlCore` (models, codec, engine),
`FanControlSMC` (in-process, read-only IOKit SMC access) and `FanControlXPC` (helper protocol).
Everything except `FanWriteStrategy`, `FanTarget`, `ApplyGenerationGate` (internal),
`HelperInstallStatus`, `HelperConnectionState`, `FanControlKitInfo`, `FanControlPlatform` and the
`Notification.Name` constants is wrapped in `#if os(macOS)`.

| File | Contents |
|---|---|
| `FanControlManager.swift` | `@MainActor @Observable` singleton `FanControlManager.shared` (design doc §3.1) |
| `FanControlPoller.swift` | internal actor on the poll queue: SMC reads, polling, write planning, `WriteSerializer` |
| `HelperInstaller.swift` | `SMAppService.daemon(plistName:)` wrapper aware of the manual installation, `HelperInstallStatus` |
| `HelperClient.swift` | async `NSXPCConnection` client (`SMCWriter`), `HelperConnectionState`, helper requirement selection |
| `ManualHelperSigning.swift` | own Team ID lookup and cdhash of the root-owned manually installed helper (manual-install mode) |
| `FanWriteStrategy.swift` | pure `F<i>Md` + `F<i>Tg` write sequences (unit-tested on Linux) |
| `ApplyGenerationGate.swift` | pure drop rule for stale poll write batches (unit-tested on Linux) |
| `PowerSourceMonitor.swift` | `PowerSourceProviding` + IOKit `PowerSourceMonitor` (AC / battery, power-aware polling) |
| `ConflictingControllerDetector.swift` | `ConflictingController` (`.fanFi`), `ConflictingControllerDetector` (other fan control apps running / helper installed) |
| `TemperatureHistory.swift` | `TemperatureHistory`: per-key ring buffers of recent temperatures (Temperature widget) |
| `FanControlPlatform.swift` | arm64 assertion (`isSupported` / `requireSupported()`, backed by `FanControlCore.FanControlHost`, `sysctl hw.optional.arm64`), `defaultSafetyPolicy`, `sensorAggregateDefinitions` |

## Threading model

Swift 6 language mode with complete strict concurrency (`swift-tools-version: 6.0`,
`swiftLanguageModes: [.v6]`, deployment target macOS 26; 2026-10-20). The isolation below is
checked by the compiler; no `nonisolated(unsafe)` is used and the only `@unchecked Sendable` left
is `HelperClient` (lock-protected, justified in its doc comment).

- **`FanControlManager` is `@MainActor`** (and therefore `Sendable`). Every observable property,
  the poll timer, the profile store, the pause / live-data-hold state and the wake bookkeeping
  are main-actor isolated. Views call its synchronous methods (`startMonitoring`,
  `stopMonitoring`, `refreshNow`, `setMonitoringPaused`, `setLiveDataHold`, `saveProfile`,
  `deleteProfile`, `clearLastError`, `refreshHelperStatus`) directly and `await` its async
  methods; code that is not on the main actor must `await` both (the former "hop to main if
  called elsewhere" fallback is gone: the compiler now enforces the main-actor call sites).
  `nonisolated`: the static constants (`profileStoreDefaultsKey`, `customProfileID`,
  `writeThresholdRPM`, `wakeReapplyDelays`, `helperApprovalInstructions`), `clientTeamID`
  (forwards to the lock-protected `HelperClient`), `sensorAggregateDefinitions` and both
  `exportSMCDump()` overloads. `shared` and `init` are main-actor isolated.
- Async methods run on the main actor between their awaits (state is read and published directly,
  no `MainActor.run`); the SMC work they need is awaited on the poll queue, and
  `SMAppService.register()` (`installHelper`) runs off the main actor.
- **`FanControlPoller`** (internal actor, `FanControlPoller.swift`) owns all poll state: the
  `SMCClient`, the discovered fans, the cached temperature key list
  (`SensorCatalog.discoverTemperatureSensors` runs once; later polls use `readTemperatures(keys:)`),
  the `AlertEvaluator`, the `TemperatureSampleFilter`, the `TemperatureSmoother`, the
  `FanTargetStabilizer`, the `FanWriteStrategy`, the write-throttle baseline, the unsettled set, the apply generation (`ApplyGenerationGate`), its own copy of the
  monitoring flag and the sleep flag. Its executor is a private serial `DispatchSerialQueue`
  (QoS utility, the former `pollQueue`), so SMC I/O never runs on the main thread. The manager
  enters it in two FIFO-compatible ways: `enqueue { … }` (`queue.async` + `assumeIsolated`) for
  ordered fire-and-forget work (monitoring flag, polls, sleep/wake flags) and `await run { … }`
  for results. Poll results are published back with `DispatchQueue.main.async` in the order they
  were produced (the published properties are `public internal(set)` for this).
- A `Timer` on the main run loop (`.common` mode, 10 % tolerance) fires every
  `effectivePollingInterval` (`pollingInterval`, slowed on battery; effective range 0.5 to 300 s).
  The power source (`PowerSourceProviding`, IOKit run-loop source on the main run loop) and the
  conflict check (`ConflictingControllerDetector`, NSWorkspace launch / terminate observers on the
  main queue) are main-actor state too. Each tick snapshots the active profile, `safetyPolicy`, `tuning` and the
  session flag on the main actor (`PollContext`), then enqueues the poll on the poller.
- Helper writes go through a FIFO `WriteSerializer` actor, so a write list (mode key first,
  then target) is never interleaved with another list. `FanControlPoller.applyTargets` is
  `nonisolated`: it plans on the poller, writes through the serializer and never touches the main
  actor (the termination restore blocks the main thread for up to 2 s while it runs).
- `HelperClient` is lock-protected; its `onStateChange` callback (`@Sendable`) is mirrored onto
  `helperConnectionState` / `isSMCWriteSessionOpen` on main. Every XPC call races against
  `HelperClient.callTimeout` (8 s): on timeout it throws `.helperConnectionFailed("timeout")` and
  invalidates the connection (which ends the session; the helper restores the pre-session values),
  so a hung helper cannot block the `WriteSerializer` forever. `ResumeOnce` (one XPC reply or the
  timeout, whichever comes first) is a checked `Sendable` built on `Synchronization.Mutex`.
- `stopMonitoring()` cancels pending wake re-apply attempts; polls that were queued while monitoring and
  run after `stopMonitoring()` are dropped and do not reopen the reader. `refreshNow()` while not
  monitoring opens the SMC for that one poll and closes it again (unless a write session is open).
- `exportSMCDump()` (sync, `nonisolated`) blocks the caller (`queue.sync`) until the in-flight poll
  and the whole dump finish; never call it on the main thread or the poll queue. UIs must use the
  async overload `await exportSMCDump()`, which runs on the poller.
- `FanControlSMC`: `SMCConnection` (handle in a `Mutex`) and `SMCClient` (key-info cache in a
  `Mutex`) are checked `Sendable`.

## Polling and control

Every poll reads `F<i>Ac`, `F<i>Tg` and the cached temperature keys, passes the temperatures
through the `TemperatureSampleFilter` (below), appends the aggregate sensors (below), runs `AlertEvaluator` (high temperature with hysteresis; emergency latch with hysteresis; 0 RPM with
target > 0 for 3 polls = anomaly), smooths the control temperatures, and publishes. If (and only
if) a write session is open, it also computes `FanControlEngine.plan(profile:fans:sensors:policy:isEmergency:)`
on the smoothed values, stabilizes the result and writes it (see "Control loop").

### Control loop (anti-hunting, 2026-10-20)

Problem seen by the user: the fans hunted at curve boundaries (louder / quieter every few
seconds), because the noisy max-of-cores input (`agg:cpu`) was mapped straight onto a linear ramp
every 2 s poll and written immediately. The loop is now:

```
SMC read → TemperatureSampleFilter → SensorAggregator → TemperatureSmoother → FanControlEngine.plan
         (implausible Tp/Te/Tg/TC)   (agg:cpu …)        (per control key)     (FanCurve, PCHIP)
         → FanTargetStabilizer → changedTargets (25 RPM throttle, unsettled fans) → helper write
           (deadband / dwell / slew)
```

All parameters live in `FanControlTuning` (Core, Codable, missing keys decode to the defaults),
`FanControlManager.tuning` (default `.default`, read by the next poll, not persisted by the kit;
`.disabled` restores the old raw behaviour):

| Stage | Parameter | Default | Rule |
|---|---|---|---|
| smoothing | `riseTimeConstant` | 3 s | `y += (1 − e^(−dt/τ))·(x − y)`, τ = rise when `x > y` |
| | `fallTimeConstant` | 25 s | τ = fall otherwise: fans slow down only after the load is really gone |
| deadband | `deadbandRPM` | 150 RPM | a planned target within ±150 RPM of the last stabilized one is not rewritten (targets equal to the fan's `Mn` / `Mx` are always reached) |
| dwell | `minimumDwell` | 10 s | a decrease or a reversal waits 10 s after the last change, **and** a decrease is made only after it has been planned on every poll for 10 s (a momentary dip does not slow the fans) |
| | `dwellAppliesToIncreases` | `false` | consecutive increases are exempt from the dwell (a heating CPU gets more air every poll); `true` = every change waits (the literal "≥ 10 s per target" rule) |
| slew | `maximumStepRPM` | 500 RPM / poll | full range (2317 → 6800) in ≈ 18 s while heating |

- **Smoothing** (`TemperatureSmoother`, Core): only the keys followed by the active profile's
  `.sensor` modes (`FanControlEngine.controlSensorKeys(profile:fans:)`) are smoothed, after the
  filter and the aggregates; it runs on every poll (session or not) and in user applies. The state
  of a key that drops out of use is forgotten (it restarts from its raw value). Non-finite samples
  leave the state alone (the engine treats a missing reading as "run at maximum"). The smoothed
  values are published as **`controlTemperatures`** (`[key: °C]`) and
  **`controlTemperature(for:)`** (falls back to the raw reading for other keys); `sensorReadings`
  stays raw (filtered). Alerts and the emergency latch use the raw values (never delayed).
- **Stabilizer** (`FanTargetStabilizer`, Core, pure state machine per fan): automatic (`nil`)
  passes through and drops the fan's state; the first manual target after automatic is used as-is;
  the **emergency override bypasses** it (straight to max); **explicit applies** (`applyProfile`,
  `setFanRPM`, `setFanControlMode`, `setFanCurve`, wake re-apply) **seed** it with their plan (no
  limits, the dwell restarts); restore / close write automatic directly. It is reset when a session
  opens or closes. When the emergency ends, the way back down is gradual (dwell + slew). The
  25 RPM throttle and the unsettled-fan rewrite still apply after it, so a failed write is retried
  with the held value.
- **Expected behaviour** (tests in `FanControlTuningTests`, Boost curve, 2 s polls): a hottest core
  flapping 58 ↔ 66 °C every poll at the 60 °C point (raw: > 100 direction changes in 10 min,
  > 900 RPM swing) settles in ≤ 2 writes and never reverses; heavy random noise (±4 °C per poll)
  still moves the target occasionally (13 reversals in 9.5 min with the test seed, ≥ 150 RPM
  steps, band ≤ 600 RPM); a step 55 → 80 °C reaches the curve value within ≈ 20 s and comes back
  down slowly after the load ends.

### Fan curves (multi-point, 2026-10-20)

`FanCurve` (Core) = `points: [Point(temperature: °C, rpm: Int)]`, evaluated with **monotone cubic
interpolation (PCHIP, Fritsch–Carlson)**: passes through every point, no overshoot, monotone where
the points are, linear for two points; flat before the first and after the last point; each
point's RPM and the result are clamped to the fan's `Mn…Mx`, so fan-agnostic curves may use
`FanCurve.fanMinimumRPM` (0, "the fan's minimum") and `fanMaximumRPM` (65 535, "its maximum").
Empty curve → max (fail loud); non-finite temperature → max. API: `rpm(at:for:)` /
`rpm(at:in:)`, `value(at:in:)` (unrounded, for charts), **`sample(count:rpmRange:temperatureDomain:)`**
(evenly spaced + the points themselves), `normalized()` (sorted, deduplicated, 0…130 °C),
`resolved(for:)` (RPMs clamped for one fan, what an editor shows), **validation**
`validationIssues(rpmRange:)` / `isValid(rpmRange:)` (≥ 2 points, finite, 0…130 °C, strictly
increasing, RPMs in range), `linear(startTemperature:maxTemperature:)`, `FanCurve.boost`, and the
**10 °C grid** helpers `gridTemperatures(from:through:step:)` (30…100), `resampled(at:rpmRange:rpmStep:)`
and `gridPresets` / `GridPreset` (`quiet`, `balanced`, `boost`, `fullSpeed`).

**How a curve is attached (least disruptive choice):** `FanControlMode` keeps exactly its three
cases, so the drop-ins' exhaustive `switch`es and `case .sensor(let key, _, _)` patterns compile
unchanged. The curve is a payload of the profile: `FanProfile.curves: [fanID: FanCurve]` (for fans
with a `modes` entry) and `FanProfile.defaultCurve` (for fans using `defaultMode`), both optional in
JSON. A `.sensor(sensorKey:startTemperature:maxTemperature:)` mode with a stored curve whose first /
last temperatures equal `startTemperature` / `maxTemperature` (±0.05 °C, `FanCurve.matches`) follows
that curve; otherwise — no curve, or a curve-unaware editor changed start / max — it follows the
old linear ramp (= the two-point curve). `FanProfile.curve(for:)` returns the effective curve
(`nil` for non-sensor or degenerate modes); `setCurve(_:sensorKey:forFan:)` sets mode + curve
consistently (`forFan: nil` = default); `removeStaleCurves()`; `resolved(for:)` materializes curves
along with modes. `FanControlEngine.plan` and the new `FanControlEngine.targetRPM(for: profile, fan:,
sensorTemperature:policy:)` honour curves; the old `targetRPM(for: mode, …)` is the linear ramp.
`FanControlManager.setFanCurve(fanIndex:sensorKey:curve:)` is the curve counterpart of
`setFanControlMode` (which drops the edited fan's curve). A new `.curve` enum case was rejected
because it would break every exhaustive switch in the drop-ins.

**In the drop-in UI (2026-10-20):** `FanCurveView` (widget details, Profiles tab overview) draws
`profile.curve(for: fan)?.sample(count: 48, rpmRange: fan.rpmRange, temperatureDomain:)` for
`.sensor` fans (so Boost shows its real 5-point curve) and `FanControlEngine.targetRPM(for: profile, …)`
for constant ones; the widget's per-fan target uses the same overload at
`FanControlManager.controlTemperature(for:)`, and the operating point is drawn at that smoothed
temperature. Custom 1 / 2 edit curves in `FanCurveEditorView` (FanControlCurveEditorView.swift): points
on the 10 °C grid (`FanCurve.gridTemperatures()`, 30…100 °C; loaded off-grid points such as Boost's
85 °C are kept), 50 RPM steps inside Mn…Mx, add / remove (≥ 2 points), `FanCurve.GridPreset` presets
resolved for the fan, live Swift Charts chart with drag; every edit goes through
`FanProfile.setCurve(_:sensorKey:forFan:)` on the draft (the curve is stored resolved for the fan), and
other modes drop the fan's curve. `validationIssues(rpmRange:)` errors (on the points with RPMs
clamped) disable Save / Apply; warnings cover falling speeds, never reaching Mx, and full speed only
at or above the emergency threshold. The editor writes the profile with `saveProfile` / `applyProfile`
(not `setFanCurve`, which edits the *active* profile into the programmatic "Custom").

### Temperature history (2026-10-20)

`FanControlManager.temperatureHistory` (`TemperatureHistory`, Kit, `Sendable` value, main actor)
holds recent **raw** (filtered) readings per key: `TemperatureHistory.defaultKeys` (`agg:cpu`,
`agg:gpu`, `TH0x`) plus the keys a view requests with `setTemperatureHistoryKeys(_:for:)` (`[]`
releases; unrequested buffers are dropped); `temperatureHistoryKeys` is the union. Appended on every
published poll. One ring buffer per key, `capacityPerKey` 1024 (≈ 34 min at 2 s; fewer minutes'
worth of samples at the slower battery / paused rates), at most 32 keys (≈ 0.5 MB worst case);
out-of-order and non-finite samples are ignored. Queries: `history(for:window:now:)` (oldest first),
`latest(for:)`, `range` / `minimum` / `maximum(for:window:now:)`.

**Temperature widget (drop-in, 2026-10-20):** `FanControlTemperatureWidgetView` (`NookWidget.temperature`)
charts the default keys over 1 / 5 (default) / 15 / 30 min (`FanControlTemperatureWidgetSettings`), so it
needs no `setTemperatureHistoryKeys` request. It downsamples to ≤ 180 bucket means per series for drawing
(min / max come from the raw samples) and breaks the line at gaps > 25 s. The history is not persisted
and starts empty at launch; while monitoring is paused (Nook hidden) nothing is recorded. Showing the
widget counts in `FanControlWidgetPresence` like the Fan Control widget (starts / un-pauses monitoring).

**Emergency override:** `AlertEvaluator.evaluateEmergency(sensors:policy:)` is evaluated on every
poll (session open or not) and its result is passed to `plan(..., isEmergency:)`. The latch turns
on when the hottest emergency sensor (`safetyPolicy.emergencySensorPrefixes`) reaches
`safetyPolicy.emergencyTemperature` (95 °C) and off only at
`emergencyTemperature - alertHysteresis` (90 °C), so fans do not flap between max and the profile
around the threshold. While it is on, every fan is planned at its `maxRPM`, even under the
Automatic profile. User-initiated applies (`applyProfile`, `setFanControlMode`, wake re-apply)
evaluate the same latch, so they cannot drop an active override inside the hysteresis band.
The latch is published as `emergencyOverrideActive` (main thread, like the other state); it is
reported even without a write session, but fans are only forced while a session is open (the
override never opens one). The latch resets when the SMC reader is reopened.

**Write throttle:** after the stabilizer (above), poll-driven writes skip a fan unless its mode changes (automatic and manual)
or its target moved by more than `FanControlManager.writeThresholdRPM` (25 RPM) from the last
successfully written value. A fan that we never forced is never "returned" to automatic by the
poll loop. User actions (`setFanRPM`, `setFanControlMode`, `applyProfile`, wake re-apply,
`restoreDefaultControl`) bypass the throttle. At most one poll-driven write batch is in flight.

**Partial failure of a write list** (pre-write review 2026-10-20): a list such as
`[F0Md ← 1, F0Tg ← rpm]` can fail after its first write (helper rejection, timeout), which would
leave the fan forced at a stale target (at idle `F0Tg` = 0, i.e. stopped). Two defences:
- `FanWriteStrategy.writes(for:)` reads each fan's hardware `F<i>Mn...F<i>Mx` at init and throws
  `.rpmOutOfRange` for a manual target outside it (± 1 RPM) *before* producing any write, so the
  helper's range check can no longer reject `F<i>Tg` after `F<i>Md` was accepted.
- On any failure the manager drops the baseline of every fan in the failed list, marks them
  "unsettled" (the next poll writes their planned state regardless of the throttle) and, if the
  session is still open, immediately writes `FanWriteStrategy.rollbackWrites(afterFailureOf:)`
  (`F<i>Md ← 0` for the fans that were being forced). If that rollback
  succeeds those fans get an `.automatic` baseline and are no longer unsettled. The original
  error is rethrown / stored in `lastError`. A timeout invalidates the connection, so the helper
  restores instead (the rollback is skipped because the session is gone).

**State drift (poll-time unsettled detection, 2026-10-20):** while a session is open every poll
also reads each fan's mode (`FanDiscovery.fanControlModes`) and compares it with the throttle
baseline (`UnsettledFanDetector.unsettledFans`, unit-tested). A fan is marked unsettled — and thus
rewritten by this very poll, bypassing the throttle — when it is
1. in manual mode with `F<i>Tg` below its hardware minimum − 50 RPM (stopped in manual; the
   post-wake state of first-write test 4), whatever was applied, including fans never written in
   the session (their planned state, usually `.automatic` → `F<i>Md ← 0`);
2. applied `.manual(rpm)` but read back as automatic, or with `F<i>Tg` more than 50 RPM
   (`UnsettledFanDetector.targetToleranceRPM`) away from `rpm`;
3. applied `.automatic` but read back as manual.
Only fans the strategy can control (`FanWriteStrategy.fans`, i.e. with `F<i>Md`) are checked. Each newly
flagged fan is logged at notice level (category `fancontrol-kit`):
`Unsettled fan(s) detected, rewriting: F0 manual=true Tg=0 applied=manual(rpm: 3000)`. Between
`NSWorkspace.willSleepNotification` and wake, polls neither flag nor write (the helper has handed
the fans back for the sleep); this suspension lapses on its own 30 s after the will-sleep
notification if no wake notification arrives.

**Apply generation (no poll can undo a user apply):** `applyProfile` / `setFanControlMode` /
`setFanRPM` first store (user profiles, `upsert`) and select the profile on main, *then* bump the
apply generation on the poller, then plan and write. Polls snapshot the active profile on main
and record the generation when they plan a batch; when that batch reaches the front of the
`WriteSerializer` it is dropped if a newer apply started (`ApplyGenerationGate.isStale`). Because
the selection changes before the bump and the poll queue is FIFO, every poll planned from the old
profile carries an old generation. If the apply's writes fail, the previous selection and the
previously stored version of the profile are restored (a newly created profile is removed).
`restoreDefaultControl`, `closeSMCSession` and the termination restore bump the generation too.
`restoreDefaultControl` writes automatic through the `WriteSerializer` *after* every batch already
queued and closes the session afterwards, and a batch planned before the bump is dropped, so no
stale manual target can be written after "Return to automatic". If no session is open but the SMC
reports a fan in manual mode (`FanDiscovery.fanControlModes`: e.g. the helper was killed mid-session
and could not restore, or another tool forced it), `restoreDefaultControl` opens a session just to
write automatic and closes it again (it is an explicit user action, so the install/approval flow
may run).

**Helper session rules:** the session is opened only by user actions (`setFanRPM`,
`setFanControlMode`, `applyProfile` with manual modes, `openSMCSession`); internally
`apply(_:force:allowOpeningSession:makeActive:)` takes `allowOpeningSession: true` only on those
paths. The wake re-apply passes `false` and does nothing if the session is closed, so it can never
start the install/approval flow. Applying a profile with manual modes while monitoring is stopped
calls `startMonitoring()` first (sensor-based modes, the emergency override and the throttle
baseline depend on polling); the drop-in UI disables Apply while the feature switch is off.
`openSMCSession` (like `startMonitoring`) registers the termination/wake observers (idempotent),
so a session opened without monitoring is still restored on quit. The installation flow
follows design doc §3.3: first write → `installHelper()` → `SMAppService.register()`; if the
status is `.requiresApproval`, Login Items & Extensions is opened and `.helperNotInstalled` is thrown (show
`FanControlManager.helperApprovalInstructions`, since that error case carries no message).
`openSMCSession` checks `version()` against `FanControlHelperConstants.protocolVersion` and
re-registers a mismatched helper once.

`setFanControlMode` / `setFanRPM` edit the active profile: a user profile is updated in place;
if a built-in profile is active, its modes are copied into a user profile named "Custom"
(`FanControlManager.customProfileID`), which becomes active. In both cases the base is first
resolved for the discovered fans (`profile.resolved(for:)`, via `FanControlManager.profile(changing:…)`),
so the other fans keep their *effective* mode: changing Fan 1 while Constant High is active leaves
Fan 2 at 5000 RPM (before 2026-10-20 only `modes` was copied, which dropped a preset's
`defaultMode` and sent untouched fans back to automatic). "Custom" also carries the preset's
`defaultMode` for fans discovered later (`ProfileEditTests`). RPMs are validated against
`fan.rpmRange` (or `0...max` if `safetyPolicy.enforceHardwareMinimum` is false) and rejected with
`.rpmOutOfRange`.

**Nook hidden (§5.4):** `setMonitoringPaused(true)` slows polling to
`max(5 × pollingInterval, 10 s)` if a write session is open (sensor-based modes and the emergency
override keep working) or if `keepAlertsWhilePaused` is `true` (default; the high-temperature and
fan-anomaly alerts keep firing). Otherwise polling stops while paused.
The host drives the pause from its Nook visibility (`FanControlNookVisibility.nookVisibilityChanged(isVisible:)`,
PATCHES.md (b-2)); the widget's appear / disappear is only a fallback. Views that must show live
data whatever the Nook state (the settings pane) call `setLiveDataHold(true, for: <name>)` on appear
and `false` on disappear: while any hold exists the pause is not in effect (`isPauseInEffect ==
false`, normal polling) but `isMonitoringPaused` keeps the host's request, so releasing the last
hold returns to the paused rate without the view restoring anything (`MonitoringPauseState`,
`MonitoringPauseStateTests`). `isPauseInEffect` (new, read-only) is what the timer uses.

**Power-aware polling (§5.4 (a), 2026-10-20):** `PowerSourceMonitor` (the default
`PowerSourceProviding`) reads `IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo())`
(`kIOPSBatteryPowerValue` = on battery; AC, UPS, desktops and unreadable state = not on battery)
and observes changes with `IOPSNotificationCreateRunLoopSource` on the main run loop. The manager
mirrors it into `isOnBattery` and computes `effectivePollingInterval` with the pure
`PollingIntervalPolicy.effectiveInterval` (FanControlCore):
`slowPollingOnBattery && isOnBattery ? max(pollingInterval, batteryPollingInterval) : pollingInterval`,
clamped to 0.5...300 s. The timer is rescheduled whenever the effective interval changes (power
source switch, or any of the three settings). The paused low-frequency poll uses it too
(`PollingIntervalPolicy.pausedInterval`: `max(5 × effectivePollingInterval, 10 s)`, i.e. 50 s on
battery with the defaults). Tests inject a mock source (`init(powerSource:)`,
`PowerAwarePollingTests`, `PollingIntervalPolicyTests`).

**Other fan control apps (§5.2, 2026-10-20):** our helper has its own Mach service, so it does not
collide with FanFi's `com.fanfi.fanfi.smcwrite`, but two apps writing `F<n>Md` / `F<n>Tg` override
each other. `ConflictingControllerDetector` checks each `ConflictingController` (built in:
`.fanFi` = app `com.fanfi.fanfi`, helper label `com.fanfi.fanfi.smcwrite`): app running
(`NSRunningApplication.runningApplications(withBundleIdentifier:)`, terminated instances ignored)
and helper installed (`/Library/LaunchDaemons/<label>.plist` or
`/Library/PrivilegedHelperTools/<label>` exists). Probes are injectable
(`ConflictingControllerDetectorTests`). The manager publishes `conflictingControllerStatuses`
(everything found, including an installed helper whose app is not running) and
`conflictingControllers` (display names of the *running* apps, e.g. `["FanFi"]`; posts
`.fanControlConflictingControllersChanged`). It refreshes on `startMonitoring()`, on
`NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` for a known
bundle id (observers registered with the other system observers), at most every
`conflictCheckInterval` (60 s) from the poll timer, and on `refreshConflictingControllers()` (the
General tab calls it on appear). Detection only warns; the kit never blocks or changes writes
because of it.

**Sleep/wake** (revised 2026-10-20 after first-write test 4: across sleep the SMC resets `F<i>Tg`
to 0 but keeps `F<i>Md` = 1, so fans wake "manual, target 0" = stopped). Two layers; the helper is
the safety authority (`docs/helper.md` §5 「スリープ／復帰」: it hands forced fans back to the SMC
before sleep and re-applies the session's last targets at 0 / 1 / 3 s after wake on its own),
the manager applies the policy:
- `NSWorkspace.willSleepNotification`: nothing is written; pending wake attempts are cancelled and
  poll-driven writes are suspended until wake (see "State drift" above).
- `NSWorkspace.didWakeNotification` with a session open:
  - `reapplyProfileAfterWake == true` (default): the active profile is re-applied **immediately**
    and again at 2 s and 5 s (`FanControlManager.wakeReapplyDelays` = `[0, 2, 5]`), each with
    `force: true` (bypassing the throttle, idempotent) and `allowOpeningSession: false`. Only the
    last attempt records an error in `lastError` (the SMC may reject writes right at wake).
  - `reapplyProfileAfterWake == false`: the session is **closed immediately** (the helper hands
    the fans back); the user re-applies a profile to take control again.
  - a poll runs at once (and before each later attempt), so the unsettled detection also catches
    a stopped fan.
The flag is read when each attempt runs; `stopMonitoring()` and a new will-sleep cancel pending
attempts. Logged at notice level (category `fancontrol-kit`): `Woke with a session open:
re-applying the active profile at 0.0s, 2.0s, 5.0s` / `System will sleep; poll writes suspended …`.
The app must not add its own wake re-apply; it only mirrors its setting into this property (see
Settings below).

**Termination:** on `NSApplication.willTerminateNotification` (observers are registered on the
first `startMonitoring` or `openSMCSession`), all fans are set to automatic and the session is
closed (both through the `WriteSerializer`, after bumping the apply generation), waiting at most 2 s
on the main thread. Independently, the helper hands the fans back to the SMC when the client
connection goes away (`docs/helper.md` §4: `F<i>Md` to automatic; `F<i>Tg` is written back only for
fans whose `F<i>Md` the session never wrote, clamped into `Mn...Mx`).

**Temperature sample filter** (`FanControlCore.TemperatureSampleFilter`): on Mac14,9 the `Tp*`
(P-core) keys read either their real value or a fixed near-zero pattern (`0.00 / 6.70 / 8.43`,
`0.00 / 4.63 / 5.32`, `0.00 / 6.03 / 7.43`), alternating per read or for a whole power-gated
cluster. Every sensor batch (discovery, each poll, and the fresh read of a user apply) is filtered
on the poll queue before alerts, `plan` and publishing, so `sensorReadings` (UI) and the planned
targets see the same values. For keys starting with `Tp`/`Te`/`Tg`/`TC`, a finite sample below
10 °C is rejected and replaced by the key's last accepted value for up to 5 consecutive rejections,
then by the hottest accepted sample of the same prefix group in that batch, and passed through raw
only if the whole group is implausible. Substitutes are always hotter than the rejected sample, so
the emergency maximum can only rise and a sensor-linked fan never runs slower than without the
filter; non-finite values still pass through (fail hot). Sudden drops above the floor are not
rejected (real core temperatures fall 10-20 °C per poll when load stops). The keys substituted in
the latest poll are published as `substitutedSensorKeys` (e.g. to dim them). The filter is reset
when sensors are rediscovered (SMC reader reopened). Defaults are the static `default*`
constants; the manager does not expose the configuration.

**Aggregate sensors** (`FanControlCore.SensorAggregator`): Apple Silicon has no single CPU
temperature key (Mac14,9: ~20 `Tp*`, `Te*`, `Tg*` keys), so a sensor-linked profile bound to one
key follows one core. After filtering, every batch (discovery, each poll, the fresh read of a user
apply) gets synthetic `SensorReading`s appended, computed from the **filtered** values, so
`sensorReadings` and `plan` see the same aggregates. Each value is the maximum of the finite member
readings; an aggregate without any finite member is omitted (a machine without such keys simply
lacks it, and a profile bound to a missing aggregate fails hot like any missing sensor).
`sensorType` is the existing case `.greatest` (no new `SensorType` case, so persisted data and
exhaustive switches are unaffected); `SensorReading.isAggregate` / `SensorAggregator.isAggregate(_:)`
test for the `agg:` id prefix, which cannot collide with a 4-character SMC key.

| id | name | members | overview |
|---|---|---|---|
| `agg:cpu` | CPU (max) | `Tp` `Te` `TC` | yes |
| `agg:cpu.p` | CPU Performance Cores (max) | `Tp` | no |
| `agg:cpu.e` | CPU Efficiency Cores (max) | `Te` | no |
| `agg:gpu` | GPU (max) | `Tg` | yes |

Every member prefix is in `SafetyPolicy.defaultEmergencySensorPrefixes`, so `TG*` (battery-area
`ioft` keys on Mac14,9) is excluded exactly as for the emergency check. The table is the single
static `SensorAggregator.definitions` (the per-architecture `definitions(appleSilicon:)` was removed
2026-10-20); the manager uses `FanControlPlatform.sensorAggregateDefinitions` (also
`manager.sensorAggregateDefinitions`; both kept for the drop-ins).
`FanControlEngine.plan` needs no change: `.sensor(sensorKey: "agg:cpu", …)` is looked up by id.
Aggregate ids do not match any emergency prefix, so the emergency maximum and alerts are unchanged
(an aggregate's value is always one member's value). `SensorCatalog.displayName(for:)` returns the
aggregate name for `agg:` ids. `SensorAggregator.overview(_:definitions:)` keeps the overview
aggregates (CPU, GPU) plus the readings they do not cover; the widget uses it for its default
"3 hottest" list so a core is not listed twice. `fanfi-probe` prints the aggregates of the filtered
samples after each temperature readout.

**Non-thermal / unreliable keys** (`SensorCatalog.isExcludedFromRanking(_:)`, also
`SensorReading.isExcludedFromRanking`): keys that must not take part in automatic "hottest"
selection or ranking. The table is data: `SensorCatalog.rankingExcludedPrefixes` = `["Tf"]` (on
every machine; meaning unknown, on Mac14,9 `Tf06`/`Tf16`/`Tf26` hold constant 79-105 values and
other `Tf*` keys are constant, negative or ≈ 0) and `SensorCatalog.rankingExcludedKeys` = the keys
that read a constant on Mac14,9 (`TH1a`, `TH1b`, `TVMD`, `Ta0C/D/G/H/K/L/V`, `Tz11`…`Tz18`,
`Tz1j`); aggregate ids are never excluded. Discovery is unchanged (the keys are still read,
published in `sensorReadings` and selectable explicitly). `SensorAggregator.overview` drops them,
`SensorAggregator.hottestOverview(_:definitions:limit:)` (the widget's automatic "3 hottest"
selection: the `limit` hottest finite overview readings, ties in overview order) therefore never
picks them, and `FanControlManager.hottestSensor`'s fallback (no emergency-prefix sensor) skips
them. No excluded key matches an emergency prefix or aggregate member, so emergency handling,
alerts and aggregates are unchanged (tested in `SensorRankingTests`).

**Safety policy:** `safetyPolicy` starts as `FanControlPlatform.defaultSafetyPolicy` =
`SafetyPolicy.default`, whose emergency prefixes are `SafetyPolicy.defaultEmergencySensorPrefixes`
= `Tp/Te/TC/Tg` (`TG*` excluded: on Mac14,9 those are `ioft` battery-area sensors at ~33 °C; the
GPU is `Tg*`). Since Intel was dropped (2026-10-20) there is one list; `default(appleSilicon:)` /
`defaultEmergencySensorPrefixes(appleSilicon:)` were removed (no caller outside the package).
`SafetyPolicy`'s stored properties and Codable keys are unchanged; a persisted policy that still
contains `TG` decodes as stored.

**User-set thresholds (design doc §5.6, 2026-10-20):** `SafetyThresholds` (Core, Codable,
missing keys decode to the defaults) holds the three adjustable values — `highTemperatureAlert`
(default 90 °C), `emergencyTemperature` (95 °C), `alertHysteresis` (5 °C) — and
`SafetyPolicy.thresholds` reads / writes exactly those three fields (`emergencySensorPrefixes` and
`enforceHardwareMinimum` are kept). `ThresholdBounds` (pure) clamps them: alert `alertRange` =
70…100 °C, emergency `emergencyRange(forAlert:)` = (alert + 1)…105 °C, hysteresis
`hysteresisRange` = 1…10 °C; non-finite values become the default. `settingHighTemperatureAlert` /
`settingEmergencyTemperature` / `settingAlertHysteresis(_:in:)` change one value and re-clamp the
others (raising the alert pushes the emergency threshold to at least alert + 1; lowering the
emergency threshold, allowed down to `emergencyOverallRange.lowerBound` = 71 °C, pulls the alert to
at most emergency − 1). `SafetyPolicy.clamped()` clamps a whole policy.
`FanControlManager.applySafetyThresholds(_:)` copies clamped thresholds into `safetyPolicy` (only
on a change); the next poll evaluates the alert and the emergency latch against them. The hysteresis
applies to both the alert and the emergency latch.

**Sensor names (design doc §5.7, 2026-10-20):** `SensorCatalog.nameComponents(for:)` returns
`SensorNameComponents` (`labelKey`, `suffix`, `isFallback`) so a UI can localize the label and
append the suffix verbatim (`name(label:)`): exact names (`TB1T` → "Battery" + "1", `TH0x` → "NAND
(SSD)"), prefix names (`Tp09` → "CPU Performance Core" + "09"), aggregates (`agg:cpu` → "CPU (max)"),
fallback (`"Sensor"` + key, `isFallback`). Label keys: `SensorCatalog.labelKeys` ("CPU Performance
Core", "CPU Efficiency Core", "GPU", "Battery", "Airflow Left", "Airflow Right", "NAND (SSD)", "Palm
Rest", "Wireless", "Memory", "Storage", "Sensor"). `displayName(for:)` (= `englishName`) and
`knownNames` keep their English output unchanged (tested for all 259 `T*` keys of the Mac14,9 dump);
it stays the value of `SensorReading.name`. The drop-in `FanControlSensorNames.localized(_:)`
(`FanControlSensorsTabView.swift`) localizes through Localizable.strings.

**Platform check:** `FanControlPlatform.isSupported` (`FanControlHost.isAppleSilicon`, `sysctl
hw.optional.arm64`, true on Apple Silicon also under Rosetta). `FanControlManager.init` logs an
error on unsupported hardware, and `requireSupported()` runs before every SMC open, so polls,
refreshes and applies fail with `FanControlError.unsupportedPlatform` (published to `lastError`).
A fan that has `F<i>Tg` but no `F<i>Md` is not controllable: it is listed in
`FanWriteStrategy.fansMissingModeKey` and writes to it fail with `FanControlError.fanModeKeyMissing`
(no `FS! ` / target-only fallback).

The persisted active profile is **not** re-applied automatically at launch (design doc §5.5 is
still open): the session stays closed until the user acts.

## Persistence

`ProfileStore` (the fixed seven profiles, additional programmatic profiles and `activeProfileID`,
`schemaVersion` 3 since the curves / Max preset) is stored as JSON (`ProfileStore.encodeJSON`) in `UserDefaults` under
**`fanControl.profileStore`** (`FanControlManager.profileStoreDefaultsKey`) on every change. The
(Not a `SettingsStore` key: the kit owns this one and writes it as JSON *Data*.) See "Profiles" below.
`pollingInterval`, `slowPollingOnBattery`, `batteryPollingInterval`, `reapplyProfileAfterWake`,
`safetyPolicy` and `tuning` are not persisted by the kit; the app's settings layer owns them
(`FanControlGeneralSettings.slowPollingOnBattery`, default `true`, decoded with `decodeIfPresent`
so older stored settings keep working).

## Profiles (fixed set of seven, 2026-10-20)

The app offers exactly seven profiles (`FanProfile.fixedProfileIDs`, `ProfileStore.fixedProfiles`);
users cannot create or delete profiles. Ids are fixed UUIDs (`FanProfile.BuiltInID`):

| Profile | id `6F1A0000-0000-4000-8000-…` | Content (`FanProfile.Preset`, provisional values) | Editable |
|---|---|---|---|
| Automatic | `…000000000001` | SMC default (no override) | no |
| Constant Quiet (定速・静音) | `…000000000011` | every fan 3000 RPM (`quietRPM`) | no |
| Constant High (定速・強) | `…000000000012` | every fan 5000 RPM (`highRPM`) | no |
| Boost (ブースト) | `…000000000013` | every fan `.sensor(agg:cpu, 50 → 85 °C)` + `defaultCurve` `FanCurve.boost`: **50 °C min, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800 (max)** (`boostCurve`) | no |
| Max (最大) | `…000000000014` | every fan 6800 RPM (`maxRPM`; clamped to each fan's max) | no |
| Custom 1 (カスタム 1) | `…000000000021` | default = copy of Boost (curve included) | per-fan modes + curves + name |
| Custom 2 (カスタム 2) | `…000000000022` | default = every fan 3500 RPM (`custom2RPM`) | per-fan modes + curves + name |

Constant RPMs are clamped to each fan's `Mn…Mx` when applied (Mac14,9: 2317…6800). The emergency
override (`SafetyPolicy`) still forces every fan to max when hot, whatever the profile.

- **Boost curve (user decision 2026-10-20, replaces the linear 70 → 95 °C ramp):** full speed
  *early*, well before 100 °C: 50 °C min, 60 °C 3500, 70 °C 5200, 80 °C 6400, 85 °C 6800 (10 °C
  below the 95 °C emergency threshold), monotone-cubic between the points. **Note:** `agg:cpu` is
  the hottest core, which idles at ≈ 72–78 °C on Mac14,9, so Boost runs ≈ 5500–6100 RPM at idle
  (72.7 °C → ≈ 5570 RPM) — intended as a "cool and loud" preset; the smoothing / stabilizer keep it
  from hunting. The preset is read-only: copy into Custom 1 / 2 to retune. Custom 1's factory
  default (`defaultCustom1()`, also restored by `reset`) is Boost with its curve.
  `Preset.boostStartTemperature` / `boostMaxTemperature` (50 / 85 °C) are the curve's ends and the
  editors' default for a newly sensor-linked fan.
- **Max:** every fan at `Preset.maxRPM` (6800 = Mac14,9's `Mx`; clamped). A separate id from the
  legacy `BuiltInID.maximum` (still used by `availableProfiles`).
- **Curves in custom slots:** `ProfileStore` keeps a matching `FanCurve` for every `.sensor` mode of
  a custom slot (`withCurves`, applied by `upsert` and normalization): a mode without one gets the
  equivalent two-point linear curve, a curve whose ends no longer match its mode is replaced. So a
  curve-unaware editor that moves start / max gets the linear ramp it shows.

- **"Every fan" presets:** `FanProfile.defaultMode` (new, optional, Codable-compatible) is the mode
  of every fan without an entry in `modes`; `mode(for:)` = `modes[id] ?? defaultMode ?? .automatic`.
  `FanControlEngine.plan` and the manager's poll use `mode(for:)`, so a stored preset works for any
  fan count. `FanControlManager.apply` decides whether it needs the session from `modes` alone, so
  the UI passes **`profile.resolved(for: fans)`** (explicit per-fan modes) to `applyProfile`
  (`FanControlProfiles.apply` in the drop-in UI). The manager is unchanged.
- **Presets are read-only and regenerated from code** on every decode/assignment, so a changed
  preset value reaches existing installs. Only the custom slots are persisted as edited.
- **API:** `upsert` (custom slot: modes / `defaultMode` / curves / name; presets ignored), `rename(id:to:)`
  (custom slots; empty name → default name), `reset(id:)` (custom slot → factory default; active
  selection kept), `isModified(id:fans:)` (compares effective per-fan modes, effective curves + name), `delete(id:)`
  (no-op for the seven). `profiles` / `activeProfileID` are normalized in `didSet`; an active id that
  names no stored profile becomes `nil` (= Automatic).
- **Additional (programmatic) profiles:** the manager itself stores profiles outside the seven —
  `setFanRPM` / `setFanControlMode` create "Custom" (`customProfileID`), and tools such as
  HelperSmokeApp apply their own (`"Smoke sensor-linked"`). `ProfileStore` keeps them after the seven
  (`additionalProfiles`; `upsert` adds, `delete` removes) so such a profile stays active across polls,
  wake re-apply and relaunch. The app UI never shows them (it reads `fixedProfiles`, not
  `availableProfiles`, which still lists the legacy Silent / Maximum built-ins for compatibility).
- **Migration** (JSON without `schemaVersion`, i.e. written before the fixed set): Silent / Maximum
  are dropped; the first user profile with a sensor-linked mode is folded into Custom 1 (its
  `modes`; name stays "Custom 1"); every other user profile is dropped (e.g. the smoke app's
  constant "Custom"). Active selection: folded profile → Custom 1, Automatic → Automatic, anything
  else → `nil` (Automatic). Nothing is re-applied by the migration. The migrated store is written
  back on the next change. Note: DynamicNotchApp and HelperSmokeApp share the bundle id and thus
  this store.
- **Migration schema 2 → 3** (curves / Max, 2026-10-20): the Max preset appears (presets come from
  code); a stored Custom 1 that still equals the old factory default (name "Custom 1",
  `.sensor(agg:cpu, 70 → 95 °C)` as `defaultMode` and in every `modes` entry, no curves) becomes the
  new default (Boost curve); any other slot keeps its values and gets two-point linear curves for
  its `.sensor` modes (behaviour unchanged). Tested in `ProfileStoreCurveTests`.

## Settings owned by the app

The kit does not depend on the app's settings store (`SettingsStore`, drop-in `FanControlSettingsStorage.swift`; sindresorhus `Defaults` until 2026-10-20). The app copies its settings into these
settable properties (main thread), at launch before `startMonitoring()` and on every change. In
the DynamicNotch drop-in UI this is `FanControlAlertCoordinator.syncManagerSettings()`, driven by
`SettingsStore.updates(.fanControlGeneralSettings)` and `SettingsStore.updates(.fanControlThresholdSettings)`.

The temperature thresholds have their own settings key, **`fanControlThresholdSettings`**
(`FanControlThresholdSettings` in `FanControlGeneralTabView.swift`, not part of
`FanControlGeneralSettings`): `highTemperatureAlert` 90, `emergencyTemperature` 95,
`alertHysteresis` 5 (°C; missing keys decode to these). The General tab edits them with three
1 °C steppers ("Temperature Thresholds": "High Temperature Alert", "Emergency (All Fans
Maximum)", "Hysteresis", within `ThresholdBounds`) and "Reset to Defaults";
`syncManagerSettings()` calls `manager.applySafetyThresholds(_:)` and, while monitoring, polls once
so the alert / emergency state follows immediately.

| Property | Default | Effect |
|---|---|---|
| `pollingInterval` | 2.0 s | timer interval (clamped to 0.5...300 s); a change of `effectivePollingInterval` reschedules the timer |
| `slowPollingOnBattery` | `true` | on battery poll every `max(pollingInterval, batteryPollingInterval)` (the coordinator mirrors `FanControlGeneralSettings.slowPollingOnBattery`, General tab toggle "Slow Down Polling on Battery (10 s)") |
| `batteryPollingInterval` | 10 s | battery interval used while `slowPollingOnBattery` (not exposed in the UI) |
| `reapplyProfileAfterWake` | `true` | `true`: re-apply on wake at 0 / 2 / 5 s; `false`: close an open session immediately on wake |
| `keepAlertsWhilePaused` | `true` | keep a slow poll while paused without a session (the drop-in coordinator mirrors `highTemperatureAlertEnabled \|\| fanAnomalyAlertEnabled`) |
| `safetyPolicy` | `FanControlPlatform.defaultSafetyPolicy` | thresholds; taken per poll. An app that persists its own policy should start from `SafetyPolicy.default`. The drop-in coordinator mirrors only the thresholds, via `applySafetyThresholds(_:)` from `FanControlThresholdSettings` (below) |
| `clientTeamID` | `FanControlHelperConstants.teamIdentifierPlaceholder` | Team ID in the helper code-signing requirement checked on every new helper connection (forwards to `HelperClient.clientTeamID`); set before the first helper call unless the constant was replaced; ignored in manual-install mode (below) |

`HelperClient.callTimeout` (default 8 s, `<= 0` disables) is set on the `HelperClient` passed to
`FanControlManager.init` (the shared instance uses the default).

**Team ID (3 places, all the same value):** `Support/Helper-Info.plist` `FanControlClientTeamID`
(read by the helper to check the *app*), `FanControlHelperConstants.teamIdentifierPlaceholder`
(fallback for the helper and default of `clientTeamID`), and optionally
`FanControlManager.shared.clientTeamID` at launch (what the *app* requires of the helper:
`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)` =
`anchor apple generic and identifier "com.example.dynamicnotch.DynamicNotch.fanfi" and certificate leaf[subject.OU] = "<teamID>"`).
Replacing the constant makes the runtime assignment unnecessary.

## Helper requirement and install status (manual-install / personal mode)

Ad-hoc signed builds without a Team ID cannot use `SMAppService` + the `anchor apple generic … leaf[subject.OU]`
requirements, so the helper can instead be installed by `sudo Support/manual-install/install.sh <App.app>`
(docs/helper.md §6). The SMAppService path is unchanged for Team-ID builds.

**`HelperClient` requirement selection** (per new connection,
`FanControlHelperConstants.helperRequirementMode(appTeamID:manualInstallDetected:)`):

| Condition | Requirement on the helper |
|---|---|
| the app's own signature has a Team ID (`SecCodeCopySelf` → `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier`) **and** no manual-install file exists | `helperCodeSigningRequirement(teamID: clientTeamID)` (as before) |
| the app has no Team ID (ad-hoc) **or** a manual-install file exists | `manualModeHelperRequirement(cdhash:)` = `identifier "com.example.dynamicnotch.DynamicNotch.fanfi" and cdhash H"<cdhash>"` |

In manual mode the cdhash is read at connect time from `/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi`
(`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` + `kSecCodeInfoUnique`), after checking that the file and its
directory are owned by root and not group/other-writable. Only root can have put that file there, so it is an acceptable trust
anchor (root could subvert the app anyway); the check guards against a different binary answering on the Mach name. If the
cdhash cannot be read, the call throws `.helperConnectionFailed(…)` without connecting. Transport errors on a manual-mode
connection get a hint appended ("re-run sudo install.sh <app>"): the usual cause is a rebuilt app whose new cdhash the helper
does not accept. `clientTeamID` is ignored in manual mode. `HelperClient.currentRequirementMode()`,
`HelperInstaller.installedManualHelperCDHash()` and `HelperInstaller.appTeamIdentifier` expose the decision for diagnostics
(the smoke app shows them).

**`HelperInstaller`** checks the manual files first (`init(plistName:fileExists:)`; the probe is injectable for tests):

| `/Library/LaunchDaemons/<label>.plist` | `/Library/PrivilegedHelperTools/<label>` | `status()` | `register()` | `unregister()` |
|---|---|---|---|---|
| present | present | `.installedManually` | no-op, returns `.installedManually` | throws `.helperConnectionFailed` ("use sudo uninstall.sh") |
| present, but its `FANCONTROL_CLIENT_REQUIREMENT` pins another cdhash than the running app's | present | `.installedManuallyMismatch(pinnedCDHash:appCDHash:)` | no-op, returns the same | throws (as above) |
| exactly one present | | `.unknown("manual installation incomplete (… is missing); re-run …")` | throws | throws |
| absent | absent | `SMAppService` status (as before) | `SMAppService.register()` | `SMAppService.unregister()` |

`FanControlManager` treats `.installedManually` like `.enabled`: `openSMCSession()` does not call `installHelper()`, and
`installHelper()` returns. A protocol-version mismatch with a manually installed helper throws
`.helperRejected(code: -1, …"Re-run sudo install.sh…")` instead of unregistering/re-registering. UIs must handle the new case
(`FanControlGeneralTabView`: 「手動インストール済み（個人利用モード）」 plus a hint naming `install.sh` / `uninstall.sh`).

## Helper connection lifecycle (when the app talks to the helper, rejection, backoff)

**Read-only monitoring never touches the helper.** Polling, discovery, alerts, `refreshNow()`, `refreshHelperStatus()`
and `HelperInstaller.status()` use only the in-process SMC reader and file / `SMAppService` reads. `HelperClient`
connects lazily on the first call, and the manager calls it only for:

| Trigger | Calls |
|---|---|
| user: apply a profile with a manual mode (widget profile list, Profiles tab), `setFanRPM` / `setFanControlMode` | `openSMCSession()` → `version()`, `openSession()`, then `write` |
| user: "Restore Automatic Control" / turning the feature off (`restoreDefaultControl()`) | with a session: writes + `closeSession()`; without one **only if the SMC reports a fan in manual mode** (orphan recovery) → `openSMCSession()` |
| user: "Check Again" (`retryHelperConnection()`) | `version()` once (read-only probe) |
| open session only: poll writes, wake re-apply, ⌘Q restore, `closeSMCSession()` | `write`, `closeSession()` |

Note the orphan recovery also fires while **another** client (FanFi, the smoke app) holds the helper session and has a fan
in manual mode; with this app refused by the helper it now fails fast with the rejection instead of connecting.

The 2026-10-20 11:20–11:23 log (DynamicNotch pid 35111, helper pinned to the smoke app) matches this: each of the five
`Accepted connection N` / `Connection N … invalidated` pairs followed an AppKit `sendAction:` (a click) in DynamicNotch by
1–2 s (the requirement build includes `SecStaticCodeCheckValidity` of the helper), and nothing connected between clicks.
The repeated clicks were most likely profile selections in the notch widget, whose `try?` hides the error, so nothing
seemed to happen and the user clicked again. Each click opened a fresh peer connection because the client only sees
`NSXPCConnectionInterrupted` (the helper accepts, evaluates its client requirement on the first message and invalidates
the peer), and an interrupted `NSXPCConnection` silently reconnects on the next message.

**Retry policy** (`HelperConnectionGate`, pure, `HelperConnectionGateTests`; one gate per `HelperClient`):

1. *Pin pre-check (manual mode, no connection).* Before creating a connection the client reads the root-owned plist
   (0644, `ManualHelperSigning.pinnedClientRequirement()`) and compares the pinned client cdhash with its own
   (`SecCodeCopySelf` → `kSecCodeInfoUnique`), `FanControlHelperConstants.manualClientPinCheck`. A mismatch is a rejection
   `.clientNotPinned(pinnedCDHash:appCDHash:)`; an undecidable check (plist unreadable, unsigned app) falls through to (2).
   `HelperInstaller.status()` runs the same check and reports `.installedManuallyMismatch`.
2. *Runtime classification* of the proxy error (`HelperConnectionGate.classify`):
   `NSXPCConnectionCodeSigningRequirementFailure` (4102, the helper fails **our** requirement) → rejection
   `.helperSignatureMismatch` at once; `NSXPCConnectionInterrupted` (4097) on a peer connection that has not replied yet →
   `.droppedWithoutReply`, and **two in a row** → rejection `.droppedByHelper` (one alone could be a helper crash on the first
   message); everything else (timeout, 4099 invalid = helper not running / not registered, interruption after replies) → transient.
3. *Rejection is sticky*: `connectionState = .rejected(reason:)`, the connection is invalidated, and every later call throws
   `FanControlError.helperConnectionRejected(…)` **without connecting** until (a) `HelperClient.resetRejection()` —
   `FanControlManager.retryHelperConnection()`, the "Check Again" button —, (b) an app relaunch, or (c) a change of the
   install fingerprint (size + mtime of the plist and the helper binary; `install.sh` rewrites both, so re-running it clears the
   rejection by itself). The interruption / invalidation handlers keep `.rejected` instead of overwriting it.
4. *Transient failures back off*: after the n-th consecutive failure calls fail fast for `min(2 s × 2^(n−1), 300 s)` with
   `.helperConnectionFailed("not retrying for another N s …")`; any reply resets the counters (and the drop streak).

`HelperConnectionState` is `.disconnected` / `.connecting` / `.connected` / `.error(String)` (transient) /
`.rejected(reason: HelperRejectionReason)`. `HelperRejectionReason.description` is English and names the remedy
("the installed helper is pinned to a different build of the app; re-run sudo install.sh <this app>"); the UI shows its own
localized text (`fanControlRejectionHelp(_:)` in `FanControlSettingsView.swift`, en/ja strings).

## Errors

Failures of async actions are rethrown **and** stored in `lastError` (main thread). Poll-loop
failures (SMC open, failed fan discovery, poll-driven writes) are stored too; `lastError` is only
re-published when the value changes, so a persistent failure does not churn observers every poll.
A failed fan discovery leaves `fans` empty and is retried on later polls while no fan is known.
The manager never clears `lastError` itself; call `clearLastError()` when the user dismisses it.
`installHelper()` throws `.helperNotInstalled` while the daemon awaits approval (after opening
Login Items); `helperStatus` is already `.requiresApproval` at that point, so UIs can show
approval guidance (`helperApprovalInstructions`, English) instead of the generic message.
`.helperConnectionRejected(String)` means the helper refuses this app (see "Helper connection lifecycle"); it is not
retried automatically, and UIs show the remedy (re-run `sudo install.sh <this app>`, then "Check Again").

## Notifications (object: the manager, posted on main)

| Name | When | userInfo |
|---|---|---|
| `.fanControlHighTemperatureChanged` | `highTempAlertActive` changed | `"active": Bool` |
| `.fanControlFanAnomalyChanged` | `anomalousFanIDs` changed | `"fanIDs": Set<Int>` |
| `.fanControlDidUpdate` | after every published poll | none |
| `.fanControlConflictingControllersChanged` | `conflictingControllers` changed | `"names": [String]` |

These are the hooks for Live Activities (design doc §4.2).

## Helper-side checks (see `docs/helper.md` §4)

The helper is the safety authority. Independently of the kit's planning it rejects writes to
keys outside the allowlist (`F<n>Tg`, `F<n>Md`; `FS! `, `F<n>Mn` and `Ftst` are not allowed), keys
whose SMC attributes lack the write bit `0x40`, payloads that are not 1 to 32 bytes or do not match
the key's `dataSize`, `F<n>Md` values other than 0/1, `F<n>Tg` values outside the hardware
`F<n>Mn...F<n>Mx` read at session open (with a ±1 RPM rounding tolerance), and any other key
(`FanControlXPC.HelperWritePolicy.validate`). `safetyPolicy.enforceHardwareMinimum = false`
therefore only affects client planning; sub-minimum targets are refused by `FanWriteStrategy`
(`.rpmOutOfRange`, nothing written) and by the helper.

## Write sequences (`FanWriteStrategy`)

Apple Silicon only (Intel dropped 2026-10-20). A fan is controllable when both `F<i>Tg` and
`F<i>Md` have key info; their types/sizes come from `keyInfo`.

| Fan | Manual | Automatic |
|---|---|---|
| `F<i>Md` exists (`fans`) | `F<i>Md ← 1`, then `F<i>Tg ← rpm` (`flt `) | `F<i>Md ← 0` |
| `F<i>Tg` but no `F<i>Md` (`fansMissingModeKey`) | throws `.fanModeKeyMissing(fan:)` | throws `.fanModeKeyMissing(fan:)` |
| no `F<i>Tg` | throws `.keyNotFound("F<i>Tg")` | throws `.keyNotFound("F<i>Tg")` |

The former `.forceBits` (Intel `FS! ` bitmask) and `.targetOnly` styles and the `ControlStyle`
enum were removed. A list that contains any failing fan throws before producing a write.

Mac14,9 / macOS 26: `FS! ` and `Ftst` are absent, both fans have `F<i>Md`; `F<i>Md` is `ui8 `
(1 byte, `01` / `00`) and `F<i>Tg` little-endian `flt ` (2317 RPM = `00 d0 10 45`, the same bytes
the read path decodes from `F<i>Mn`). `F<i>Mn` is never written. Manual targets outside the
fan's `F<i>Mn...F<i>Mx` throw `.rpmOutOfRange` before any write is produced (`FanWriteInfo.rpmLimits`).
`rollbackWrites(afterFailureOf:)` returns the writes that hand the fans of a failed manual list
back to automatic.

Mode writes always come before target writes.

## Not verifiable without a Mac

The code was first written on Linux against SDK-signature stubs. It now builds against the real
macOS SDK (macOS 26 SDK, Xcode 26.6, Swift 6.3.3) in the Swift 6 language mode (tools 6.0,
deployment target macOS 26) with 0 diagnostics (`SMCConnection` uses `mach_task_self_` because the
`mach_task_self()` macro is not importable). This does not prove
runtime behaviour. Still to verify on hardware:

- `SMAppService` register/approval flow, including the error `register()` throws while approval is pending.
- The privileged XPC connection and both code-signing requirements (helper checks the app, the
  app checks the helper via `setCodeSigningRequirement`; needs real Team ID signing).
- Whether 8 s (`callTimeout`) is a good bound for a helper reply on a loaded machine.
- Whether Apple Silicon models accept `F<i>Md`/`F<i>Tg` writes as is, or need an extra unlock key
  (`Ftst` is reported for some M1 models; it is not in the helper allowlist). On Mac14,9 (M2 Pro) /
  macOS 26 `Ftst` does not exist; `F<i>Md` (`ui8 `, attr `0xd0`) and `F<i>Tg` (`flt `, attr `0xd4`)
  carry the `0x40` write bit. No write has been attempted.

SMC reads (the `SMCClient` path behind `FanControlManager` polling and `exportSMCDump()`) are verified
on Mac14,9 / macOS 26 with the read-only `fanfi-probe` executable (`swift run fanfi-probe`,
`--dump`, `--watch N`); results and per-model findings are in `docs/integration.md` §6 Phase 1.
- Whether the default thresholds (alert 90 °C, emergency 95 °C, hysteresis 5 °C, sensor
  prefixes `Tp/Te/TC/Tg`) suit each Apple Silicon model (design doc §5.6). The three temperatures
  are user-adjustable in the General tab since 2026-10-20; the prefixes are not.
- Sleep/wake: on Mac14,9 the SMC resets `F<i>Tg` to 0 and keeps `F<i>Md` = 1 across sleep
  (first-write test 4). The immediate wake re-apply, the helper's own sleep hand-back / wake
  recovery and the unsettled detection are implemented but not yet re-tested on hardware
  (integration.md §6 Phase 5).
- Whether `@Observable` property `didSet` observers fire as expected (they are used for the notifications).
- Battery impact of the 2 s default interval; whether the 2 s termination wait is enough.
