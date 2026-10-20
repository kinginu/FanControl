# Architecture

This page is the map. The details live in [kit.md](kit.md) (app side), [helper.md](helper.md)
(privileged helper) and [integration.md](integration.md) (how a host app wires it up).

FanControl splits fan control along the privilege boundary:

- **Reads** (temperatures, fan RPM, fan mode) happen **in the app**, unprivileged, through the
  IOKit `AppleSMC` user client.
- **Writes** (`F<n>Md` fan mode and `F<n>Tg` target RPM, nothing else) go over XPC to a small
  **root launchd helper**. The helper validates every write on its own and hands the fans back to
  the SMC whenever its client goes away.

Supported: Apple Silicon only, macOS 26 or later, Swift 6 language mode with complete strict
concurrency in every target.

## Modules

```
target             depends on            role
─────────────────  ────────────────────  ──────────────────────────────────────────────────────
FanControlCore     —                     pure logic, no I/O (builds on Linux too): models, SMC
                                         codec, discovery, engine, PCHIP curves, smoothing and
                                         stabiliser, sample filter, aggregates, profiles, safety
                                         thresholds, polling policy, fan statistics
FanControlSMC      Core                  IOKit AppleSMC client: enumeration, key info, reads,
                                         and the raw write path the helper uses
FanControlXPC      Core                  XPC protocol, identifiers (Info.plist keys), write
                                         allowlist, HelperWritePolicy, PowerTransitionPolicy,
                                         code-signing requirements, manual-install rules
FanControlKit      Core, SMC, XPC        app side: FanControlManager facade + components,
                                         poller actor, HelperClient, HelperInstaller
FanControlHelper   Core, SMC, XPC        root daemon; ship it as an Xcode Command Line Tool
                                         target, not as the SwiftPM product
fanfi-probe        Core, SMC             read-only diagnostic CLI (target FanControlProbe)
```

`fanfi-probe` links Core and SMC only, so it cannot write: it has no path to the helper.

## Runtime

```
┌──────────────────────────── host app (user, unsandboxed) ───────────────────────────┐
│  SwiftUI views (host-provided)                                                      │
│        │ public API (@MainActor)                                                    │
│  FanControlManager — @MainActor @Observable facade: poll snapshot, profileStore,    │
│        │              safetyPolicy, tuning, temperatureHistory, lastError           │
│        ├─ MonitoringService   timer, effective interval, power source, pause/holds  │
│        ├─ FanController       apply, session open/close, restore, selection         │
│        │                      rollback, termination restore                         │
│        ├─ HelperCoordinator   install status, handshake, session flag, conflicts    │
│        ├─ WakeCoordinator     sleep/wake re-apply at 0 / 2 / 5 s                    │
│        └─ ErrorRecorder       records a user action's error in lastError            │
│        │ enqueue / await run                                                        │
│  FanControlPoller — actor on a private utility serial queue                         │
│     SMC read ─► TemperatureSampleFilter ─► SensorAggregator ─► TemperatureSmoother  │
│     (IOKit)     (Tp/Te/Tg/TC < 10 °C)      (agg:cpu, agg:gpu…)  (per control key)   │
│        ─► FanControlEngine.plan ─► FanTargetStabilizer ─► 25 RPM throttle           │
│           (PCHIP curve, emergency)  (deadband/dwell/slew)   + UnsettledFanDetector  │
│        ─► FanWriteStrategy (Md = 1 then Tg; range-checked before any write)         │
│        │                                                                            │
│  WriteSerializer (FIFO) ─► HelperClient (NSXPCConnection .privileged, 8 s timeout,  │
│                            HelperConnectionGate, helper code-signing requirement)   │
└────────│────────────────────────────────────────────────────────────────────────────┘
         │ XPC on the Mach service <FanControlMachServiceName>
         │ code-signing requirement checked in both directions
┌────────▼────────────────── FanControlHelper (root launchd daemon) ──────────────────┐
│  HelperDaemon: identifiers from the embedded Info.plist (HelperConfiguration),      │
│        client requirement: Team ID, or the cdhash pin from FANCONTROL_CLIENT_       │
│        REQUIREMENT (manual install); invalid or not arm64 → exit 78 without         │
│        listening; signal handlers and power notifications before the listener       │
│  HelperListenerDelegate ─► HelperService (one per connection)                       │
│        ─► SessionRegistry (single-owner session, state in a Mutex)                  │
│             HelperWritePolicy: allowlist ^F[0-9]Md$ ^F[0-9]Tg$, write bit 0x40,     │
│             size == dataSize, Md ∈ {0,1}, Tg ∈ [Mn−1, Mx+1]                         │
│             restore on close / disconnect / reclaim / owner-pid watchdog (5 s) /    │
│             SIGTERM: Md ← 0, no Tg back (SIGTERM exit 0, or 74 if a restore failed) │
│  PowerObserver (IORegisterForSystemPower) ─► PowerTransitionPolicy                  │
│        will sleep: hand forced fans back · wake: re-apply at 0 / 1 / 3 s            │
│        │                                                                            │
│  FanControlSMC ─► AppleSMC                                                          │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Threading

- `FanControlManager` and its components are `@MainActor`. Views call them directly.
- All SMC I/O runs on `FanControlPoller`, an actor whose executor is a private serial
  `DispatchSerialQueue`. Results are published back to the main actor in order.
- Writes go through the FIFO `WriteSerializer` actor, so one write list never interleaves with
  another. An apply generation (`ApplyGenerationGate`) drops a poll batch that was planned before
  a newer user apply.
- `HelperClient` is the only `@unchecked Sendable` type (lock-protected). There is no
  `nonisolated(unsafe)`.
- In the helper, `SessionRegistry` serialises every XPC call and power notification under one
  `Synchronization.Mutex`; `PowerObserver` is an actor on the power-notification queue.

Details: [kit.md](kit.md) "Architecture" and "Threading model", [helper.md](helper.md) intro and §5.

### Where decisions live

The rules that matter for safety are pure, unit-tested types; the IOKit and XPC code around them
is thin glue.

| Decision | Type | Module |
|---|---|---|
| Which keys and values the helper accepts; restore plan | `HelperWritePolicy`, `FanControlHelperConstants.allowedWriteKeyPatterns` | XPC |
| What to do on sleep and wake | `PowerTransitionPolicy` | XPC |
| Which client the helper accepts (Team ID or cdhash); which requirement the app puts on the helper | `FanControlHelperConstants.resolveClientRequirement`, `.helperRequirementMode` (`ManualInstallMode.swift`) | XPC |
| Identifiers (helper, Mach service, client, Team ID) | `FanControlIdentifiers` | XPC |
| Code-signing requirement strings (validated; malformed input gives `never`) | `CodeSigningRequirement`, `SigningPin` | XPC |
| Write order and pre-write range check; rollback list | `FanWriteStrategy` | Kit |
| Stale poll batches | `ApplyGenerationGate` | Kit |
| Fans that drifted from what was applied | `UnsettledFanDetector` | Kit |
| When to stop connecting to the helper; backoff | `HelperConnectionGate` | Kit |
| Pause and live-data holds | `MonitoringPauseState` | Kit |
| Target RPM for a profile and temperature; emergency latch | `FanControlEngine`, `AlertEvaluator` | Core |
| Anti-hunting | `TemperatureSmoother`, `FanTargetStabilizer`, `FanControlTuning` | Core |
| Implausible readings, aggregate sensors | `TemperatureSampleFilter`, `SensorAggregator` | Core |
| Poll interval on battery | `PollingIntervalPolicy` | Core |

## Installation paths

Both paths use the same helper binary, the same label and Mach service, and the same write
validation. **Never install both at once.**

| | `SMAppService` (default for shipping) | Manual install (developers, personal use) |
|---|---|---|
| Needs | Developer ID / Team ID signing | Nothing: ad-hoc signing is fine |
| Helper location | `App.app/Contents/MacOS/FanControlHelper` | `/Library/PrivilegedHelperTools/<label>` |
| Registration | The kit calls `SMAppService.daemon(plistName:).register()`, the user approves in Login Items & Extensions | `sudo Support/manual-install/install.sh <App.app>` |
| Helper accepts the app by | Bundle id + Team ID | Bundle id + the app's **cdhash** (re-run `install.sh` after every rebuild) |
| App accepts the helper by | Helper identifier + Team ID | Helper identifier + cdhash of the root-owned installed binary |

Details: [helper.md](helper.md) §1–§3 and §6, [integration.md](integration.md) §2–§4,
[`Support/manual-install/README.md`](../Support/manual-install/README.md).

## Identifiers

No identifier is hard-coded in Swift. Both binaries read four Info.plist keys at runtime through
`FanControlIdentifiers`: `FanControlHelperIdentifier`, `FanControlMachServiceName`,
`FanControlClientBundleIdentifier` and `FanControlClientTeamID`. The helper reads them from the
Info.plist embedded with `-sectcreate`; the app reads them from its own Info.plist, where
`Support/embed-helper-config.sh` copies them (it also generates the LaunchDaemon plist).
`Support/identifiers.sh` is the shell twin used by the install scripts. With no keys set, the
DynamicNotch defaults apply. See [helper.md](helper.md) "Configuring identifiers".

## Safety in one paragraph

The helper is the safety authority: it writes only `F<n>Md` ∈ {0, 1} and `F<n>Tg` inside the fan's
hardware `Mn…Mx`, and it ends every session — close, client disconnect or crash, reclaim, SIGTERM —
with `F<n>Md ← 0`, which returns the fan to the SMC. Before sleep it hands forced fans back, and
after wake it re-applies the session's last targets. The client adds the pre-write range check,
rollback after a partial failure, drift detection, and the emergency override (every fan at max
from 95 °C while a session is open). What software cannot cover: SIGKILL of the helper, a kernel
panic or power loss while fans are forced. See the [safety model](../README.md#safety-model).
