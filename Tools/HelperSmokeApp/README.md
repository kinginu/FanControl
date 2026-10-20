# HelperSmokeApp

A minimal sample host app, generated with XcodeGen, that embeds the privileged helper according
to the recipe in [docs/integration.md](../../docs/integration.md) §1–§4 and drives the real
`FanControlKit` API. Every hardware test in
[docs/verification/SUMMARY.md](../../docs/verification/SUMMARY.md) was run with it. The build
check is recorded in
[`helper-bundle-smoke-2026-10-20.md`](../../docs/verification/helper-bundle-smoke-2026-10-20.md)
(in Japanese).

| Target | Kind | Contents |
|---|---|---|
| `FanControlSmoke` | macOS app (`LSUIElement`, menu bar) | Links `FanControlCore` / `FanControlKit` from the local package `../..`. The window shows `HelperInstaller.status()`, the helper-requirement mode (Team ID or manual cdhash, the app's Team ID, the pinned helper cdhash) and live per-fan current/target/mode, session and connection state, `agg:cpu`, emergency/alert flags and `lastError`, refreshed every second. |
| `FanControlHelper` | Command Line Tool | Compiles `../../Sources/FanControlHelper/*.swift` directly, links Core / SMC / XPC, and embeds `../../Support/Helper-Info.plist` with `-sectcreate` |

Buttons, in order:

- **Helper version**: XPC `version` only; it never writes.
- **Install helper**: `SMAppService.register`; does nothing in manual mode.
- **Fan 1 → 3000 RPM…**: writes to the SMC after a confirmation dialog.
- **Apply sensor-linked (agg:cpu 45→75 °C)…**
- **Emergency test: set threshold to 55 °C…** / **restore default thresholds**: changes the
  in-memory `safetyPolicy` only.
- **Apply first profile** (Automatic) / **Restore automatic**.

The app copies the helper into `Contents/MacOS/` and
`../../Support/LaunchDaemons/<label>.plist` into `Contents/Library/LaunchDaemons/`. It uses the
app bundle id the package expects (`FanControlHelperConstants.appBundleIdentifier`, which must
also match the launchd plist's `AssociatedBundleIdentifiers`). It targets macOS 26.0+ in the
Swift 6 language mode, without App Sandbox and with Hardened Runtime.
<!-- TODO: verify after refactor — bundle id / label become configurable; update this paragraph. -->

> The sample app shares its bundle id, Mach service name and `UserDefaults` with any other host
> that uses the same identifiers. Uninstall its helper before installing another host's helper.

## Generate and build

If Xcode is not the `xcode-select`ed toolchain, set `DEVELOPER_DIR`.

```sh
cd FanControl/Tools/HelperSmokeApp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

The product is `.derivedData/Build/Products/Debug/FanControlSmoke.app`. To check it:

```sh
APP=.derivedData/Build/Products/Debug/FanControlSmoke.app
find "$APP" -not -path '*/_CodeSignature/*'
launchctl plist __TEXT,__info_plist "$APP/Contents/MacOS/FanControlHelper"
plutil -p "$APP/Contents/Library/LaunchDaemons/"*.plist
codesign -d --entitlements - -vv "$APP" "$APP/Contents/MacOS/FanControlHelper"
codesign --verify --deep --strict -v "$APP"
```

`project.yml` sets two non-default options:

- `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime`. Xcode does not apply Hardened
  Runtime to ad-hoc signatures by itself. The flag is harmless with real signing.
- `ENABLE_DEBUG_DYLIB = NO`. By default, Debug builds split the app into a stub plus
  `FanControlSmoke.debug.dylib`, and with ad-hoc signing and Hardened Runtime, library validation
  refuses that dylib (`… have different Team IDs`), so the app does not launch.

Generated files (`*.xcodeproj`, `.derivedData/`, `.build/`) are git-ignored.

## With a Team ID (SMAppService mode, not yet tested)

1. Sign with your team: either set `DEVELOPMENT_TEAM` and
   `CODE_SIGN_IDENTITY: "Apple Development"` (or `"Developer ID Application"`) in `project.yml`,
   or pass them on the command line.
2. Replace the Team ID placeholder (`TEAMID0000`) in `Support/Helper-Info.plist`
   (`FanControlClientTeamID`) and in `FanControlHelperConstants.teamIdentifierPlaceholder`.
   <!-- TODO: verify after refactor -->
3. Check that `codesign -dvvv` shows the same `TeamIdentifier` on both binaries, with `runtime`
   in the flags, and that the embedded plist has your Team ID. Check whether the helper still
   carries `com.apple.application-identifier`; under Developer ID signing without a profile,
   launchd may refuse it.
4. Copy the app to `/Applications` and launch it from there (`SMAppService` checks the bundle
   location). The status should read `notRegistered` (`notFound` means the plist is misplaced).
   Click **Install helper**, which sets the status to `requiresApproval` and opens Login Items.
   Approve the app, then click Refresh, which should show `enabled`.
5. Click **Helper version**, which should return `helper protocol 1, build 1.0 (1)`. Check
   `sudo launchctl print system/<label>` and the helper `log stream`.
6. Clean up: unregister (or switch the item off in System Settings), delete the app, and confirm
   that `launchctl print` no longer finds the service.

## Manual-install mode (tested 2026-10-20)

Operations that need root, and every SMC write, are run by **you**, one confirmed step at a time.

1. Build as above (ad-hoc).
2. Preview, which needs no root: `../../Support/manual-install/install.sh --dry-run "$APP"`. It
   shows both cdhashes and the generated plist. A warning about `com.apple.application-identifier`
   is expected.
3. Install: `sudo ../../Support/manual-install/install.sh "$APP"`, then run
   `../../Support/manual-install/status.sh "$APP"`.
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
9. Clean up: quit the app, run `sudo ../../Support/manual-install/uninstall.sh`, and check that
   `status.sh` reports both files missing.
