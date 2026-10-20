# FanControlHelper (privileged helper)

The root launchd daemon that performs SMC **writes**. Temperatures and RPMs are read in the app
itself (`FanControlSMC.SMCClient`, without privileges); only writes go to the helper over XPC.

- **Apple Silicon only.** Writes use `F<n>Md` and `F<n>Tg`, nothing else. On hardware that is
  not arm64 (`sysctl hw.optional.arm64` ≠ 1, `FanControlHost.isAppleSilicon`), the helper logs a
  fault, `Refusing to start: this Mac is not Apple silicon …`, and exits with code 78
  (`EX_CONFIG`) without opening its listener.
- There are two installation modes. **`SMAppService`** (§1–§3) is the default and needs Team ID
  signing. **Manual install** (§6) is for developers and personal use.
- Build: Swift 6 language mode (complete strict concurrency), deployment target macOS 26.
  `SessionRegistry` is a checked `Sendable` that keeps all of its state in a
  `Synchronization.Mutex`; every XPC call and power notification is serialised under that
  mutex, and the SMC I/O happens inside it. `PowerObserver` is an actor whose executor is the
  power-notification queue. `HelperListenerDelegate` and `HelperService` are immutable
  `Sendable` classes (the connection counter is an `Atomic`). The helper uses no
  `@unchecked Sendable` and no force unwraps.

Identifiers used below are configurable per host ("Configuring identifiers" below). The
examples use the defaults, which are DynamicNotch's:

| Role | Info.plist key | Default |
|---|---|---|
| App bundle id / signing identifier | `FanControlClientBundleIdentifier` | `com.example.dynamicnotch.DynamicNotch` |
| Helper signing identifier | `FanControlHelperIdentifier` | `com.example.dynamicnotch.DynamicNotch.fanfi` |
| Mach service = launchd label (`<label>`) | `FanControlMachServiceName` | = helper identifier |
| Log subsystem / category | (client bundle id) | `com.example.dynamicnotch.DynamicNotch` / `fancontrol-helper` |

Source map:

| Path | Contents |
|---|---|
| `Sources/FanControlXPC/FanControlIdentifiers.swift` | Parses the identifier keys from `Bundle.main.infoDictionary` (fallbacks, validation) |
| `Sources/FanControlXPC/FanControlHelperConstants.swift` | Accessors for the identifiers (Mach service name, plist name, …), Team ID placeholder, write allowlist, requirement builders |
| `Sources/FanControlXPC/FanControlHelperProtocol.swift` | `@objc` XPC protocol (wire contract and version history), error codes, `makeHelperInterface()` |
| `Sources/FanControlXPC/HelperWritePolicy.swift` | Pure validation and restore planning (unit-tested) |
| `Sources/FanControlXPC/PowerTransitionPolicy.swift` | Pure sleep/wake decisions (unit-tested) |
| `Sources/FanControlXPC/ManualInstallMode.swift` | Constants, requirement builders and validation for manual-install mode (§6) |
| `Sources/FanControlXPC/CodeSigningRequirement.swift` | `SigningPin` (Team ID vs cdhash) and the validated requirement builders / strict parser both paths share; invalid input fails closed (`never`) |
| `Sources/FanControlSMC/` | IOKit AppleSMC access (`SMCConnection`, `SMCClient`) |
| `Sources/FanControlHelper/` | The daemon: `main.swift` (one call), `HelperDaemon` (bootstrap, command line, exit statuses, signals), `HelperListenerDelegate`, `HelperService`, `SessionRegistry` (session state machine), `PowerObserver`, `HelperConfiguration`, `HelperLog` |
| `Support/LaunchDaemons/<label>.plist` | launchd plist for SMAppService with the default identifiers (DynamicNotch copies it as-is) |
| `Support/Helper-Info.plist` | Info.plist template embedded in the helper Mach-O; the single source of the identifiers |
| `Support/embed-helper-config.sh` | Run Script for the app target: copies the identifiers into the app's Info.plist and generates `Contents/Library/LaunchDaemons/<label>.plist` |
| `Support/identifiers.sh` | Shell version of `FanControlIdentifiers` (sourced by the scripts) |
| `Support/manual-install/` | `install.sh` / `uninstall.sh` / `status.sh` and the LaunchDaemon plist template (§6) |

## Configuring identifiers

The app, the helper, launchd and the install scripts must agree on three names. None of them is
hard-coded in Swift: `FanControlIdentifiers` reads them **once at runtime** from
`Bundle.main.infoDictionary`. In the app that is the app's own `Info.plist`. In the helper it is
the Info.plist embedded with `-sectcreate __TEXT __info_plist` (`Support/Helper-Info.plist`).
Both sides read the same keys. `FanControlHelperConstants.machServiceName`, `.helperIdentifier`,
`.appBundleIdentifier`, `.plistName`, `.manualHelperPath`, … are computed from them, so call
sites do not change.

| Key | Used for | If missing |
|---|---|---|
| `FanControlHelperIdentifier` | Helper code-signing identifier (the helper target's `PRODUCT_BUNDLE_IDENTIFIER`); the app pins it on its connection | `FanControlMachServiceName`, else `com.example.dynamicnotch.DynamicNotch.fanfi` |
| `FanControlMachServiceName` | Mach service and launchd `Label`; LaunchDaemon plist name `<label>.plist` (`SMAppService.daemon(plistName:)`); manual-install paths `/Library/PrivilegedHelperTools/<label>`, `/Library/LaunchDaemons/<label>.plist` | `FanControlHelperIdentifier` |
| `FanControlClientBundleIdentifier` | The only app the helper accepts (`identifier "…"` in its client requirement, `AssociatedBundleIdentifiers`); the helper's log subsystem | `com.example.dynamicnotch.DynamicNotch` |
| `FanControlClientTeamID` (optional) | Team ID of both binaries in SMAppService mode (helper: client requirement; app: default of `HelperClient.clientTeamID`) | not set: placeholder `TEAMID0000`, which rejects everyone; irrelevant in manual mode |

Values must be reverse-DNS identifiers (`[A-Za-z0-9-]` components separated by single dots, at
most 255 bytes) and Team IDs exactly 10 upper-case letters or digits. An invalid value is
**ignored** (the fallback applies) and reported: the helper logs each problem at startup
(`Embedded Info.plist: …`, plus the resolved `Identifiers: helper …, Mach service …, client …`),
and `FanControlHelperConstants.identifiers.issues` lists them in the app. The shell scripts are
stricter: they abort on an invalid value. When no key is set (DynamicNotchApp today, the test
runner), everything resolves to the defaults above, so existing hosts keep working unchanged.

**What a host sets** (example: app `com.acme.Notch`):

1. Helper target: `PRODUCT_BUNDLE_IDENTIFIER = com.acme.Notch.helper`.
2. A copy of `Support/Helper-Info.plist` in the host project, embedded by the helper target's
   `-sectcreate`, with `CFBundleIdentifier` and `FanControlHelperIdentifier` =
   `com.acme.Notch.helper`, `FanControlMachServiceName` = `com.acme.Notch.helper` (or another
   name), `FanControlClientBundleIdentifier` = `com.acme.Notch`, and `FanControlClientTeamID`.
3. App target: `PRODUCT_BUNDLE_IDENTIFIER = com.acme.Notch`, and a Run Script phase (after the
   helper is embedded; it runs before code signing) with `ENABLE_USER_SCRIPT_SANDBOXING = NO`
   and `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` as an **input file** (without it the phase can run
   before Xcode writes the Info.plist, which then loses the keys):
   ```sh
   "${SRCROOT}/FanControl/Support/embed-helper-config.sh" "${SRCROOT}/Config/Helper-Info.plist"
   ```
   It fails the build if the app's `CFBundleIdentifier` differs from
   `FanControlClientBundleIdentifier`, writes the four keys into the built app's Info.plist and
   generates `Contents/Library/LaunchDaemons/<label>.plist` (instead of copying
   `Support/LaunchDaemons/…`). Without the script, put the keys in the app's Info.plist yourself
   and ship a LaunchDaemon plist whose `Label`, `MachServices` and `AssociatedBundleIdentifiers`
   match (`embed-helper-config.sh --launchd-plist-only <Helper-Info.plist> <dir>` writes one).
4. Manual install needs nothing extra: `install.sh`, `status.sh <app>` and
   `uninstall.sh <app>` read the identifiers from the helper's embedded Info.plist
   (`launchctl plist __TEXT,__info_plist <helper>`). Without an app argument they use the
   defaults, overridable with `FANCONTROL_HELPER_IDENTIFIER`, `FANCONTROL_MACH_SERVICE_NAME` and
   `FANCONTROL_CLIENT_BUNDLE_IDENTIFIER` (`Support/identifiers.sh`; pass them through `sudo`
   explicitly, e.g. `sudo FANCONTROL_MACH_SERVICE_NAME=com.acme.Notch.helper ./uninstall.sh`).

Check a build without installing anything:

```sh
launchctl plist __TEXT,__info_plist YourApp.app/Contents/MacOS/FanControlHelper   # embedded keys
YourApp.app/Contents/MacOS/FanControlHelper --print-configuration                 # what the helper resolves (JSON, then exits; no SMC access)
plutil -p YourApp.app/Contents/Info.plist | grep FanControl                        # what the app resolves
```

`HelperSmokeApp` (`Tools/HelperSmokeApp/project.yml`) is the reference setup: its
`FANCONTROL_APP_ID`, `FANCONTROL_HELPER_ID` and `FANCONTROL_HELPER_INFO_PLIST` build settings are
the only place the identifiers appear.

Not configurable through the plist: the helper executable name (`FanControlHelper`) and the
protocol version. Both log subsystems follow the configured client bundle id: the helper's
`fancontrol-helper` category and the app-side `fancontrol-kit` category (`kitLog` in
`FanControlManager.swift`) log under `FanControlClientBundleIdentifier`.

## 1. Bundle layout

```
YourApp.app/Contents/
  MacOS/YourApp
  MacOS/FanControlHelper                                 ← helper executable
  Library/LaunchDaemons/<label>.plist
```

Xcode setup (full recipe in [integration.md](integration.md) §2–§4):

1. Add an **Xcode Command Line Tool target** `FanControlHelper` (this is required). Compile
   `Sources/FanControlHelper/*.swift` in it, and link the package's `FanControlCore`,
   `FanControlSMC` and `FanControlXPC` library products.
   **Do not ship the SwiftPM executable product `FanControlHelper`.** SwiftPM does not embed
   `Helper-Info.plist` (the package deliberately has no `unsafeFlags`). Without it,
   `Bundle.main.infoDictionary` has no `FanControlClientTeamID`, `HelperConfiguration.teamID`
   falls back to the placeholder `TEAMID0000`, and **every client is rejected**. The SwiftPM
   product exists only for Linux/CI build checks.
2. Linker flags:
   `OTHER_LDFLAGS = $(inherited) -sectcreate __TEXT __info_plist "$(SRCROOT)/FanControl/Support/Helper-Info.plist"`.
   Also set `GENERATE_INFOPLIST_FILE = NO`, `CREATE_INFOPLIST_SECTION_IN_BINARY = NO`, and leave
   `INFOPLIST_FILE` empty. If Xcode also creates the section, it passes a second
   `-sectcreate __TEXT __info_plist`. Xcode 26.6 does not report an error for this, but nothing
   guarantees which copy wins. Set `PRODUCT_BUNDLE_IDENTIFIER` to `FanControlHelperIdentifier`,
   because the app requires this signing identifier from the helper.
3. In the app target, add a **Copy Files** phase, destination `Executables`, with
   `FanControlHelper`. For the launchd plist, either run `Support/embed-helper-config.sh`
   ("Configuring identifiers"; generates it from Helper-Info.plist), or, with the default
   identifiers, add a second Copy Files phase (destination `Wrapper`, subpath
   `Contents/Library/LaunchDaemons`) with `Support/LaunchDaemons/<label>.plist`.
4. Add `FanControlHelper` to the app's Target Dependencies.

## 2. Signing (SMAppService mode)

- Sign the app and the helper with the **same Team ID**, with **Hardened Runtime** on both.
  Notarize the whole app when you distribute it.
- On every connection, the helper sets
  `NSXPCConnection.setCodeSigningRequirement(_:)`:
  ```
  anchor apple generic and identifier "<app bundle id>" and certificate leaf[subject.OU] = "<TeamID>"
  ```
  `<TeamID>` is `FanControlClientTeamID` from the embedded Info.plist. If it is missing, the
  helper falls back to `FanControlHelperConstants.teamIdentifierPlaceholder` (`TEAMID0000`) and
  logs a warning, which in effect rejects every client.
- In the other direction, `HelperClient` requires this of the helper on every new connection:
  ```
  anchor apple generic and identifier "<helper label>" and certificate leaf[subject.OU] = "<TeamID>"
  ```
  This is `FanControlHelperConstants.helperCodeSigningRequirement(teamID:)`. `<TeamID>` defaults
  to `FanControlClientTeamID` from the **app's** Info.plist (`FanControlHelperConstants.clientTeamID`,
  copied there by `embed-helper-config.sh`), else the placeholder. You can also set
  `FanControlManager.shared.clientTeamID` at launch, before the first helper call.
- Every identifier, Team ID and cdhash is validated before it is put into a requirement
  (`CodeSigningRequirement`); a malformed value yields the requirement `never`, which rejects
  every peer, never a widened requirement.
- **App Sandbox:** the helper must **not** be sandboxed, because it needs AppleSMC writes and an
  XPC listener. The host app is expected to be unsandboxed as well. If you do sandbox the app,
  it needs two temporary exceptions: `com.apple.security.temporary-exception.iokit-user-client-class`
  = `AppleSMCClient` and `com.apple.security.temporary-exception.mach-lookup.global-name` = the
  helper label. See integration.md §4.
- Apple Development signing satisfies `anchor apple generic`, so a development Team ID works
  during development.

## 3. Registration (app side, SMAppService mode)

```swift
import ServiceManagement

let service = SMAppService.daemon(plistName: FanControlHelperConstants.plistName)
switch service.status {
case .notRegistered:    try service.register()                      // on the first write
case .requiresApproval: SMAppService.openSystemSettingsLoginItems() // user must approve
case .enabled:          break                                       // ready
case .notFound:         break                                       // plist missing or misnamed in the bundle
@unknown default:       break
}
```

- Right after `register()`, the status is normally `.requiresApproval`. The helper does not run
  until the user allows it in System Settings ▸ General ▸ Login Items & Extensions. Because of
  `AssociatedBundleIdentifiers`, the entry appears under the app's name.
- After approval, launchd starts the helper on demand (`RunAtLoad` = false, started on a
  `MachServices` connection).
- The app connects with
  `NSXPCConnection(machServiceName: FanControlHelperConstants.machServiceName, options: .privileged)`
  and `remoteObjectInterface = makeHelperInterface()`.
- Each call is bounded by `HelperClient.callTimeout`, 8 s by default. On timeout the call throws
  `helperConnectionFailed("timeout")` and invalidates the connection, so the helper releases the
  session and restores the fans.
- After connecting, the app calls `version(reply:)`. If `protocolVersion` differs, it runs
  `unregister()` and then `register()` once.
- To uninstall, call `try await service.unregister()`.

**Why not `SMJobBless` / `SMAuthorizedClients`:** `SMJobBless` has been deprecated since
macOS 13. It copies the helper to `/Library/PrivilegedHelperTools`, which makes updates and
removal messy. `SMAppService` keeps the helper inside the app bundle, removes it together with
the app, and uses the standard OS approval UI. The helper's Mach service name is also distinct
from other fan-control helpers (for example FanFi's `com.fanfi.fanfi.smcwrite`), so they do not
collide at the launchd level.

## 4. XPC protocol and session

`FanControlHelperProtocol` (the first `Int` of every reply is a `FanControlHelperErrorCode`):

| Method | Description |
|---|---|
| `version` | `(protocolVersion, build string)` |
| `openSession` | Opens the exclusive write session |
| `writeKey(key, bytes)` | Writes raw bytes to an allowed key. Requires the session. |
| `closeSession` | Closes the session |
| `readKeyInfo(key)` | `(rc, dataSize, typeFourCC, attributes, message)`. No session needed. |
| `setLowPowerMode(enabled)` | `(rc, message)`. Protocol 2. No session needed. See [Low Power Mode request](#low-power-mode-request). |

Error codes: `0 ok`, `1 notSessionOwner`, `2 sessionNotOpen`, `3 invalidKey`,
`4 keyNotAllowed`, `5 smcUnavailable`, `6 smcError`, `7 badRequest`,
`8 commandFailed`, `9 rateLimited` (8 and 9: Low Power Mode request only).

**Single-owner session**

- A session belongs to the XPC connection that opened it (pid + connection id). `openSession`,
  `writeKey` or `closeSession` from any other connection returns `notSessionOwner`.
- If the owner pid no longer exists, the next `openSession` reclaims the session. If
  `openSession` comes from **another connection of the same pid** (for example after a client
  timeout dropped the old connection), the old session is ended and restored first, and then
  the new connection gets it.
- Invalidation or interruption of the connection (app quit or crash) releases the session.
  As a backstop, a watchdog checks every 5 s (`SessionRegistry.ownerLivenessInterval`) that the
  owner's pid still exists and releases the session if it does not.
- Just before the first write to each key in a session, the helper records the key's current
  value. If that read fails, the write is refused with `6 smcError`.
- The helper opens AppleSMC only while a session is open. At session open it reads `FNum` and
  each fan's hardware `F<n>Mn` and `F<n>Mx`, which are used for validation.
- Each successful client write is remembered per key as `lastWritten`, the client's intent.
  Sleep/wake recovery uses it (§5). The helper's own power-handling writes are not recorded.

**Restore**, used on close, release, reclaim and helper SIGTERM, and implemented by
`HelperWritePolicy.restore`:

1. Each mode key is set to the **fixed automatic value** `F<n>Md ← 0`, not to its recorded
   value, so the state of a previous manual session is never reproduced. A failed write is
   retried once.
2. `F<n>Tg` is written back **only** for fans whose `F<n>Md` this session never wrote (a client
   that wrote only `Tg`, which `FanWriteStrategy` never does). The value is clamped to
   `Mn…Mx`.
3. `F<n>Tg` is never written for a fan handed back with `Md = 0`, because the SMC owns the
   target in automatic mode. On Apple Silicon the idle snapshot is `Tg = 0`, which is below
   `Mn`. Writing it back while `Md = 1` would command the fan to stop, and if the following
   `Md = 0` failed, the fan would stay in manual mode at 0 RPM. A fan whose mode restore failed
   also keeps its last validated target, which lies inside `Mn…Mx`, and the failure is logged.
4. Restore writes bypass value validation. The session is released whether or not they succeed.
   A failed restore is logged as a fault (`restore FAILED for F0Md …`); on SIGTERM the helper
   then exits with 74 instead of 0.

**Session state machine** (`Sources/FanControlHelper/SessionRegistry.swift`):

```
idle ──openSession──▶ open ──close / invalidation / reclaim / watchdog──▶ idle
  │                     │
  └─────SIGTERM/SIGINT──┴──SIGTERM/SIGINT (restore first)──▶ terminated (final)
```

Every way out of `open` goes through one function that leaves `open` first, stops the watchdog
and then runs the restore once (`WriteSession.finish()` is idempotent), so a restore can never run
twice or be skipped. `terminated` answers `openSession` with `5 smcUnavailable` ("the helper is
shutting down"), so nothing can be forced between the shutdown restore and process exit.

**Process lifecycle and exit statuses** (`HelperDaemon`). Start-up order: refuse unsupported
hardware or an invalid client requirement → SIGTERM/SIGINT handlers → power notifications → XPC
listener last, so no session can open before every restore path exists.

| Status | Meaning |
|---|---|
| 0 | `--print-configuration` / `--help`, or SIGTERM/SIGINT with every fan handed back (or no session) |
| 64 (`EX_USAGE`) | Unknown command-line argument (launchd passes none) |
| 74 (`EX_IOERR`) | SIGTERM/SIGINT, but a restore write failed; a fan may stay forced (see the fault log) |
| 78 (`EX_CONFIG`) | Not Apple Silicon, or invalid `FANCONTROL_CLIENT_REQUIREMENT`; exited without listening |

SIGKILL, a crash or a power cut cannot be handled; the SMC then keeps the last forced target until
the app's "Return to automatic", a reboot, or an SMC reset.

**Logging.** One subsystem (the client bundle id) and one category (`fancontrol-helper`); each
message starts with an area prefix — `Startup:`, `Config:`, `XPC:`, `Session:`, `Power:`,
`Shutdown:` — for example `eventMessage BEGINSWITH "Session:"`. Levels: `fault` = cannot serve or
a restore failed; `error` = SMC failure; `warning` = refused request or suspicious configuration;
`notice` = state transitions (persisted); `info` = connection lifecycle; `debug` = each SMC write
(`Session: wrote F0Tg=3000`, visible with `log stream --level debug`). Every interpolation is
annotated `.public`: the helper logs only pids, connection ids, key names and values, requirements
and identifiers.

The hardware test confirmed that `Md = 0` alone returns a fan to SMC control: the target jumps to
the SMC's own value immediately (see [verification/SUMMARY.md](verification/SUMMARY.md)).

**Write allowlist** (`FanControlHelperConstants.allowedWriteKeyPatterns`):

| Pattern | Purpose |
|---|---|
| `^F[0-9]Tg$` | Target RPM |
| `^F[0-9]Md$` | Fan mode (1 = manual, 0 = automatic) |

Every other key is refused with `4 keyNotAllowed`, including `F<n>Mn` (read-only, attribute
`0x84`, on Apple Silicon) and any model-specific unlock key. `HelperWritePolicy.validate` also rejects any
key other than `F<n>Md` and `F<n>Tg` with `7 badRequest`, as defence in depth behind the
allowlist. A key must also be 4 ASCII characters, the payload must be 1–32 bytes **and** equal to
the SMC's `dataSize`, and the SMC attributes must include the write bit `0x40`
(`SMCKeyInfo.isWritable`); otherwise the write fails with `7 badRequest`.

**Value validation.** The payload is decoded with `SMCCodec.decode` according to the key's type
(`HelperWritePolicy.validate`):

| Key | Condition | On violation |
|---|---|---|
| `F<n>Md` | 0 or 1 | `7 badRequest` |
| `F<n>Tg` | Within the hardware `F<n>Mn…F<n>Mx` read at session open, ±1 RPM | `7 badRequest` (`6 smcError` if Mn/Mx could not be read) |
| anything else | always | `7 badRequest` |

A client-side `SafetyPolicy.enforceHardwareMinimum = false` only affects planning. A target below
the minimum is refused by `FanWriteStrategy` before any write (`.rpmOutOfRange`) and again by the
helper. The helper does not rate-limit writes. Instead, the client skips poll-driven writes whose
target changed by ≤ 25 RPM ([kit.md](kit.md)).

### Write sequence (Apple Silicon)

- Write `F<n>Md ← 1` first and then `F<n>Tg`, because a `Tg` written in automatic mode may be
  overwritten or rejected by the SMC. `F<n>Md ← 0` returns the fan to automatic control.
- A fan without `F<n>Md` is not controlled: the client throws `fanModeKeyMissing` and does not
  fall back to writing only `Tg`.
- If a write fails between `Md = 1` and `Tg`, the client rolls the fan back with `Md ← 0`
  (kit.md, "Partial failure").
- On Mac14,9 with macOS 26, `F<n>Md` and `F<n>Tg` are enough; no unlock key is needed. The
  attributes are `F<n>Md` = `0xd0` (`ui8 `) and `F<n>Tg` = `0xd4` (`flt `), both with `0x40`,
  and `F<n>Mn` = `0x84`, without `0x40`. Other models are untested.
- Encoding (`flt `, little-endian Float32) is done by the client (`FanControlCore.SMCCodec`). The
  helper writes the validated bytes as they are.

### Low Power Mode request

<!-- F2: power profiles (DynamicNotchApp/docs/power-profiles.md). -->

Protocol version **2** adds one dedicated request, `setLowPowerMode(_ enabled: Bool)`, used by
power profiles. Changing Low Power Mode needs root; reading it does not. The request is not a
generic command runner:

- **Fixed argv, no shell.** The helper runs `/usr/bin/pmset` (absolute path, never looked up
  through `PATH`) through `Process` with an empty environment plus a fixed `PATH`. The only
  client input is the `Bool`; no client string reaches the command line.
- **Allowlist.** `LowPowerModeCommand.allowedInvocations` holds the only three argv the
  handler may run: `-a lowpowermode 1`, `-a lowpowermode 0` and `-g`. Every invocation is checked
  against it before it runs (`LowPowerModeCommand.isAllowed`).
- **Read first, write only on change.** `pmset -g` is read first; if Low Power Mode already has
  the requested value the reply is `ok` and nothing is written.
- **Rate limit.** At most 6 writes per 60 s (shared by all connections); past that the reply is
  `9 rateLimited` and nothing runs. A no-op request is still answered.
- **Read-back.** After the write, `pmset -g` is read again and parsed
  (`LowPowerModeCommand.parseLowPowerMode`: the `lowpowermode` line of the "Currently in use"
  section; `powermode` 1 on Macs that also have High Power Mode). A mismatch is
  `8 commandFailed`; an unreadable state is `ok` with "not confirmed" in the message.
- **Failure.** A non-zero pmset exit (or a 10 s timeout) is `8 commandFailed`, with the first
  line of pmset's stderr (at most 200 characters) in the message.
- **Logging.** Every request is logged with the caller's pid (`fancontrol-helper` category):
  the request, a skipped write, the refusal, the pmset failure and the read-back.
- **No session.** The request changes a system setting, not a fan, so it does not need (or
  open) the fan write session; the connection itself has already passed the code-signing
  requirement. The helper does **not** restore Low Power Mode on exit: it is a persistent system
  setting, and giving the user's value back is the app's job (`PowerProfileEngine`).
- `-a` sets the value for every power source, like "Always" / "Never" in System Settings ▸
  Battery ▸ Low Power Mode. A per-source choice ("Only on Battery") is replaced by the plain
  value; giving the value back writes the plain value too.

Code: `Sources/FanControlXPC/LowPowerModeCommand.swift` (allowlist, parser, `ProcessCommandRunner`,
`LowPowerModeRequestHandler`; unit-tested with a fake pmset in `LowPowerModeCommandTests`),
`Sources/FanControlHelper/LowPowerModeService.swift` (XPC entry point). App side:
`HelperClient.setLowPowerMode(_:)` and `FanControlManager.setLowPowerMode(_:)`, which never
registers the helper by itself and requires protocol ≥ `lowPowerModeProtocolVersion` (an older
helper → "re-run install.sh"). End-to-end over a real `NSXPCConnection`:
`LowPowerModeEndToEndTests`.

Manual check (read-only): `pmset -g | grep lowpowermode`. The helper log:
`/usr/bin/log stream --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'`.

## 5. Manual testing on a Mac

```sh
sudo launchctl print system/<label>
/usr/bin/log stream --level debug --predicate 'subsystem == "<subsystem>" AND category == "fancontrol-helper"'
launchctl plist __TEXT,__info_plist YourApp.app/Contents/MacOS/FanControlHelper   # embedded Info.plist
codesign -dvvv --entitlements - YourApp.app/Contents/MacOS/FanControlHelper
codesign -d -r- YourApp.app
```

In zsh, use `/usr/bin/log`, because the plain name `log` is a shell builtin.

Checklist:

1. `version` returns `(1, "1.0 (1)")`.
2. `openSession` → `writeKey("F0Md", [1])` → `writeKey("F0Tg", <flt>)` changes the speed (read
   `F0Ac` to confirm).
3. A key outside the allowlist (for example `TC0P`) returns `4 keyNotAllowed`, and a size
   mismatch returns `7 badRequest`.
4. `openSession` from a second signed process returns `1 notSessionOwner`.
5. Sleep and wake with a session open. The log shows the hand-back and the wake recovery, and
   `fanfi-probe --watch 1` shows no persistent `manual(0)` after wake (see the next subsection).
6. `kill -9` the app during manual control. The log shows "went away; releasing session" and
   the fans return to automatic. `sudo launchctl kill SIGTERM system/<label>` does the same
   ("SIGTERM received"). An out-of-range `Tg`, `F0Md = 2`, or a write to `F0Mn` returns
   `7 badRequest` / `4 keyNotAllowed`. After the restore, `F0Md` is 0 and `F0Tg` is **not**
   written back.
7. An unsigned client, or one with another Team ID, is invalidated immediately.
8. After `SMAppService.daemon(plistName:).unregister()`, `launchctl print` no longer shows the
   service.

### Sleep / wake

**Background.** Across sleep, the SMC resets `F<n>Tg` to 0 and keeps `F<n>Md = 1`, including on
fans that were automatic before the sleep. Without countermeasures, fans wake "manual, target 0",
which means stopped. The helper is the safety authority, so it handles this itself and does not
rely on the app.

**Observed mechanism (hardware retest).** Even when the helper handed a fan back with `Md = 0`
before sleep, the SMC wakes **every fan at `F<n>Md = 3`, `Tg = 0`**, a transient that is neither
manual nor automatic. One to two seconds later the SMC returns the fans to `Md = 0` itself. A `Tg`
written during the transient is discarded at that point. So the brief "manual, target 0" right
after wake comes from the SMC, not from our writes. In the retest, `manual(0)` appeared in only
one sample, the profile was restored after about 2 s, and the RPM caught up after about 6 s.
Before the fix, restoring took about 5 s.

**Implementation.** `PowerObserver` (`Sources/FanControlHelper/PowerObserver.swift`) registers
with `IORegisterForSystemPower`. The helper runs under `dispatchMain()` and has no main CFRunLoop,
so the notification port is attached to a dedicated serial queue with
`IONotificationPortSetDispatchQueue`. The actor's executor is that queue, and the IOKit callbacks
use `assumeIsolated` on it. All decisions are made in `FanControlXPC.PowerTransitionPolicy`, which
is pure and tested. `SessionRegistry` executes them under its lock. These writes go through the
same validation as client writes.

| Notification | Action |
|---|---|
| `kIOMessageCanSystemSleep` | Always allowed (`IOAllowPowerChange`); the helper never vetoes sleep |
| `kIOMessageSystemWillSleep` | With a session open, each fan the session is forcing (last `Md` write ≠ 0) is handed back with `F<n>Md ← 0`. `Tg` is not written, and the session and the client's intent are kept. Then `IOAllowPowerChange` is called regardless of the result. |
| `kIOMessageSystemHasPoweredOn` | Recovery attempts at 0, 1 and 3 s (`PowerTransitionPolicy.wakeRetryDelays`). The later attempts run after the `Md = 3` transient has ended. Each attempt re-reads the fans, so it is idempotent. A new sleep cancels the remaining attempts. |

Each wake attempt with a session open (`PowerTransitionPolicy.wakeRecovery`) works like this:

- Any non-zero `Md` counts as manual, including the transient 3. Attempt 1 therefore sees
  `Md = 3`, writes only `Tg`, and that write does not stick. Attempt 2 sees `Md = 0` and writes
  `Md ← 1` and then `Tg`, which sticks. This is the expected pattern.
- For a remembered fan (forced, with a recorded target), the helper writes `Md` (the last value)
  and then `Tg` (the last target) if the fan is not manual. If the fan is manual but `Tg` is more
  than 5 RPM off, only `Tg` is written.
- Any other fan in manual mode (no recorded target, for example one the SMC woke as manual, or one
  where only `Md = 1` succeeded) is handed back with `Md ← 0`.
- Write order: `Md` writes in fan order, then `Tg` writes. Because the memory holds the client's
  latest writes, an app that changes the target after wake is followed by the later attempts.

If the Mac wakes without a session, attempt 1 reads the fans and only **logs a warning** for
manual fans; another tool may own them.

Log lines (notice level or above, so they are persisted; use `log show --last 10m --predicate …`):

```
Power: registered for system sleep/wake notifications
Power: system will sleep; session of pid 1234 open, handed back to the SMC: F0Md=0; remembered targets: F0 3000
Power: system will sleep; no session open, nothing to hand back
Power: system has powered on; wake recovery at 0.0s, 1.0s, 3.0s
Power: wake recovery 1/3 (session of pid 1234): observed F0 Md=3 Tg=0, F1 Md=3 Tg=0; wrote F1Md=0, F0Tg=3000
Power: wake recovery 2/3 (session of pid 1234): observed F0 Md=0 Tg=0, F1 Md=0 Tg=0; wrote F0Md=1, F0Tg=3000
Power: wake recovery 3/3 (session of pid 1234): fans already match (F0 Md=1 Tg=3000, F1 Md=0 Tg=0)
Power: system has powered on; no session open but fan(s) 0,1 are in manual mode - not writing (another tool may own them)
Power: IORegisterForSystemPower failed; sleep/wake fan handling is disabled
```

Failed writes appear on the same line, for example `F0Tg=3000 FAILED (<reason>)`. The app side
also re-applies the active profile at 0, 2 and 5 s after wake, and its polls detect fans that are
manual with `Tg < Mn` (kit.md, "Sleep/wake" and "State drift").

Known limits: `HasPoweredOn` also arrives on DarkWake, so during a DarkWake a session keeps
running at its remembered targets until the next `WillSleep`. Sleep while the helper is killed or
crashed is not covered.

## 6. Manual install (developer / personal-use mode)

This mode is for people **without an Apple Developer Program Team ID**. Instead of using
`SMAppService`, the helper is installed by hand as a plain LaunchDaemon, and the app and helper
can be **ad-hoc signed** (`CODE_SIGN_IDENTITY = -`). If the environment variable described below
is absent, the helper behaves exactly as in SMAppService mode. A usage guide is in
[`Support/manual-install/README.md`](../Support/manual-install/README.md).

### How it compares

| | SMAppService (§1–§3) | Manual install |
|---|---|---|
| Registration | App calls `register()`, user approves | User runs `sudo Support/manual-install/install.sh <App.app>` |
| Helper location | `App.app/Contents/MacOS/FanControlHelper` (`BundleProgram`) | `/Library/PrivilegedHelperTools/<label>` (root:wheel 0755, `Program`) |
| plist | `App.app/Contents/Library/LaunchDaemons/<label>.plist` | `/Library/LaunchDaemons/<label>.plist` (root:wheel 0644) |
| Helper checks app | `anchor apple generic and identifier "<app>" and certificate leaf[subject.OU] = "<TeamID>"` | `identifier "<app>" and cdhash H"<app cdhash>"` (from the plist's `EnvironmentVariables` → `FANCONTROL_CLIENT_REQUIREMENT`) |
| App checks helper | `anchor apple generic and identifier "<label>" and certificate leaf[subject.OU] = "<TeamID>"` | `identifier "<label>" and cdhash H"<installed helper cdhash>"` |
| Status in the app | `HelperInstallStatus.enabled` etc. | `.installedManually` |
| Removal | `unregister()` / System Settings | `sudo …/uninstall.sh` |

Both modes use the same label and Mach service name. **Never install both at once.**
`install.sh` aborts if a job from SMAppService is loaded (its `launchctl print` path is not the
manual plist). The app never calls `SMAppService` while the manual files exist.

The template `Support/manual-install/FanControlHelper.manual.plist` is filled in by `install.sh`
(`Label`, `MachServices`, `Program` and the requirement, from the helper's embedded identifiers):

```xml
<key>Label</key>        <string><label></string>
<key>Program</key>      <string>/Library/PrivilegedHelperTools/<label></string>
<key>MachServices</key> <dict><key><label></key><true/></dict>
<key>EnvironmentVariables</key>
<dict>
    <key>FANCONTROL_CLIENT_REQUIREMENT</key>
    <string>identifier "<app bundle id>" and cdhash H"<40 hex digits>"</string>
</dict>
<key>RunAtLoad</key>    <false/>      <!-- on demand, via the Mach service -->
<key>ProcessType</key>  <string>Adaptive</string>
```

The template's placeholder value (`__FILLED_IN_BY_INSTALL_SH__`) fails validation, so a template
installed by mistake makes the helper refuse to start. `AssociatedBundleIdentifiers` is not
needed in this mode.

### Helper side: `FANCONTROL_CLIENT_REQUIREMENT`

At launch, `HelperConfiguration.resolveClientRequirement()` decides the client requirement. The
pure logic is `FanControlHelperConstants.resolveClientRequirement(environment:teamID:)`.

- **Variable absent:** the Team ID requirement is used, and the helper logs
  `Client requirement mode: Team ID (SMAppService)`.
- **Present and well-formed:** that requirement is used, and the helper logs
  `Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to <cdhash>`.
  The Team ID is ignored.
- **Present but invalid** (empty, bundle id only, no cdhash, an `or` clause, …): the helper logs a
  fault, `Refusing to start: invalid FANCONTROL_CLIENT_REQUIREMENT …`, and **exits with code 78
  without opening the listener**. It never falls back to a weaker requirement.

The value must **exactly** equal the string that
`FanControlHelperConstants.manualModeClientRequirement(cdhash:)` builds. Surrounding whitespace is
allowed, and the hex digits may be upper or lower case:

```
identifier "<app bundle id>" and cdhash H"<40 hex digits>"
```

A substring match would also accept a loosened requirement such as
`… and cdhash H"…" or anchor apple`, which is why the match is exact. The string must also compile
with `SecRequirementCreateWithString`. `install.sh` writes the same format (`client_requirement`
in `common.sh`), and `ManualInstallScriptConsistencyTests` checks that the scripts, the template
and the Swift constants agree.

### Threat model

- **What limits the damage is the helper's own write validation** (the allowlist plus the
  hardware range checks, §4). A client that passes the identity check can only ask for "allowed
  fan keys, within that fan's `Mn…Mx`, mode 0/1". The helper restores automatic control on
  disconnect and exit. At worst a client can do what the app itself can do: run the fans at max
  or pin them at minimum. It cannot write arbitrary SMC keys or values out of range.
- **In manual mode, any process running as the logged-in user's uid is inside the trust
  boundary.** Pinning the cdhash stops a *different build* from connecting. It does not stop a
  malicious process of the same user from using the helper through the pinned app:
  - The requirement checks only the **main executable's code directory**:
    `setCodeSigningRequirement` validates the peer's dynamic code, not the bundle seal.
  - If the app has `com.apple.security.get-task-allow` (which Xcode injects into Debug builds),
    the same user can attach with `task_for_pid` / `lldb -p` and inject code that still satisfies
    the pinned cdhash.
  - If the app has `com.apple.security.cs.disable-library-validation`, a framework replaced
    inside the user-writable bundle loads without changing the cdhash.
  - The same holds in Team ID mode if the app has the same entitlements.
- **`install.sh` warns** when the app to be pinned has either entitlement. It does not abort.
  - **Remove `get-task-allow`.** Pin a Release build, or a Debug build with
    `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, and check with
    `codesign -d --entitlements - --xml <App.app>`.
  - **Keep `disable-library-validation` if you embed frameworks.** Ad-hoc signatures have no Team
    ID, and with Hardened Runtime, library validation only loads libraries with the same Team ID
    or signed by Apple, so the app would not launch without it. Keep the app bundle writable only
    by you.
- **A requirement with only the bundle id can be spoofed.** Anyone can ad-hoc sign a binary with
  any identifier (`codesign -s - -i <app bundle id>`). The helper therefore refuses to start
  without a cdhash.
- **A cdhash is the hash of the code directory**, which binds the main executable's contents and
  the sealed Info.plist and resources. No other binary can have the same cdhash, so a rebuilt
  app, a different app, or the sample app cannot connect.
- The requirement string is stored in a root-owned plist (0644). Only root can change it, and
  root could write to the SMC without the helper anyway, so this adds no attack surface.
- **App → helper check.** At connect time, `HelperClient` reads the cdhash of the root-owned
  `/Library/PrivilegedHelperTools/<label>`. It first checks that the file and its directory are
  owned by uid 0 and are not group- or other-writable, and that the code passes
  `SecStaticCodeCheckValidity`. The client then pins that cdhash. Only root can place that file,
  and only root can register a system-domain Mach name. This check mainly prevents a different
  binary from answering on the same name; SMC safety comes from the helper's validation.
- **Weaknesses:** (1) every rebuild changes the cdhash, so `install.sh` must be re-run (the app's
  error messages say so); (2) there is no Gatekeeper or notarization; (3) this mode is not for
  distribution; (4) you must trust everything that runs as your user.

### App side

- Requirement selection uses
  `FanControlHelperConstants.helperRequirementMode(appTeamID:manualInstallDetected:)`. If the
  running app's own signature has no Team ID (`kSecCodeInfoTeamIdentifier` is nil) **or** the
  manual files exist, the app pins the cdhash; otherwise it uses the Team ID requirement.
- `HelperInstaller.status()` returns `.installedManually` when **both** files exist, and
  `.unknown("manual installation incomplete …")` when only one does. `register()` is a no-op in
  manual mode, and `unregister()` throws "use sudo uninstall.sh".
- If a manually installed helper reports a different protocol version, the app asks you to re-run
  `install.sh` instead of re-registering.

### When the pinned cdhash does not match

If you rebuild or replace the app without re-running `install.sh`, or if you installed the helper
for a different app, the helper rejects every request from this app. The helper log shows
`Accepted connection N from pid …`, immediately followed by `Connection N … invalidated`.

The app then behaves as follows (kit.md, "Helper connection lifecycle"):

- **It does not connect.** Before connecting, `HelperClient` compares the cdhash pinned in the
  root-owned plist (0644, readable without root) with its own. On a mismatch it enters a rejected
  state and never connects. If the check cannot decide (for example, the plist is unreadable),
  the client connects, and two consecutive drops without a reply count as a rejection. A helper
  signature that fails the app's requirement (`NSXPCConnectionCodeSigningRequirementFailure`) is
  rejected at once.
- **It does not retry automatically.** The rejection lasts until the user clicks "Check Again",
  the app is relaunched, or `install.sh` is re-run, which changes the size and mtime of the plist
  and the helper binary. Meanwhile, every action fails immediately without connecting. Other
  failures back off from 2 s, doubling up to 5 min.
- **The fix:** run `sudo ./install.sh <this app>`, then click "Check Again".
  `./status.sh <App.app>` also checks the match.

### Procedure

```sh
# 0. Build ad-hoc. With Hardened Runtime, set ENABLE_DEBUG_DYLIB = NO for Debug (see Notes).
cd FanControl/Tools/HelperSmokeApp && xcodegen generate && \
  xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
APP="$PWD/.derivedData/Build/Products/Debug/FanControlSmoke.app"
cd ../../Support/manual-install

./install.sh --dry-run "$APP"   # 1. preview: no root needed, changes nothing
sudo ./install.sh "$APP"        # 2. install
./status.sh "$APP"              # 3. read-only status and pin check
sudo ./install.sh "$APP"        # 4. after every rebuild
sudo ./uninstall.sh             # 5. remove (bootout → SIGTERM → helper restores fans)
```

What `install.sh` does (with `set -euo pipefail`; it is idempotent):

1. Checks that `<App>/Contents/MacOS/FanControlHelper` exists, checks the app's
   `CFBundleIdentifier`, runs `codesign --verify --strict` on both, and checks both signing
   identifiers.
2. Gets the app's cdhash from the `CDHash=` line of `codesign -dvvv`, and checks that there is
   exactly one line with 40 hex digits. For a universal binary, it picks the host slice
   (`uname -m`) with `--arch`. If that slice is missing, or a thin binary has a different
   architecture, it aborts.
3. Warns if the helper has `com.apple.application-identifier` (Xcode injects it), and if the app
   has `get-task-allow` or `disable-library-validation`.
4. Aborts if a job with the same label from SMAppService is loaded.
5. Generates the plist from the template with `plutil -replace` and runs `plutil -lint`.
6. Boots out the old job if one is loaded and waits for it. It then installs the helper as
   root:wheel 0755 and re-verifies its signature and cdhash, installs the plist as root:wheel
   0644, and runs `launchctl enable` and `launchctl bootstrap system <plist>`, followed by a
   summary from `launchctl print`.

`--dry-run` needs no root. It runs the verification and generates the plist, prints the plist,
and only prints the commands that would change anything.

`uninstall.sh` (also `--dry-run`) only removes what `install.sh` wrote. It refuses `com.apple.*`
labels and a `/Library/LaunchDaemons/<label>.plist` without `FANCONTROL_CLIENT_REQUIREMENT` (so a
mistyped label cannot stop and delete another vendor's daemon), refuses to boot out a loaded job
whose plist is missing, and without the plist removes `/Library/PrivilegedHelperTools/<label>` only
if its signing identifier is the helper identifier.

### Notes

- **Debug dylib.** By default, Xcode 26 Debug builds split the app into a stub plus
  `<App>.debug.dylib`. With ad-hoc signing and Hardened Runtime, library validation refuses that
  dylib (`mapping process and mapped file (non-platform) have different Team IDs`), and **the app
  does not launch**. Set `ENABLE_DEBUG_DYLIB = NO`, or build Release.
- **`com.apple.application-identifier`.** Xcode injects this entitlement into Command Line Tool
  targets, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` does not remove it. In manual mode with
  ad-hoc signing, AMFI logs "restricted entitlements failed to validate (-67688)", but
  AppleSystemPolicy allows the launch, and the helper ran as root. For Developer ID signing
  without a provisioning profile, this has not been verified. Check it with
  `codesign -d --entitlements -`.
- Since macOS 13, a job in `/Library/LaunchDaemons` appears under Login Items & Extensions ▸
  Allow in the Background, and adding one may show a notification. If the user turns it off there,
  the job does not start.
- Do not register through SMAppService while the manual install is present. Run
  `sudo uninstall.sh` first.
