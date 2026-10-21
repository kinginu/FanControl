# FanControl

A safety-first fan control stack for **Apple Silicon Macs**, written entirely in Swift.

The app reads temperatures and fan speeds directly from the System Management Controller (SMC)
over IOKit, with no special privileges. **Only the writes** (fan mode and target RPM) go to a
small root launchd helper over XPC. The helper checks every write on its own: it accepts only
fan keys on an allowlist and values inside the fan's hardware range. It also hands the fans back
to macOS when the client goes away, on SIGTERM, and before sleep, and it repairs fan state after
wake.

> **Status: version 1.0.0 ([CHANGELOG](CHANGELOG.md)), tested on one machine.** Everything below was built and run on a
> MacBook Pro Mac14,9 (M2 Pro) with macOS 26.5. Other Apple Silicon models have not been tested.
> Controlling fans by hand can make a Mac run hotter than macOS would let it. Read the
> [safety model](#safety-model) before you use it.

## What's in the package

| Product | Kind | What it does |
|---|---|---|
| `FanControlCore` | library | Pure logic with no I/O: SMC key, type and codec handling, fan discovery, the control engine, multi-point **PCHIP fan curves** (monotone cubic), temperature **smoothing** and the target **stabiliser** (deadband, dwell, slew), the sample filter for implausible readings, aggregate sensors (`agg:cpu`, `agg:gpu`, …), profiles, safety thresholds and the power-aware polling policy. It also builds and tests on Linux. |
| `FanControlSMC` | library | An IOKit `AppleSMC` client: key enumeration, key info, reads, and the raw write path the helper uses. |
| `FanControlXPC` | library | The helper's XPC protocol, its constants, the **write allowlist and value validation** (`HelperWritePolicy`), the **sleep/wake policy** (`PowerTransitionPolicy`) and the manual-install requirement builders. |
| `FanControlKit` | library | The app-side layer: the `FanControlManager` facade (`@MainActor @Observable`) and its internal components (`MonitoringService`, `FanController`, `HelperCoordinator`, `WakeCoordinator`, `ErrorRecorder`), the poller actor, the helper client with its connection gate, the `SMAppService` installer, the write strategy, power-source monitoring and detection of other fan-control apps. |
| `FanControlHelper` | executable | The privileged launchd daemon. Ship it as an Xcode Command Line Tool target (see [docs/integration.md](docs/integration.md) §2), **not** as this SwiftPM product. |
| `fanfi-probe` | executable | A **read-only** diagnostic CLI that prints fans, temperatures, aggregates and full key dumps, runs the fan hunting check, and can emit JSON. It never writes and needs no `sudo`. |

Supporting material:

| Path | Contents |
|---|---|
| `Support/Helper-Info.plist` | The Info.plist embedded into the helper Mach-O with `-sectcreate`; the single source of the identifier keys |
| `Support/embed-helper-config.sh` | Run Script for the app target: copies the identifier keys into the app's Info.plist and generates the LaunchDaemon plist |
| `Support/identifiers.sh` | Shell version of `FanControlIdentifiers`, sourced by the scripts |
| `Support/LaunchDaemons/` | The launchd plist for the `SMAppService` path with the default identifiers |
| `Support/manual-install/` | `install.sh`, `uninstall.sh` and `status.sh` for the developer / personal-use mode ([README](Support/manual-install/README.md)) |
| `Tools/HelperSmokeApp/` | A minimal sample host app (XcodeGen) that embeds the helper and drives the real API. It was used for every hardware test. |
| `docs/` | Start at the [documentation index](docs/README.md): [architecture.md](docs/architecture.md), [integration.md](docs/integration.md), [kit.md](docs/kit.md), [helper.md](docs/helper.md), [verification/SUMMARY.md](docs/verification/SUMMARY.md) |

## Requirements

- **Apple Silicon only.** On a Mac that is not arm64, the kit refuses to open the SMC
  (`FanControlError.unsupportedPlatform`) and the helper exits at launch with code 78.
  Intel Macs are not supported.
- **macOS 26** or later as the deployment target, and Swift 6.0+ tools. Every target, tests
  included, builds in the Swift 6 language mode with complete strict concurrency.
- Xcode 26 to build the helper target and a host app. The package alone builds with Command Line
  Tools.
- Verified hardware so far: **Mac14,9** (MacBook Pro 14", M2 Pro, two fans, 2317–6800 RPM).
  The package also handles fanless Macs, which have no `FNum` fans and are read-only, but this has
  not been tested.

## Quick start

### 1. Add the package

```swift
// Package.swift of your app, or File ▸ Add Package Dependencies… ▸ Add Local… in Xcode
.package(url: "https://github.com/kinginu/FanControl.git", from: "1.0.0"),
// or a local checkout: .package(path: "../FanControl")
// app target
.product(name: "FanControlCore", package: "FanControl"),
.product(name: "FanControlKit",  package: "FanControl"),
```

### 2. Read without a helper

```swift
import FanControlKit

let manager = FanControlManager.shared      // @MainActor
manager.startMonitoring()                   // polls the SMC every 2 s (10 s on battery)
// manager.fans, manager.sensorReadings, manager.controlTemperatures, manager.temperatureHistory …
```

Or from a terminal:

```sh
swift run fanfi-probe                        # model, fans, temperatures, aggregates
swift run fanfi-probe --watch 1              # repeat every second (Ctrl-C to stop)
swift run fanfi-probe --dump                 # every SMC key: type, size, attributes, raw bytes
swift run fanfi-probe --watch 1 --fan-stats 120   # hunting check: per-fan statistics, PASS/FAIL
swift run fanfi-probe --json                 # the snapshot as JSON (JSON Lines with --watch)
```

`fanfi-probe --help` lists the options and the exit codes (0 success, 1 a `--fan-stats` FAIL,
2 bad command line, 3 SMC unavailable); [integration.md](docs/integration.md) §6 uses them.

### 3. Write: install the helper

There are two ways to install the helper. They share the same launchd label and Mach service name,
so **never install both at once.**

**Default: `SMAppService`, which needs a Developer ID / Team ID.**
Embed the helper in your app as a Command Line Tool target, and ship the launchd plist in
`Contents/Library/LaunchDaemons/` (generated by `Support/embed-helper-config.sh`, or copied from
`Support/LaunchDaemons/` when you keep the default identifiers). Sign the app and the helper with the same Team ID, with
Hardened Runtime on both. The first time the user applies a profile with a manual mode, the kit
calls `SMAppService.daemon(plistName:).register()` and sends the user to Login Items & Extensions
to approve it. The two sides check each other with `anchor apple generic … certificate
leaf[subject.OU] = "<TeamID>"` requirements. Step-by-step instructions are in
[docs/integration.md](docs/integration.md) §1–§4.

**Identifiers are Info.plist keys, not Swift constants.** Both binaries read
`FanControlHelperIdentifier`, `FanControlMachServiceName`, `FanControlClientBundleIdentifier` and
`FanControlClientTeamID` at runtime (`FanControlIdentifiers`). Put your values, including the
Team ID, in a copy of `Support/Helper-Info.plist` (embedded into the helper) and let
`Support/embed-helper-config.sh` copy them into the app and generate the LaunchDaemon plist. With
no keys set, the DynamicNotch defaults apply (`com.example.dynamicnotch.DynamicNotch` for the app,
`com.example.dynamicnotch.DynamicNotch.fanfi` for the helper identifier, Mach service and label),
and without a Team ID the placeholder `TEAMID0000` rejects every peer. See
[docs/helper.md](docs/helper.md) "Configuring identifiers".

**Manual install: for developers and personal use only.**
If you have no Team ID, build the app and helper ad-hoc signed and run
`sudo Support/manual-install/install.sh /path/to/YourApp.app`. The script copies the helper to
`/Library/PrivilegedHelperTools/` and writes a LaunchDaemon plist that **pins your app's
cdhash**. The app in turn pins the cdhash of the installed helper. Security caveats:

- Pinning a cdhash only stops a *different build* from connecting. Any process running as
  your user can still use the helper through the pinned app: it can attach to the app if the
  app has `get-task-allow`, or swap in a framework if it has `disable-library-validation`. What
  limits the damage is the helper's own allowlist and range checks, not the client check.
- There is no Gatekeeper or notarization. Re-run `install.sh` after **every** rebuild, because
  the cdhash changes.
- Do not use this mode to distribute to other people.

Details: [Support/manual-install/README.md](Support/manual-install/README.md),
[docs/helper.md](docs/helper.md) §6.

### 4. Control

```swift
try await manager.applyProfile(profile)          // opens the write session on demand
try await manager.setFanRPM(fanIndex: 0, rpm: 3000)
try await manager.restoreDefaultControl()        // hand every fan back to macOS
```

Calls not on the main actor must be `await`ed. If the app is quit, killed or crashes, the helper
hands the fans back to macOS anyway.

A write needs an open session, and only user actions open one. `applyProfile` opens it when the
profile has a manual or sensor-linked mode, in `modes` or as `defaultMode`, so a preset applied
before the fans are known is still written. `setFanRPM`, `setFanControlMode` and `setFanCurve`
edit the active profile and follow the same rule. An automatic profile with no session open
writes nothing, and read-only monitoring never contacts the helper.

## Architecture

```
 ┌──────────────────────── your app (user, unsandboxed) ─────────────────────────┐
 │  SwiftUI (your views)                                                         │
 │        │                                                                      │
 │  FanControlManager (@MainActor @Observable facade: state, profiles, settings) │
 │    ├ MonitoringService · FanController · HelperCoordinator · WakeCoordinator  │
 │        │ enqueue / await                                                      │
 │  FanControlPoller   (actor on a utility serial queue)                         │
 │    SMC read ─► SampleFilter ─► Aggregator ─► Smoother ─► Engine.plan          │
 │    (IOKit,       (Tp/Te/Tg/TC     (agg:cpu…)  (EMA, per    (PCHIP curve,      │
 │     read-only)    < 10 °C)                      control key) emergency)       │
 │                         ─► Stabiliser ─► 25 RPM throttle ─► FanWriteStrategy  │
 │                           (deadband/dwell/slew)              (Md=1 then Tg)   │
 │        │                                                                      │
 │  WriteSerializer (FIFO) ─► HelperClient (NSXPCConnection .privileged,         │
 │                             8 s timeout, connection gate, signing requirement)│
 └────────│──────────────────────────────────────────────────────────────────────┘
          │ XPC (Mach service, code-signing requirement in both directions)
 ┌────────▼─────────────── FanControlHelper (root launchd daemon) ───────────────┐
 │  HelperListenerDelegate ─► SessionRegistry (single-owner session, Mutex)      │
 │     allowlist ^F[0-9]Md$ ^F[0-9]Tg$ · SMC write bit 0x40 · size == dataSize   │
 │     Md ∈ {0,1} · Tg ∈ [Mn−1, Mx+1] read at session open                       │
 │     restore on close / disconnect / SIGTERM:  Md ← 0 (no Tg write-back)       │
 │  PowerObserver (IORegisterForSystemPower) ─► PowerTransitionPolicy            │
 │     will-sleep: hand forced fans back · wake: re-apply at 0 / 1 / 3 s         │
 │        │                                                                      │
 │  FanControlSMC ─► AppleSMC                                                    │
 └───────────────────────────────────────────────────────────────────────────────┘
```

More diagrams (module graph, components, where each safety rule lives, the two installation
paths): [docs/architecture.md](docs/architecture.md).

## Safety model

The design rule is that **the helper alone decides what is safe to write**. A compromised or
buggy client can never do more than the app itself is allowed to do. Each layer below adds to
the previous one.

1. **Helper allowlist.** Only `F<n>Md` (mode) and `F<n>Tg` (target) can be written; every
   other key, `F<n>Mn` included, is refused. A second check in `HelperWritePolicy` rejects any
   other key again, and a key whose SMC attributes lack the write bit `0x40` is refused too.
2. **Value validation.** `F<n>Md` must be 0 or 1. `F<n>Tg` must lie within the fan's hardware
   `Mn…Mx` (±1 RPM), read when the session opens. The payload must be 1–32 bytes and match the
   key's `dataSize`.
3. **Restore.** When a session closes or ends (close, client disconnect or `kill -9`, helper
   SIGTERM), the helper writes `F<n>Md ← 0`, retried once. It does **not** write `F<n>Tg` back:
   the hardware test showed that `Md = 0` alone returns control to the SMC, and writing back an
   idle snapshot of `Tg = 0` would command a stop.
4. **Sleep and wake.** Across sleep, the SMC sets `F<n>Tg` to 0 but keeps manual mode, and it
   wakes every fan at `Md = 3`, `Tg = 0` for 1–2 s. Before sleep, the helper hands forced fans
   back to the SMC. After wake, it re-applies the session's last targets at 0, 1 and 3 s,
   without waiting for the app.
5. **Client checks.** The client refuses targets outside `Mn…Mx` *before* writing anything, so
   a write list never leaves `Md = 1` with a stale `Tg`. When a list fails partway, it is rolled
   back with `Md ← 0`. Each poll also re-checks the fan state and rewrites a fan that has drifted,
   for example one that is manual with `Tg < Mn`.
6. **Emergency override.** While a write session is open, every fan runs at max once an
   emergency sensor reaches 95 °C. This applies under every profile, including Automatic, and the
   override turns off again at 90 °C. All three thresholds can be changed within fixed bounds.
7. **Anything else returns the fans to macOS:** quitting the app, turning the feature off,
   "Restore automatic control" (which also recovers manual fans left behind when no session is
   open), uninstalling the helper, rebooting, or an SMC reset.

**What software cannot fix:** SIGKILL of the helper, a kernel panic, or power loss while fans are
forced. The fans then stay at their last validated target, which is inside `Mn…Mx`, until you
click "Restore automatic control" or reboot. The helper is launched on demand, so it restarts on
the next connection.

## Status and limitations

- Verified on hardware: reads, the first write and restore, client `kill -9`, helper SIGTERM,
  sensor-linked curves, the emergency override, and sleep/wake recovery (twice). See
  [docs/verification/SUMMARY.md](docs/verification/SUMMARY.md).
- **Not yet verified:** registration through `SMAppService` and approval with real Team ID
  signing, other Apple Silicon models (whether `F<n>Md` + `F<n>Tg` is enough there, and what
  `TG*` and `TC*` mean), fanless Macs, and long-term battery impact.
- Sensor names come from community knowledge plus one machine's dump. Many keys show up as
  "Sensor XXXX".
- Coexistence: if another fan-control app (for example FanFi) writes `F<n>Md` / `F<n>Tg` at the
  same time, the two apps override each other. The kit detects such apps and warns, but it does
  not block writes.
- The default thresholds (90 / 95 / 5 °C) and the preset curves are provisional values.

## Building and testing

```sh
swift build
swift test            # 587 tests in 79 suites (Swift Testing); needs Xcode, or see CONTRIBUTING.md for Command Line Tools only
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

The default suite never touches hardware. `Tests/FanControlSMCTests/LiveSMCReadTests.swift` reads (never writes) this Mac's real AppleSMC and runs only when opted in: `FANCONTROL_LIVE_SMC_TESTS=1 swift test --filter LiveSMCReadTests`.

The app ↔ helper XPC contract has end-to-end tests (`Tests/FanControlKitTests/EndToEnd/`) that need no root, launchd or SMC writes: `HelperClient` talks over a real `NSXPCConnection` to an in-process fake helper (`NSXPCListener.anonymous()`, backed by an in-memory SMC and the real `HelperWritePolicy` / `PowerTransitionPolicy`) through session open, write order (`Md` before `Tg`), rollback after a partial failure, restore (`Md` = 0 only), release on disconnect, call timeout, protocol-version mismatch and code-signing rejection. They run as part of `swift test`; on their own with `swift test --filter HelperEndToEnd` (about 5 s). Scope and limits: [docs/kit.md](docs/kit.md) "Testing".

## Licence

MIT. See [LICENSE](LICENSE).

This project is not affiliated with Apple. "SMC key" names and their meanings are reverse-engineered
community knowledge. Use at your own risk.
