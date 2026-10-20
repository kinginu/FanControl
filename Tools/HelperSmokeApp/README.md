# HelperSmokeApp

`FanControlSmoke` is the sample host app of the FanControl package. It is a minimal app,
generated with XcodeGen, that embeds the privileged helper according to the recipe in
[docs/integration.md](../../docs/integration.md) §1–§4 and drives the real `FanControlKit` API.
Use it as a template for your own host, or to check the helper on a new Mac or macOS release.
Every hardware test in [docs/verification/SUMMARY.md](../../docs/verification/SUMMARY.md) was run
with it. The build check is recorded in
[`helper-bundle-smoke-2026-10-20.md`](../../docs/verification/helper-bundle-smoke-2026-10-20.md)
(in Japanese).

The helper can run in two modes, and the same build supports both:

| Mode | Signing | Who installs the helper | Client check in the helper | Status |
|---|---|---|---|---|
| **SMAppService** | Team ID (Apple Development / Developer ID) | the app (`SMAppService.daemon`, approved in Login Items) | Team ID + bundle id | not yet tested on hardware |
| **Manual install** (personal use) | ad-hoc (`-`), no Team ID | you, with `sudo Support/manual-install/install.sh` | bundle id + the app's cdhash | tested 2026-10-20 |

## Contents

| Target | Kind | Contents |
|---|---|---|
| `FanControlSmoke` | macOS app (`LSUIElement`, menu bar) | Links `FanControlCore` / `FanControlKit` from the local package `../..`. The window shows `HelperInstaller.status()`, the helper-requirement mode (Team ID or manual cdhash, the app's Team ID, the pinned helper cdhash) and live per-fan current/target/mode, session and connection state, `agg:cpu`, emergency/alert flags and `lastError`, refreshed every second. |
| `FanControlHelper` | Command Line Tool | Compiles `../../Sources/FanControlHelper/*.swift` directly, links Core / SMC / XPC, and embeds `$(FANCONTROL_HELPER_INFO_PLIST)` (default `../../Support/Helper-Info.plist`) with `-sectcreate` |

Buttons, in order:

- **Refresh status**, **Helper version** (XPC `version` only; it never writes), **Check again**
  (resets a rejection / backoff, e.g. after re-running `install.sh`, and probes with `version()`).
- **Install helper**: `SMAppService.register`; does nothing in manual mode.
- **Fan 1 → 3000 RPM…**, **All fans → 6000 RPM…**: write to the SMC after a confirmation dialog.
- **Apply sensor-linked (agg:cpu 45→75 °C)…**
- **Emergency test: set threshold to 55 °C…** / **restore default thresholds**: changes the
  in-memory `safetyPolicy` only.
- **Apply first profile** (Automatic) / **Restore automatic**.

The app targets macOS 26.0+ in the Swift 6 language mode, without App Sandbox and with Hardened
Runtime.

## How the helper is embedded

1. `FanControlHelper` is a bare executable whose Info.plist is the `__TEXT,__info_plist` section
   (`OTHER_LDFLAGS = -sectcreate __TEXT __info_plist $(FANCONTROL_HELPER_INFO_PLIST)`,
   `GENERATE_INFOPLIST_FILE = NO`, `CREATE_INFOPLIST_SECTION_IN_BINARY = NO`).
2. The app copies it to `Contents/MacOS/FanControlHelper` ("Embed Dependencies").
3. The app's Run Script phase "Embed FanControl identifiers" runs
   `../../Support/embed-helper-config.sh "$FANCONTROL_HELPER_INFO_PLIST" --app "$TARGET_BUILD_DIR/$WRAPPER_NAME"`.
   It fails the build if the app's bundle id is not the plist's `FanControlClientBundleIdentifier`
   or if the embedded helper carries other identifiers (a stale helper), copies the `FanControl*`
   keys into the app's Info.plist, and generates the SMAppService plist
   `Contents/Library/LaunchDaemons/<label>.plist` (docs/helper.md, "Configuring identifiers").
   Manual-install mode ignores that plist: `install.sh` writes its own to `/Library/LaunchDaemons`.
4. Xcode signs the helper, then the app.

The identifiers live in three build settings in `project.yml`, nowhere else:

| Setting | Default | Meaning |
|---|---|---|
| `FANCONTROL_APP_ID` | `com.example.dynamicnotch.DynamicNotch` | App `PRODUCT_BUNDLE_IDENTIFIER` (= `FanControlClientBundleIdentifier`) |
| `FANCONTROL_HELPER_ID` | `com.example.dynamicnotch.DynamicNotch.fanfi` | Helper `PRODUCT_BUNDLE_IDENTIFIER` (= `FanControlHelperIdentifier`, the code-signing identifier) |
| `FANCONTROL_HELPER_INFO_PLIST` | `$(SRCROOT)/../../Support/Helper-Info.plist` | Info.plist embedded in the helper; must name the two ids above |

To build it as another host, write a Helper-Info.plist with your identifiers and pass all three,
e.g. `xcodebuild … FANCONTROL_APP_ID=com.acme.Notch FANCONTROL_HELPER_ID=com.acme.Notch.helper
FANCONTROL_HELPER_INFO_PLIST=/path/to/acme-Helper-Info.plist`.

> The sample app shares its bundle id, Mach service name and `UserDefaults` with any other host
> that uses the same identifiers (by default, DynamicNotch). Uninstall its helper before
> installing another host's helper, and vice versa.

`project.yml` sets three non-default options:

- `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime`. Xcode does not apply Hardened
  Runtime to ad-hoc signatures by itself. The flag is harmless with real signing.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app, for the Run Script (its output file name
  depends on the plist's contents, so it cannot be declared).
- `ENABLE_DEBUG_DYLIB = NO`. By default, Debug builds split the app into a stub plus
  `FanControlSmoke.debug.dylib`, and with ad-hoc signing and Hardened Runtime, library validation
  refuses that dylib (`… have different Team IDs`), so the app does not launch.

## Generate and build

If Xcode is not the `xcode-select`ed toolchain, set `DEVELOPER_DIR`.

```sh
cd FanControl/Tools/HelperSmokeApp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
APP=.derivedData/Build/Products/Debug/FanControlSmoke.app
```

Generated files (`*.xcodeproj`, `.derivedData*/`, `.build/`) are git-ignored.

### Check the bundle

```sh
find "$APP" -not -path '*/_CodeSignature/*'
launchctl plist __TEXT,__info_plist "$APP/Contents/MacOS/FanControlHelper"   # embedded Info.plist
"$APP/Contents/MacOS/FanControlHelper" --print-configuration                 # resolved ids, no SMC access
plutil -p "$APP/Contents/Info.plist" | grep FanControl
plutil -p "$APP/Contents/Library/LaunchDaemons/"*.plist
codesign -dvvv "$APP" "$APP/Contents/MacOS/FanControlHelper" 2>&1 | grep -E '^(Identifier|CodeDirectory|TeamIdentifier)'
codesign -d --entitlements - "$APP/Contents/MacOS/FanControlHelper"
codesign --verify --deep --strict -v "$APP"
```

With the defaults, expect:

- `Contents/MacOS/FanControlSmoke`, `Contents/MacOS/FanControlHelper` and
  `Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist`.
- The embedded Info.plist has `CFBundleIdentifier` and `FanControlHelperIdentifier` /
  `FanControlMachServiceName` = `com.example.dynamicnotch.DynamicNotch.fanfi`,
  `FanControlClientBundleIdentifier` = `com.example.dynamicnotch.DynamicNotch` and
  `FanControlClientTeamID` = `TEAMID0000` (the placeholder).
- The app's Info.plist carries the same four `FanControl*` keys.
- The LaunchDaemon plist has `Label` and the `MachServices` key = the helper id,
  `BundleProgram` = `Contents/MacOS/FanControlHelper`, `AssociatedBundleIdentifiers` = the app id.
  It is identical to the checked-in `../../Support/LaunchDaemons/<label>.plist`.
- Both binaries have `Signature=adhoc` and `flags=0x10002(adhoc,runtime)`; the helper's
  `Identifier` is the helper id.

## Manual-install mode (tested 2026-10-20)

Operations that need root, and every SMC write, are run by **you**, one confirmed step at a time.

1. Build as above (ad-hoc).
2. Preview, which needs no root:
   `../../Support/manual-install/install.sh --dry-run --app "$APP"`. It shows both cdhashes and
   the generated plist. A warning about `com.apple.application-identifier` is expected; so are
   the `get-task-allow` warnings for a Debug build.
3. Install: `sudo ../../Support/manual-install/install.sh --app "$APP"`, then run
   `../../Support/manual-install/status.sh --app "$APP"`.
4. Start the helper log in another terminal:
   `/usr/bin/log stream --level debug --predicate 'subsystem == "<subsystem>" AND category == "fancontrol-helper"'`.
5. Run `open "$APP"` and open the menu-bar fan icon ▸ Show Window. Expect
   `installedManually` and `manual (cdhash) · app team none (ad-hoc) · helper cdhash <…>`.
6. Click **Helper version**. The log should show
   `Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to <…>` and
   `Accepted connection …`. If the helper does not start, check `last exit code` (78 means a bad
   requirement) and the AMFI log. If the connection is invalidated, run `status.sh` and re-run
   `install.sh`.
7. Optional negative test: rebuild without re-running `install.sh`. The app should report the
   pin mismatch and not connect.
8. **Writes:** follow the first-write procedure in
   [SUMMARY.md](../../docs/verification/SUMMARY.md#first-write-procedure). Run
   `swift run fanfi-probe --watch 1` side by side, confirm the escape routes, then work through
   these steps:
   1. Fan 1 → 3000, then Restore automatic.
   2. Helper SIGTERM, and app `kill -9`, while a fan is forced.
   3. Sensor-linked.
   4. Emergency test.
   5. Sleep/wake with the lid closed for more than 60 s.

   For each step, the expected log patterns are in
   [docs/helper.md](../../docs/helper.md) §5 and [docs/integration.md](../../docs/integration.md) §6.
9. Clean up: quit the app, run `sudo ../../Support/manual-install/uninstall.sh --app "$APP"`,
   and check that `status.sh` reports both files missing.

`install.sh` is idempotent: run it again after every rebuild (the cdhash changes); when nothing
changed it leaves the running helper alone. See
[Support/manual-install/README.md](../../Support/manual-install/README.md).

## SMAppService mode (with a Team ID, not yet tested)

1. Sign with your team: either set `DEVELOPMENT_TEAM` and
   `CODE_SIGN_IDENTITY: "Apple Development"` (or `"Developer ID Application"`) in `project.yml`,
   or pass them on the command line.
2. Replace the Team ID placeholder (`TEAMID0000`) with your Team ID in the Helper-Info.plist
   (`FanControlClientTeamID`). The Run Script copies it into the app's Info.plist, so both sides
   use it; no Swift constant needs changing.
3. Check that `codesign -dvvv` shows the same `TeamIdentifier` on both binaries, with `runtime`
   in the flags, and that the embedded plist has your Team ID. Check whether the helper still
   carries `com.apple.application-identifier`; under Developer ID signing without a profile,
   launchd may refuse it.
4. If a manual installation with the same label exists, remove it first
   (`sudo ../../Support/manual-install/uninstall.sh --app "$APP"`); the two modes share the label.
5. Copy the app to `/Applications` and launch it from there (`SMAppService` checks the bundle
   location). The status should read `notRegistered` (`notFound` means the plist is misplaced).
   Click **Install helper**, which sets the status to `requiresApproval` and opens Login Items.
   Approve the app, then click Refresh status, which should show `enabled`.
6. Click **Helper version**, which should return `helper protocol 1, build 1.0 (1)`. Check
   `sudo launchctl print system/<label>` and the helper `log stream`.
7. Clean up: unregister (or switch the item off in System Settings), delete the app, and confirm
   that `launchctl print` no longer finds the service.
