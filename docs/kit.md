# FanControlKit (app-side layer)

`FanControlKit` is what DynamicNotch links. It depends on `FanControlCore` (models, codec, engine),
`FanControlSMC` (in-process, read-only IOKit SMC access) and `FanControlXPC` (helper protocol).
Everything except `FanWriteStrategy`, `FanTarget`, `ApplyGenerationGate` (internal),
`HelperInstallStatus`, `HelperConnectionState`, `FanControlKitInfo`, `FanControlPlatform` and the
`Notification.Name` constants is wrapped in `#if os(macOS)`.

| File | Contents |
|---|---|
| `FanControlManager.swift` | `@Observable` singleton `FanControlManager.shared` (design doc §3.1) |
| `HelperInstaller.swift` | `SMAppService.daemon(plistName:)` wrapper, `HelperInstallStatus` |
| `HelperClient.swift` | async `NSXPCConnection` client (`SMCWriter`), `HelperConnectionState` |
| `FanWriteStrategy.swift` | pure per-platform write sequences (unit-tested on Linux) |
| `ApplyGenerationGate.swift` | pure drop rule for stale poll write batches (unit-tested on Linux) |
| `FanControlPlatform.swift` | `isAppleSilicon` (`sysctl hw.optional.arm64`) and `defaultSafetyPolicy` |

## Threading model

- All observable properties of `FanControlManager` are mutated on the **main thread** only.
  Synchronous public methods (`startMonitoring`, `stopMonitoring`, `refreshNow`,
  `setMonitoringPaused`, `saveProfile`, `deleteProfile`, `clearLastError`) hop to main if called elsewhere.
  `FanControlManager` is **not** `@MainActor`; it is `@unchecked Sendable`, so views may call it
  directly from the main thread and `await` its async methods from a `Task`.
  Async methods can be awaited from any context; they publish via `MainActor.run`.
- A `Timer` on the main run loop (`.common` mode, 10 % tolerance) fires every `pollingInterval`
  (effective range 0.5 to 300 s). Each tick snapshots the active profile, `safetyPolicy` and the
  session flag, then runs the poll on a private serial `DispatchQueue` (`pollQueue`, QoS utility).
- `pollQueue` owns the `SMCClient`, the discovered fans, the cached temperature key list
  (`SensorCatalog.discoverTemperatureSensors` runs once; later polls use `readTemperatures(keys:)`),
  the `AlertEvaluator`, the `TemperatureSampleFilter`, the `FanWriteStrategy`, the write-throttle baseline, the apply generation
  (`ApplyGenerationGate`) and its own copy of the monitoring flag.
- Helper writes go through a FIFO `WriteSerializer` actor, so a write list (mode key first,
  then target) is never interleaved with another list.
- `HelperClient` is lock-protected; its `onStateChange` callback is mirrored onto
  `helperConnectionState` / `isSMCWriteSessionOpen` on main. Every XPC call races against
  `HelperClient.callTimeout` (8 s): on timeout it throws `.helperConnectionFailed("timeout")` and
  invalidates the connection (which ends the session; the helper restores the pre-session values),
  so a hung helper cannot block the `WriteSerializer` forever.
- `stopMonitoring()` cancels a pending wake re-apply; polls that were queued while monitoring and
  run after `stopMonitoring()` are dropped and do not reopen the reader. `refreshNow()` while not
  monitoring opens the SMC for that one poll and closes it again (unless a write session is open).
- `exportSMCDump()` (sync) blocks the caller until the in-flight poll and the whole dump finish;
  UIs must use the async overload `await exportSMCDump()`, which runs on `pollQueue`.

## Polling and control

Every poll reads `F<i>Ac`, `F<i>Tg` and the cached temperature keys, passes the temperatures
through the `TemperatureSampleFilter` (below), appends the aggregate sensors (below), runs `AlertEvaluator` (high temperature with hysteresis; emergency latch with hysteresis; 0 RPM with
target > 0 for 3 polls = anomaly), and publishes. If (and only if) a write session is open, it
also computes `FanControlEngine.plan(profile:fans:sensors:policy:isEmergency:)` and writes the
result.

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

**Write throttle:** poll-driven writes skip a fan unless its mode changes (automatic and manual)
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
  (`F<i>Md ← 0` / `FS! ` bits cleared for the fans that were being forced). If that rollback
  succeeds those fans get an `.automatic` baseline and are no longer unsettled. The original
  error is rethrown / stored in `lastError`. A timeout invalidates the connection, so the helper
  restores instead (the rollback is skipped because the session is gone).

**Apply generation (no poll can undo a user apply):** `applyProfile` / `setFanControlMode` /
`setFanRPM` first store (user profiles, `upsert`) and select the profile on main, *then* bump the
apply generation on `pollQueue`, then plan and write. Polls snapshot the active profile on main
and record the generation when they plan a batch; when that batch reaches the front of the
`WriteSerializer` it is dropped if a newer apply started (`ApplyGenerationGate.isStale`). Because
the selection changes before the bump and `pollQueue` is FIFO, every poll planned from the old
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
status is `.requiresApproval`, Login Items (& Extensions on macOS 15) is opened and `.helperNotInstalled` is thrown (show
`FanControlManager.helperApprovalInstructions`, since that error case carries no message).
`openSMCSession` checks `version()` against `FanControlHelperConstants.protocolVersion` and
re-registers a mismatched helper once.

`setFanControlMode` / `setFanRPM` edit the active profile: a user profile is updated in place;
if a built-in profile is active, its modes are copied into a user profile named "Custom"
(`FanControlManager.customProfileID`), which becomes active. RPMs are validated against
`fan.rpmRange` (or `0...max` if `safetyPolicy.enforceHardwareMinimum` is false) and rejected with
`.rpmOutOfRange`.

**Nook hidden (§5.4):** `setMonitoringPaused(true)` slows polling to
`max(5 × pollingInterval, 10 s)` if a write session is open (sensor-based modes and the emergency
override keep working) or if `keepAlertsWhilePaused` is `true` (default; the high-temperature and
fan-anomaly alerts keep firing). Otherwise polling stops while paused.

**Sleep/wake:** 5 s after `NSWorkspace.didWakeNotification`, the manager refreshes (if
monitoring) and, if a session is still open:
- `reapplyProfileAfterWake == true` (default): re-applies the active profile (bypassing the
  throttle, never opening a session);
- `reapplyProfileAfterWake == false`: **closes the session.** The SMC may silently reset forced
  fans to automatic during sleep while `appliedTargets` (the throttle baseline) and
  `fanControlModes` still say manual; the poll loop would then never rewrite them (the targets did
  not "change"). Closing makes the helper restore the pre-session values, so the reported state
  matches the hardware again; the user re-applies a profile to take control.
The flag is read when the 5 s delay elapses; `stopMonitoring()` cancels the pending work. The app
must not add its own wake re-apply; it only mirrors its setting into this property (see Settings
below).

**Termination:** on `NSApplication.willTerminateNotification` (observers are registered on the
first `startMonitoring` or `openSMCSession`), all fans are set to automatic and the session is
closed (both through the `WriteSerializer`, after bumping the apply generation), waiting at most 2 s
on the main thread. Independently, the helper hands the fans back to the SMC when the client
connection goes away (`docs/helper.md` §4: mode keys to automatic; `F<i>Tg` is written back only for
target-only fans, clamped into `Mn...Mx`).

**Temperature sample filter** (`FanControlCore.TemperatureSampleFilter`): on Mac14,9 the `Tp*`
(P-core) keys read either their real value or a fixed near-zero pattern (`0.00 / 6.70 / 8.43`,
`0.00 / 4.63 / 5.32`, `0.00 / 6.03 / 7.43`), alternating per read or for a whole power-gated
cluster. Every sensor batch (discovery, each poll, and the fresh read of a user apply) is filtered
on `pollQueue` before alerts, `plan` and publishing, so `sensorReadings` (UI) and the planned
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
readings; an aggregate without any finite member is omitted (Intel/fanless machines simply lack
it, and a profile bound to a missing aggregate fails hot like any missing sensor).
`sensorType` is the existing case `.greatest` (no new `SensorType` case, so persisted data and
exhaustive switches are unaffected); `SensorReading.isAggregate` / `SensorAggregator.isAggregate(_:)`
test for the `agg:` id prefix, which cannot collide with a 4-character SMC key.

| id | name | members (Apple Silicon) | members (Intel) | overview |
|---|---|---|---|---|
| `agg:cpu` | CPU (max) | `Tp` `Te` `TC` | `Tp` `Te` `TC` | yes |
| `agg:cpu.p` | CPU Performance Cores (max) | `Tp` | `Tp` | no |
| `agg:cpu.e` | CPU Efficiency Cores (max) | `Te` | `Te` | no |
| `agg:gpu` | GPU (max) | `Tg` | `Tg` `TG` | yes |

Members are the table's prefixes filtered by `SafetyPolicy.defaultEmergencySensorPrefixes(appleSilicon:)`,
so `TG*` (battery-area `ioft` keys on Mac14,9) is excluded on Apple Silicon exactly as for the
emergency check. The table is `SensorAggregator.definitions(appleSilicon:)`; the manager uses
`FanControlPlatform.sensorAggregateDefinitions` (also `manager.sensorAggregateDefinitions`).
`FanControlEngine.plan` needs no change: `.sensor(sensorKey: "agg:cpu", …)` is looked up by id.
Aggregate ids do not match any emergency prefix, so the emergency maximum and alerts are unchanged
(an aggregate's value is always one member's value). `SensorCatalog.displayName(for:)` returns the
aggregate name for `agg:` ids. `SensorAggregator.overview(_:definitions:)` keeps the overview
aggregates (CPU, GPU) plus the readings they do not cover; the widget uses it for its default
"3 hottest" list so a core is not listed twice. `fanfi-probe` prints the aggregates of the filtered
samples after each temperature readout.

**Safety policy selection:** `safetyPolicy` starts as `FanControlPlatform.defaultSafetyPolicy`
= `SafetyPolicy.default(appleSilicon: FanControlPlatform.isAppleSilicon)`. On Apple Silicon the
emergency prefixes are `Tp/Te/TC/Tg` (`TG*` excluded: on Mac14,9 those are `ioft` battery-area
sensors at ~33 °C; the GPU is `Tg*`); on Intel they stay `Tp/Te/TC/Tg/TG` (`TG0P`/`TG0D` = GPU).
`isAppleSilicon` uses `sysctl hw.optional.arm64` (true on Apple Silicon also under Rosetta), not
`FanWriteStrategy`'s key-presence detection: `F<i>Md` also exists on some late Intel models and
the strategy is only known after fan discovery. `SafetyPolicy.default` (static) is unchanged and
keeps the full list; `SafetyPolicy`'s stored properties and Codable keys are unchanged.

The persisted active profile is **not** re-applied automatically at launch (design doc §5.5 is
still open): the session stays closed until the user acts.

## Persistence

`ProfileStore` (user profiles plus `activeProfileID`) is stored as JSON
(`ProfileStore.encodeJSON`) in `UserDefaults` under **`fanControl.profileStore`**
(`FanControlManager.profileStoreDefaultsKey`) on every change. The real app may swap this for a
sindresorhus `Defaults` key with the same name. Built-in profiles (Automatic, Silent, Maximum)
are generated for the current fans and are not stored; `availableProfiles` lists them first.
`pollingInterval`, `reapplyProfileAfterWake` and `safetyPolicy` are not persisted by the kit; the
app's settings layer owns them.

## Settings owned by the app

The kit does not depend on sindresorhus `Defaults`. The app copies its settings into these
settable properties (main thread), at launch before `startMonitoring()` and on every change. In
the DynamicNotch drop-in UI this is `FanControlAlertCoordinator.syncManagerSettings()`, driven by
`Defaults.updates(.fanControlGeneralSettings)`.

| Property | Default | Effect |
|---|---|---|
| `pollingInterval` | 2.0 s | timer interval (clamped to 0.5...300 s); setting it reschedules the timer |
| `reapplyProfileAfterWake` | `true` | `true`: 5 s wake re-apply; `false`: close an open session on wake |
| `keepAlertsWhilePaused` | `true` | keep a slow poll while paused without a session (the drop-in coordinator mirrors `highTemperatureAlertEnabled \|\| fanAnomalyAlertEnabled`) |
| `safetyPolicy` | `FanControlPlatform.defaultSafetyPolicy` | thresholds; taken per poll. An app that persists its own policy should start from `SafetyPolicy.default(appleSilicon: FanControlPlatform.isAppleSilicon)` |
| `clientTeamID` | `FanControlHelperConstants.teamIdentifierPlaceholder` | Team ID in the helper code-signing requirement checked on every new helper connection (forwards to `HelperClient.clientTeamID`); set before the first helper call unless the constant was replaced |

`HelperClient.callTimeout` (default 8 s, `<= 0` disables) is set on the `HelperClient` passed to
`FanControlManager.init` (the shared instance uses the default).

**Team ID (3 places, all the same value):** `Support/Helper-Info.plist` `FanControlClientTeamID`
(read by the helper to check the *app*), `FanControlHelperConstants.teamIdentifierPlaceholder`
(fallback for the helper and default of `clientTeamID`), and optionally
`FanControlManager.shared.clientTeamID` at launch (what the *app* requires of the helper:
`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)` =
`anchor apple generic and identifier "com.example.dynamicnotch.DynamicNotch.fanfi" and certificate leaf[subject.OU] = "<teamID>"`).
Replacing the constant makes the runtime assignment unnecessary.

## Errors

Failures of async actions are rethrown **and** stored in `lastError` (main thread). Poll-loop
failures (SMC open, failed fan discovery, poll-driven writes) are stored too; `lastError` is only
re-published when the value changes, so a persistent failure does not churn observers every poll.
A failed fan discovery leaves `fans` empty and is retried on later polls while no fan is known.
The manager never clears `lastError` itself; call `clearLastError()` when the user dismisses it.
`installHelper()` throws `.helperNotInstalled` while the daemon awaits approval (after opening
Login Items); `helperStatus` is already `.requiresApproval` at that point, so UIs can show
approval guidance (`helperApprovalInstructions`, English) instead of the generic message.

## Notifications (object: the manager, posted on main)

| Name | When | userInfo |
|---|---|---|
| `.fanControlHighTemperatureChanged` | `highTempAlertActive` changed | `"active": Bool` |
| `.fanControlFanAnomalyChanged` | `anomalousFanIDs` changed | `"fanIDs": Set<Int>` |
| `.fanControlDidUpdate` | after every published poll | none |

These are the hooks for Live Activities (design doc §4.2).

## Helper-side checks (see `docs/helper.md` §4)

The helper is the safety authority. Independently of the kit's planning it rejects writes to
keys outside the allowlist (`F<n>Tg`, `F<n>Md`, `FS! `; `F<n>Mn` and `Ftst` are not allowed), keys
whose SMC attributes lack the write bit `0x40`, payloads that are not 1 to 32 bytes or do not match
the key's `dataSize`, `F<n>Md` values other than 0/1, `F<n>Tg` values outside the hardware
`F<n>Mn...F<n>Mx` read at session open (with a ±1 RPM rounding tolerance), and `FS! ` bits at or
above `1 << FNum` (`FanControlXPC.HelperWritePolicy.validate`). `safetyPolicy.enforceHardwareMinimum = false`
therefore only affects client planning; sub-minimum targets are refused by `FanWriteStrategy`
(`.rpmOutOfRange`, nothing written) and by the helper.

## Write sequences (`FanWriteStrategy`)

Detected per fan from key presence and `keyInfo`, not from the CPU architecture:

| Style | Detection | Manual | Automatic |
|---|---|---|---|
| `.modeKey` (Apple Silicon) | `F<i>Md` exists | `F<i>Md ← 1`, then `F<i>Tg ← rpm` (`flt `) | `F<i>Md ← 0` |
| `.forceBits` (Intel) | `FS! ` exists | `FS! ← mask \| 1<<i` (current mask read first), then `F<i>Tg ← rpm` (`fpe2`) | `FS! ← mask & ~(1<<i)` |
| `.targetOnly` | neither | `F<i>Tg ← rpm` | nothing (the helper restores values on session close) |

Mac14,9 / macOS 26: `FS! ` and `Ftst` are absent, so both fans are `.modeKey`; `F<i>Md` is `ui8 `
(1 byte, `01` / `00`) and `F<i>Tg` little-endian `flt ` (2317 RPM = `00 d0 10 45`, the same bytes
the read path decodes from `F<i>Mn`). `F<i>Mn` is never written. Manual targets outside the
fan's `F<i>Mn...F<i>Mx` throw `.rpmOutOfRange` before any write is produced (`FanWriteInfo.rpmLimits`).
`rollbackWrites(afterFailureOf:)` returns the writes that hand the fans of a failed manual list
back to automatic.

Mode writes always come before target writes. Batches write `FS! ` once with all bits merged.

## Not verifiable without a Mac

The code was first written on Linux against SDK-signature stubs. It now builds against the real
macOS SDK (macOS 26, Swift 6.3.3) with 0 diagnostics in the package's Swift 5 mode and with
`-swift-version 6` (`ResumeOnce` requires `T: Sendable` for the latter; `SMCConnection` uses
`mach_task_self_` because the `mach_task_self()` macro is not importable). This does not prove
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
- Whether the provisional thresholds (alert 90 °C, emergency 95 °C, hysteresis 5 °C, sensor
  prefixes `Tp/Te/TC/Tg/TG`) suit each model (design doc §5.6).
- Whether the SMC resets forced fans across sleep (the 5 s wake re-apply assumes it may).
- Whether `@Observable` property `didSet` observers fire as expected (they are used for the notifications).
- Battery impact of the 2 s default interval; whether the 2 s termination wait is enough.
