# FanControl

<!-- TODO: verify after refactor — the project name is provisional (see docs/NAMING.md); "FanControl" collides with existing projects. -->

A safety-first fan control stack for **Apple Silicon Macs**, written entirely in Swift.

The app reads temperatures and fan speeds directly from the System Management Controller (SMC)
over IOKit, with no special privileges. **Only the writes** (fan mode and target RPM) go to a
small root launchd helper over XPC. The helper checks every write on its own: it accepts only
fan keys on an allowlist and values inside the fan's hardware range. It also hands the fans back
to macOS when the client goes away, on SIGTERM, and before sleep, and it repairs fan state after
wake.

> **Status: pre-1.0, tested on one machine.** Everything below was built and run on a
> MacBook Pro Mac14,9 (M2 Pro) with macOS 26.5. Other Apple Silicon models have not been tested.
> Controlling fans by hand can make a Mac run hotter than macOS would let it. Read the
> [safety model](#safety-model) before you use it.

## What's in the package

| Product | Kind | What it does |
|---|---|---|
| `FanControlCore` | library | Pure logic with no I/O: SMC key, type and codec handling, fan discovery, the control engine, multi-point **PCHIP fan curves** (monotone cubic), temperature **smoothing** and the target **stabiliser** (deadband, dwell, slew), the sample filter for implausible readings, aggregate sensors (`agg:cpu`, `agg:gpu`, …), profiles, safety thresholds and the power-aware polling policy. It also builds and tests on Linux. |
| `FanControlSMC` | library | An IOKit `AppleSMC` client: key enumeration, key info, reads, and the raw write path the helper uses. |
| `FanControlXPC` | library | The helper's XPC protocol, its constants, the **write allowlist and value validation** (`HelperWritePolicy`), the **sleep/wake policy** (`PowerTransitionPolicy`) and the manual-install requirement builders. |
| `FanControlKit` | library | The app-side layer: `FanControlManager` (an `@MainActor @Observable` object), the poller actor, the helper client with its connection gate, the `SMAppService` installer, the write strategy, power-source monitoring and detection of other fan-control apps. |
| `FanControlHelper` | executable | The privileged launchd daemon. Ship it as an Xcode Command Line Tool target (see [docs/integration.md](docs/integration.md) §2), **not** as this SwiftPM product. |
| `fanfi-probe` | executable | A **read-only** diagnostic CLI that prints fans, temperatures, aggregates and full key dumps. It never writes and needs no `sudo`. |
| `FanControlUI` | library (*planned*) | SwiftUI settings, the curve editor and temperature charts. It does not exist yet: the UI currently lives as drop-in files in the private host app. <!-- TODO: verify after refactor --> |

Supporting material:

| Path | Contents |
|---|---|
| `Support/LaunchDaemons/` | The launchd plist for the `SMAppService` path |
| `Support/Helper-Info.plist` | The Info.plist embedded into the helper Mach-O with `-sectcreate` |
| `Support/manual-install/` | `install.sh`, `uninstall.sh` and `status.sh` for the developer / personal-use mode ([README](Support/manual-install/README.md)) |
| `Tools/HelperSmokeApp/` | A minimal sample host app (XcodeGen) that embeds the helper and drives the real API. It was used for every hardware test. |
| `Tools/IntegrationTypeCheck/` | A type-check harness for UI drop-in files |
| `docs/` | [kit.md](docs/kit.md), [helper.md](docs/helper.md), [integration.md](docs/integration.md), [verification/SUMMARY.md](docs/verification/SUMMARY.md). The earlier Japanese versions are in `docs/ja/`. |

## Requirements

- **Apple Silicon only.** On a Mac that is not arm64, the kit refuses to open the SMC
  (`FanControlError.unsupportedPlatform`) and the helper exits at launch with code 78.
  Intel support (the `FS! ` force-bit scheme) was removed on purpose.
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
.package(path: "../FanControl"),   // or a URL once it is published
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
swift run fanfi-probe            # model, fans, temperatures, aggregates
swift run fanfi-probe --watch 1  # repeat every second
swift run fanfi-probe --dump     # every SMC key: type, size, attributes, raw bytes
```

### 3. Write: install the helper

There are two ways to install the helper. They share the same launchd label and Mach service name,
so **never install both at once.**

**Default: `SMAppService`, which needs a Developer ID / Team ID.**
Embed the helper in your app as a Command Line Tool target and copy the launchd plist to
`Contents/Library/LaunchDaemons/`. Sign the app and the helper with the same Team ID, with
Hardened Runtime on both. The first time the user applies a profile with a manual mode, the kit
calls `SMAppService.daemon(plistName:).register()` and sends the user to Login Items & Extensions
to approve it. The two sides check each other with `anchor apple generic … certificate
leaf[subject.OU] = "<TeamID>"` requirements. Step-by-step instructions are in
[docs/integration.md](docs/integration.md) §1–§4.

<!-- TODO: verify after refactor — identifiers (bundle id, helper label, Team ID) are moving from source constants to Info.plist keys; update this paragraph and integration.md §4 when that lands. -->
Currently the Team ID must be set in `Support/Helper-Info.plist` (`FanControlClientTeamID`) and in
`FanControlHelperConstants.teamIdentifierPlaceholder`, and the identifiers are the placeholder
values `com.example.dynamicnotch.DynamicNotch` (app) and
`com.example.dynamicnotch.DynamicNotch.fanfi` (helper label, Mach service and signing identifier).

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

<!-- TODO: verify after refactor — FanControlManager is being split; method names above may move to new types. -->

## Architecture

```
 ┌──────────────────────── your app (user, unsandboxed) ─────────────────────────┐
 │  SwiftUI (FanControlUI, planned)                                              │
 │        │                                                                      │
 │  FanControlManager  (@MainActor @Observable: state, profiles, settings)       │
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

## Safety model

The design rule is that **the helper alone decides what is safe to write**. A compromised or
buggy client can never do more than the app itself is allowed to do. Each layer below adds to
the previous one.

1. **Helper allowlist.** Only `F<n>Md` (mode) and `F<n>Tg` (target) can be written.
   `F<n>Mn`, `FS! ` and unlock keys such as `Ftst` are refused. A second check rejects every
   other key, and a key whose SMC attributes lack the write bit `0x40` is refused too.
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
  signing, other Apple Silicon models (`Ftst` unlock keys, `TG*` and `TC*` sensor meanings),
  fanless Macs, and long-term battery impact.
- Sensor names come from community knowledge plus one machine's dump. Many keys show up as
  "Sensor XXXX".
- Coexistence: if another fan-control app (for example FanFi) writes `F<n>Md` / `F<n>Tg` at the
  same time, the two apps override each other. The kit detects such apps and warns, but it does
  not block writes.
- The default thresholds (90 / 95 / 5 °C) and the preset curves are provisional values.

## Building and testing

```sh
swift build
swift test            # Swift Testing; needs Xcode, or see CONTRIBUTING.md for Command Line Tools only
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. See [LICENSE](LICENSE).

This project is not affiliated with Apple. "SMC key" names and their meanings are reverse-engineered
community knowledge. Use at your own risk.
