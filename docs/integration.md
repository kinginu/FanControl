# Integrating FanControl into an app

This guide covers adding the package and the privileged helper to a macOS app's Xcode project,
and checking the result on hardware. Related documents:

- [helper.md](helper.md): the helper itself (signing, registration, XPC, sessions, safety checks,
  sleep/wake, manual install)
- [kit.md](kit.md): the app-side `FanControlKit` (threading, polling, control loop, profiles and
  curves, thresholds, persistence)
- [verification/SUMMARY.md](verification/SUMMARY.md): what has been verified on hardware

Requirements: Apple Silicon only, Swift tools 6.0, Swift 6 language mode, and a deployment
target of **macOS 26** for the package and your app target. On a Mac that is not arm64, the kit
refuses to open the SMC (`FanControlError.unsupportedPlatform`) and the helper exits at launch.

Identifiers are Info.plist keys read at runtime by both the app and the helper (helper.md,
"Configuring identifiers"); set them for your app, no Swift changes needed:

| Role | Key | Default (DynamicNotch) |
|---|---|---|
| App bundle id | `FanControlClientBundleIdentifier` | `com.example.dynamicnotch.DynamicNotch` |
| Helper signing identifier | `FanControlHelperIdentifier` | `com.example.dynamicnotch.DynamicNotch.fanfi` |
| Mach service = launchd label | `FanControlMachServiceName` | = helper identifier |
| Team ID (SMAppService only) | `FanControlClientTeamID` | not set (`TEAMID0000` placeholder) |

## 0. Parts

| Path | Contents |
|---|---|
| `Package.swift` | The libraries `FanControlCore`, `FanControlSMC`, `FanControlXPC` and `FanControlKit`. The executables `FanControlHelper` (Linux/CI build checks only; **do not ship it**, see §2) and `fanfi-probe` (read-only diagnostics). |
| `Support/Helper-Info.plist` | Info.plist embedded in the helper; template for the identifier keys |
| `Support/embed-helper-config.sh` | App Run Script: copies the identifier keys into the app and generates the launchd plist (§3) |
| `Support/LaunchDaemons/<label>.plist` | The launchd plist for SMAppService with the default identifiers |
| `Support/manual-install/` | Scripts for the manual-install mode ([README](../Support/manual-install/README.md)) |
| `Tools/HelperSmokeApp/` | A minimal XcodeGen host app that implements §1–§4 and served as the hardware test bench |

## 1. Add the package and link it

1. In Xcode, choose **File ▸ Add Package Dependencies… ▸ Add Local…** and select the folder
   that contains `Package.swift`. The paths below assume `$(SRCROOT)/FanControl`.
2. In the app target's **Frameworks, Libraries, and Embedded Content**, add `FanControlCore` and
   `FanControlKit`. `FanControlSMC` and `FanControlXPC` come along transitively.
3. The kit has no third-party dependencies. It does not depend on your settings store: the app
   copies its settings into the manager (kit.md, "Settings owned by the app").

With XcodeGen, give the local package reference a `group:`. Without one, it can clash with a
source group that points to the same folder.

## 2. Helper target

First choose your identifiers (helper.md, "Configuring identifiers"): the app's bundle id
(`FanControlClientBundleIdentifier`), the helper's signing identifier
(`FanControlHelperIdentifier`) and the Mach service / launchd label (`FanControlMachServiceName`,
defaults to the helper identifier). Copy `FanControl/Support/Helper-Info.plist` into your project
(e.g. `Config/Helper-Info.plist`), set those keys and `CFBundleIdentifier` (= helper identifier),
and point the steps below at your copy. No Swift code changes: both binaries read the keys at
runtime. With no keys at all, the DynamicNotch defaults apply.

Build the helper **only as an Xcode Command Line Tool target**. If you ship the SwiftPM executable
product instead, SwiftPM does not embed `Helper-Info.plist`, the helper falls back to the Team ID
placeholder, and it rejects every client (helper.md §1).

1. Choose **File ▸ New ▸ Target ▸ macOS ▸ Command Line Tool**, named `FanControlHelper`, in Swift.
2. Delete the generated `main.swift` and add `FanControl/Sources/FanControlHelper/*.swift` as file
   references; do not copy them.
3. Add `FanControlCore`, `FanControlSMC` and `FanControlXPC` to the target's frameworks. They are
   linked statically; `otool -L` shows no package dylibs.
4. Build settings (verified with Xcode 26.6 in `Tools/HelperSmokeApp`):
   - `PRODUCT_NAME = FanControlHelper`
   - `PRODUCT_BUNDLE_IDENTIFIER = <FanControlHelperIdentifier>`. This becomes the signing
     identifier, which the app requires (`FanControlHelperConstants.helperCodeSigningRequirement`).
   - `OTHER_LDFLAGS = $(inherited) -sectcreate __TEXT __info_plist "$(SRCROOT)/Config/Helper-Info.plist"`
     (your copy; `$(SRCROOT)/FanControl/Support/Helper-Info.plist` for the defaults). Keep the
     quotes, because the path may contain spaces. Xcode does not relink when only the plist
     changes; clean or touch a helper source after editing it.
   - `GENERATE_INFOPLIST_FILE = NO`, `CREATE_INFOPLIST_SECTION_IN_BINARY = NO`, and an empty
     `INFOPLIST_FILE`. With `GENERATE_INFOPLIST_FILE = YES` alone, the generated plist does not
     reach the binary, so that setting is harmless. With
     `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` plus an `INFOPLIST_FILE`, Xcode passes a second
     `-sectcreate`. That did not fail the link, but nothing guarantees which copy wins, so
     avoid it.
   - `ENABLE_HARDENED_RUNTIME = YES`, `SKIP_INSTALL = YES`
   - `MACOSX_DEPLOYMENT_TARGET` the same as the app's (26.0)
   - Sign the helper the same way as the app (`CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`,
     `CODE_SIGN_IDENTITY`).

The project then needs exactly two targets: your app, and `FanControlHelper`. The package's own
`FanControlHelper` product is never built unless something references it, and the shared name
does not cause a clash.

## 3. Embed the helper in the app

In the app target:

1. **Build Phases ▸ Target Dependencies**: add `FanControlHelper`.
2. Add a **Copy Files** phase, destination **Executables** (= `Contents/MacOS`):
   `FanControlHelper`, with Code Sign On Copy checked. The copy is re-signed with
   `--preserve-metadata=identifier,entitlements,flags`, which keeps the identifier and the
   runtime flag.
3. Set `PRODUCT_BUNDLE_IDENTIFIER` to `FanControlClientBundleIdentifier` and
   `ENABLE_USER_SCRIPT_SANDBOXING = NO`, and add a **Run Script** phase after the Copy Files
   phase, with Input Files `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` (orders it after
   ProcessInfoPlistFile; without it the two race and the keys can be lost) and your
   Helper-Info.plist:
   ```sh
   "${SRCROOT}/FanControl/Support/embed-helper-config.sh" "${SRCROOT}/Config/Helper-Info.plist"
   ```
   It checks the app's bundle id against the plist, copies the four `FanControl*` keys into the
   built app's Info.plist (the app reads them at runtime), and writes
   `Contents/Library/LaunchDaemons/<label>.plist` (`Label`, `MachServices`,
   `AssociatedBundleIdentifiers`, `BundleProgram`). Run Script phases run before code signing.
   *Alternative with the default identifiers only* (what DynamicNotchApp does): skip the script
   and add a second Copy Files phase, destination **Wrapper**, subpath
   `Contents/Library/LaunchDaemons`, with `FanControl/Support/LaunchDaemons/<label>.plist`.
4. Check the built bundle:
   ```
   YourApp.app/Contents/MacOS/FanControlHelper
   YourApp.app/Contents/Library/LaunchDaemons/<label>.plist
   ```
   The plist file name must equal `FanControlHelperConstants.plistName` (`<FanControlMachServiceName>.plist`);
   otherwise `SMAppService` reports `.notFound`. Its `BundleProgram` is
   `Contents/MacOS/FanControlHelper`, relative to the bundle root. To see what each side
   resolved: `plutil -p YourApp.app/Contents/Info.plist | grep FanControl` and
   `YourApp.app/Contents/MacOS/FanControlHelper --print-configuration`.

## 4. Signing

### SMAppService mode (default, Team ID)

1. Put your Team ID in your `Helper-Info.plist` (`FanControlClientTeamID`). The helper reads
   this value to check the app.
2. The app needs the same value: `embed-helper-config.sh` copies `FanControlClientTeamID` into
   the app's Info.plist, where it becomes the default of `FanControlManager.clientTeamID` (what
   the app requires of the helper). Without the script, add the key to the app's Info.plist, or
   set `FanControlManager.shared.clientTeamID = "<TeamID>"` at launch, before the first helper
   call. If neither is set, the placeholder `TEAMID0000` is used and every helper connection
   fails. No Swift constant needs editing.
3. Sign the app and the helper with the **same Team ID**, with **Hardened Runtime** on both, and
   notarize the app when you distribute it.
4. Verify:
   ```sh
   codesign -dvvv --entitlements - YourApp.app/Contents/MacOS/FanControlHelper   # Identifier, TeamIdentifier, flags include runtime (0x10000)
   launchctl plist __TEXT,__info_plist YourApp.app/Contents/MacOS/FanControlHelper   # embedded Info.plist
   codesign -d -r- YourApp.app
   codesign --verify --deep --strict -v YourApp.app
   ```
   `otool -s __TEXT __info_plist` prints only hex, and on arm64 even
   `otool -X … | xxd -r -p` scrambles the word byte order. Use `launchctl plist` or
   `segedit <bin> -extract __TEXT __info_plist out.plist` instead.
   - **Ad-hoc signing:** Xcode 26.6 ignores `ENABLE_HARDENED_RUNTIME` when signing ad hoc (the
     result is `flags=0x2(adhoc)`). Add `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime`.
   - **After real signing, check the helper's entitlements.** Xcode injects
     `com.apple.application-identifier` into Command Line Tool targets, and
     `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` does not remove it. Whether launchd accepts this
     under Developer ID signing without a profile has **not been verified**.

### Manual-install mode (developers / personal use, no Team ID)

Keep the targets and Copy Files phases from §1–§3 as they are. Build the app and the helper
**ad-hoc** (`CODE_SIGN_IDENTITY = -`, plus `--options=runtime` as above) and run
`sudo Support/manual-install/install.sh <YourApp.app>` (helper.md §6). You do not need to replace
the Team ID. The plist inside the bundle is not used; `install.sh` takes the label and both
identifiers from the helper's embedded Info.plist.

- Re-run `install.sh` after every rebuild, because the cdhash changes.
- For Debug builds, set **`ENABLE_DEBUG_DYLIB = NO`**, or build Release. Otherwise library
  validation refuses the debug dylib and the app does not launch.
- For the build you pin, avoid `get-task-allow` (use Release or
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`). See the threat model in helper.md §6.
- This mode is for personal use only, and must never be installed alongside an SMAppService
  registration.

### App Sandbox

Do **not** sandbox the app; this is the recommended setup. If you must, add these two temporary
exceptions; without them, both the in-app SMC reads and the XPC connection fail:

| Key | Value (array) |
|---|---|
| `com.apple.security.temporary-exception.iokit-user-client-class` | `AppleSMCClient` |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | `<FanControlMachServiceName>` |

Mac App Store review may reject temporary exceptions, so plan on Developer ID distribution. The
helper itself is never sandboxed.

## 5. UI and app wiring

The core libraries contain no views. Host-independent SwiftUI lives in the separate product
`FanControlUI` (`Sources/FanControlUI/`: the settings pane and its General / Profiles / Sensors
tabs, the curve view and editor, temperature charts, the alert coordinator and the settings
storage; kit.md, "UI layer"). Link it alongside `FanControlCore` / `FanControlKit`. DynamicNotch
adds only its host glue from `DynamicNotchIntegration/` (widgets, widget settings, the live
activity view and the Nook hooks; PATCHES.md). Whatever draws the UI, the app has to wire up the
following:

1. At launch: copy your settings into the manager (`pollingInterval`, `slowPollingOnBattery`,
   `reapplyProfileAfterWake`, `keepAlertsWhilePaused`, thresholds through
   `applySafetyThresholds(_:)`), then call `startMonitoring()` if the feature is enabled. Do it
   again whenever a setting changes. Profiles are persisted by the kit itself (kit.md,
   "Persistence").
2. Visibility: when your UI is hidden, call `setMonitoringPaused(true)`. Views that must show live
   data regardless use `setLiveDataHold(_:for:)`.
3. Alerts: observe `.fanControlHighTemperatureChanged`, `.fanControlFanAnomalyChanged`,
   `.fanControlDidUpdate` and `.fanControlConflictingControllersChanged`.
4. Termination: nothing to do. The manager returns the fans to automatic on
   `NSApplication.willTerminateNotification`. Do not add your own wake re-apply either; the
   manager already does it (kit.md, "Sleep/wake").
5. Apply profiles with `profile.resolved(for: manager.fans)`, so that presets defined through
   `defaultMode` are stored with explicit per-fan modes. `applyProfile` also opens the session
   for an unresolved preset (manual `defaultMode`), e.g. one applied before the first poll has
   published `fans` (kit.md, "Profiles").
6. Handle `HelperInstallStatus` (`.requiresApproval`: show
   `FanControlManager.helperApprovalInstructions`; `.installedManually` /
   `.installedManuallyMismatch`) and `HelperConnectionState.rejected(reason:)`. The fix for the
   latter is "re-run `sudo install.sh <this app>`, then Check Again".

## 6. Hardware verification checklist (Phase 1 → 5)

Run these in order on Apple Silicon hardware, ideally several models including a fanless
MacBook Air. Items marked [x] were verified on Mac14,9 with macOS 26.5. The evidence is
summarised in [verification/SUMMARY.md](verification/SUMMARY.md); the detailed logs are in
Japanese.

### Phase 1: reading (no helper)

```sh
swift run fanfi-probe            # model, key count, fans, temperatures, aggregates
swift run fanfi-probe --dump     # every key: type, size, attributes, raw bytes
swift run fanfi-probe --watch 2  # refresh fans and temperatures every 2 s
swift run fanfi-probe --json     # the same snapshot as JSON, for scripts
```

`fanfi-probe` is read-only and needs no `sudo`. Its exit status is meant for scripts: `0` success
(for `--fan-stats`, every fan PASS), `1` a `--fan-stats` FAIL or no fans, `2` an invalid command
line, `3` the SMC could not be opened. `--dump` cannot be combined with `--watch`, `--fan-stats`
or `--json`; `fanfi-probe --help` prints the full usage.

- [x] An unprivileged process can open `AppleSMC`; `#KEY` = 2299, and all keys can be enumerated.
- [x] Fan discovery: `FNum` = 2, both fans `Mn` 2317 / `Mx` 6800 RPM (`flt `). At idle,
      `Ac` = `Tg` = 0 (stopped) and `Md` = 0, which is automatic. There is no `F<n>ID` (names fall
      back to "Fan 1/2").
- [x] Temperatures: 259 `T*` keys (250 `flt `, 9 `ioft`), all inside −20…130 °C. `ioft` is
      **little-endian**; before that was fixed, all 9 were dropped as out of range.
- [x] Codec: the fan and temperature paths use only `flt ` (LE Float32) and `ui8 `. `si64` was
      added.
- [x] The `Tp*` flicker filter (`TemperatureSampleFilter`), the aggregates (`agg:cpu` = max of
      `Tp*`, matching `TCMz`), and the emergency prefixes `Tp/Te/TC/Tg` (`TG*` excluded).
- [x] Ranking exclusions: `Tf*` and the constant keys no longer win the automatic "hottest"
      selection (unit-tested; re-check in your UI).
- [ ] Sensor names on other models; many keys stay "Sensor XXXX".
- [ ] `fanfi-probe --json` (snapshot, and JSON Lines with `--watch`) parses with a JSON tool, for
      example `swift run fanfi-probe --json | python3 -m json.tool`.
- [ ] Fanless Macs, and environments where the SMC is unavailable.

**Mac14,9 findings from the dump (2026-10-19):**

- Attribute bits: every one of the 2170 readable keys has `0x80`, and all 54 keys without `0x80`
  fail to read, so `0x80` is the *read* bit. `F<n>Tg` = `0xd4` and `F<n>Md` = `0xd0` have the
  write bit `0x40`; `F<n>Mn` = `0x84`, `F<n>Mx` = `0x85` and `FNum` = `0x80` do not.
- No unlock key is present or needed. Other fan keys of unknown meaning: `F<n>Dc`, `Fb`, `Fc`,
  `St`, `Sf`, `FOff`, `FRmp`, `FOFC`, `FBAD`.
- Integer endianness varies by key: `#KEY`, `FOFC` and `F<n>Fc` look big-endian, while the
  battery keys and `ui64`/`si64` look little-endian. `SMCCodec` integers stay big-endian; check on
  hardware before relying on any new integer key.
- 126 keys fail to read: 42 are larger than 32 bytes, 54 lack `0x80` (11 are in both groups), and
  41 make the SMC return an error.
- Implausible "temperatures": `Tf02/12/22` read a constant −11 to −13; `Tf06/16/26` read a
  constant 79–105, which changed between days; several `Ta0*`, `TH1a/b`, `TVMD` and `Tz1*` read
  0.00 or a constant 9.50. These keys are excluded from ranking only (kit.md).
- The `Tp*` (P-core) keys alternate per read between real values (50–75 °C) and fixed patterns
  (`0.00 / 6.70 / 8.43` and similar), and a power-gated cluster can keep reading the pattern for
  many reads. `TCMz` tracks the maximum real `Tp*` value.
- `TG*` (`ioft`, about 33 °C, close to `TB0T`) is **not** the GPU on this model; the GPU is
  `Tg*`.

### Phase 2/3: helper installation

SMAppService mode:

- [ ] The status goes "not installed" → install → "requires approval", with guidance and an
      "Open Login Items" action.
- [ ] After approving in System Settings ▸ General ▸ Login Items & Extensions, "Check Again" shows
      "installed".
- [ ] `.notFound` (a misplaced plist) shows guidance only, with no install button.
- [ ] `sudo launchctl print system/<label>` shows the service, and `log stream` shows connections.
- [ ] Code-signing requirements in both directions with real Team ID signing.

Manual-install mode:

- [x] `install.sh --dry-run` prints the verification, both cdhashes and the generated plist,
      and changes nothing.
- [x] `sudo install.sh` → the helper starts as root on demand, logs
      `Client requirement mode: MANUAL INSTALL …`, and accepts the pinned app.
- [x] Read-only monitoring never connects to the helper.
- [x] App rebuilt without re-running `install.sh`: the app shows "pinned to another build", makes
      no connection attempts, and does not retry automatically.
- [ ] A process ad-hoc signed with the app's identifier but a different cdhash is rejected.
- [ ] `sudo uninstall.sh` → the service is gone and the status returns to "not installed".

### Phase 4: writing and profiles

> Before the first write, follow the procedure in [verification/SUMMARY.md](verification/SUMMARY.md#first-write-procedure):
> run `fanfi-probe --watch 1` and the helper `log stream` side by side, confirm the escape routes
> first, and start with one fan at a modest fixed RPM.

- [x] Fixed 3000 RPM on Fan 1 writes `F0Md = 1`, then `F0Tg = 3000`; `F0Ac` follows within about
      3 s, and Fan 2 is unaffected.
- [x] "Restore automatic" writes `F0Md = 0` and the SMC takes over immediately, with no `Tg`
      write-back. With no session and no manual fan, it writes nothing.
- [x] `kill -9` of the app during manual control → the helper restores within about 2 s.
- [x] Helper SIGTERM during manual control → the helper restores and exits with code 0.
- [x] A sensor-linked curve (`agg:cpu` 45 → 75 °C) follows the curve (74.35 °C → 6702 RPM).
- [ ] A target below `Mn` (with `enforceHardwareMinimum = false`) → `rpmOutOfRange`, and
      **nothing** is written.
- [ ] Each preset (Constant Quiet 3000, Constant High 5000, Boost, Max) applied from the UI.
      Boost runs at about 5500–6100 RPM at idle on Mac14,9, which is by design.
- [ ] Custom slots: edit, save, rename, reset, apply; the curve editor; persistence across
      relaunch.
- [ ] Quitting the app (⌘Q) or turning the feature off returns the fans to automatic.
- [ ] A poll that runs right after an apply does not write the old profile's targets.
- [ ] **Hunting test:** run Boost under constant load for at least 5 min, then record
      `fanfi-probe --watch 2` for 3 min. Targets must not swing by more than ±150 RPM at a steady
      temperature. On a rising load, the target moves by at most 500 RPM per poll and reaches the
      curve value within about 20 s. When the load drops, the target waits at least 10 s, then
      falls in steps. The emergency override is immediate.
- [ ] Freeze the helper with `sudo kill -STOP` → after about 8 s the call fails with "timeout"
      and the app does not hang. After `kill -CONT`, the helper restores.
- [ ] SIGKILL the helper during manual control → `Md` stays 1, and "Restore automatic" (with no
      session) writes `Md = 0`.
- [ ] **Automated hunting check (`--fan-stats`):** apply a sensor-linked profile (e.g. a custom
      slot with a curve on `agg:cpu`, or Boost) under a steady load, wait about 1 min, then run
      `swift run fanfi-probe --watch 1 --fan-stats 120` (read-only; it prints one actual/target
      line per second and then per-fan statistics; exit code 0 = every fan PASS, 1 = FAIL).
      Per fan it reports actual min/max/mean, target min/max, the number of target reversals
      (direction changes, moves under 50 RPM ignored) and the max |actual − target| after a 5-s
      settle. **PASS**: at most 1 reversal per 60 s (at least 1 allowed in any window) and
      |actual − target| ≤ 150 RPM for ≥ 95 % of post-settle samples. **FAIL** prints the reason:
      *target hunting* means the control loop oscillates (look at the smoothing knobs in
      `FanControlTuning`: rise/fall time constants, `deadbandRPM`, `minimumDwell`,
      `maximumStepRPM`; the curve slope around the current temperature, and
      `Tp*` sample noise that `TemperatureSampleFilter` should absorb); *actual does not track
      target* means the SMC is not following the written `Tg` (check `Md` = 1, a competing writer
      such as FanFi, or a target outside `Mn…Mx`). The thresholds live in
      `FanStabilityCriteria` (FanControlCore/FanStatistics.swift). In automatic mode the check
      describes the SMC's own controller and is only a baseline.

### Phase 5: advanced

- [x] Emergency override (threshold lowered to 55 °C for the test): every fan, including the one
      in automatic mode, is forced to 6800 RPM, and the fans return to the profile when the
      thresholds are restored.
- [x] Sleep/wake with a session open: no persistent `manual(0)` after wake, and the profile is
      restored within about 2 s (helper.md §5).
- [ ] High-temperature alert at 90 °C, cleared at 85 °C; the fan anomaly alert (target > 0 with
      0 RPM for 3 polls).
- [ ] With the UI hidden and no session: a slow poll continues while any alert is enabled, and
      polling stops otherwise.
- [ ] Power-aware polling: on battery the interval is 10 s, and it returns to the setting at
      once on AC (`Power source changed: battery` / `AC` in the log).
- [ ] Coexistence with other fan-control apps: launching a known app (for example FanFi,
      `com.fanfi.fanfi`) shows a warning, which clears on quit. An installed helper whose app
      is not running is listed but does not trigger a warning.
- [ ] Threshold settings: lowering the alert or emergency threshold takes effect on the next
      poll, and "Reset to Defaults" restores 90 / 95 / 5 °C.
- [ ] Turning the feature off and on quickly does not leave monitoring stopped.

## 7. Open questions

- **Other Apple Silicon models.** Community reports say some newer models need an extra unlock
  key before `F<n>Tg` takes effect. No such key is on the allowlist, and Mac14,9 needs none.
  Decide after testing on such a model.
- **Thresholds.** 90 / 95 / 5 °C are provisional defaults and are user-adjustable (alert 70–100,
  emergency alert+1…105, hysteresis 1–10). Open: whether these defaults suit each model, whether
  the alert and the emergency need separate hysteresis values, and how the steppers should behave
  in °F.
- **Sensor semantics.** Is `TG*` non-GPU on every Apple Silicon model? Should `TC*` stay in the
  emergency prefixes and in `agg:cpu`? Is the maximum the right aggregate, or is an average
  needed? The sample-filter parameters (10 °C floor, hold for 5 reads, fall back to the group
  maximum) are provisional.
- **Sensor names.** No reliable source for `TCM*`, `TVM*`, `TPD*/TRD*`, `Th0*`, `TD*` or `Tf*`.
  The P/E core split is inconsistent across community sources.
- **Coexistence.** Detection only warns. Open: whether to refuse writes while another
  controller runs, and whether to add more apps to the list. "Restore automatic" also hands back
  fans that another tool forced; the UI should say so.
- **Power.** Should the battery interval be configurable, should Low Power Mode be honoured, and
  what does the 2 s default cost in battery?
- **Start-up.** The persisted active profile is **not** re-applied at launch; the session stays
  closed until the user acts.
- **Unverified:** SMAppService registration and approval with real signing, the 8 s XPC timeout
  under load, and whether the 2 s termination wait is enough.
