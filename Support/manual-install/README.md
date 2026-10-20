# Manual helper install (developer / personal-use mode)

These scripts install `FanControlHelper` as a plain LaunchDaemon. Use them when you **have no
Developer ID / Team ID** and so cannot use `SMAppService`, for example while developing, or on
your own Mac. For apps you give to other people, use the `SMAppService` path instead
([docs/integration.md](../../docs/integration.md) §4). The full design and threat model are in
[docs/helper.md](../../docs/helper.md) §6.

| File | Purpose |
|---|---|
| `install.sh` | Verifies the app and its embedded helper, pins the app's cdhash, installs the helper and the plist, and bootstraps the job. Idempotent. |
| `uninstall.sh` | Boots the job out (the helper restores automatic fan control on SIGTERM) and removes both files |
| `status.sh` | Read-only (no root needed): shows both files, the pinned requirement, the helper cdhash and launchd state. Given an app, it also checks whether the app's cdhash is the pinned one. |
| `common.sh` | Shared constants and helpers (sourced). Tests check that these values match the Swift constants. |
| `<label>.manual.plist` | The LaunchDaemon template. Its placeholder values make the helper refuse to start if the template is installed unfilled. |

## Usage

```sh
# Build the app (with the helper embedded at Contents/MacOS/FanControlHelper), ad-hoc signed.
# For Debug + Hardened Runtime, set ENABLE_DEBUG_DYLIB = NO, or the app will not launch.

./install.sh --dry-run /path/to/YourApp.app   # preview: verifies, prints plist and commands, changes nothing
sudo ./install.sh /path/to/YourApp.app        # install (re-run after EVERY rebuild of the app)
./status.sh /path/to/YourApp.app              # "the app's cdhash matches the pinned requirement"
sudo ./uninstall.sh                           # remove
```

What gets installed:

- `/Library/PrivilegedHelperTools/<label>` (root:wheel 0755)
- `/Library/LaunchDaemons/<label>.plist` (root:wheel 0644). It is launched on demand through its
  Mach service. Its `EnvironmentVariables.FANCONTROL_CLIENT_REQUIREMENT` is
  `identifier "<app bundle id>" and cdhash H"<app cdhash>"`.

<!-- TODO: verify after refactor — <label> and <app bundle id> are currently the constants in common.sh (com.example.dynamicnotch.DynamicNotch[.fanfi]); they are becoming configurable. -->

## Security caveats (read before installing)

- **The cdhash pin stops a different build from connecting, and nothing more.** Any process
  running as your user can still drive the helper through the pinned app:
  - by attaching to it, if the app has `com.apple.security.get-task-allow`. Xcode adds this to
    Debug builds. Pin a Release build, or build with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.
  - by replacing a framework in the bundle, if the app has
    `com.apple.security.cs.disable-library-validation`. Ad-hoc signed apps that embed frameworks
    need this entitlement, so keep the bundle writable only by you.

  `install.sh` warns about both entitlements.
- **What limits the damage is the helper itself:** only `F<n>Md` (0/1) and `F<n>Tg` (within the
  fan's hardware `Mn…Mx`) can be written, and fans are handed back to macOS on disconnect, exit
  and sleep. A misbehaving client can run the fans at max or pin them at minimum, and nothing
  worse.
- There is no Gatekeeper or notarization. You install what you built yourself.
- Since macOS 13 the job appears under System Settings ▸ General ▸ Login Items & Extensions ▸
  Allow in the Background. If it is switched off there, the helper does not start.
- **Do not combine this mode with an SMAppService registration.** Both use the same label.
  `install.sh` aborts if an SMAppService job is loaded.

## Troubleshooting

| Symptom | Check |
|---|---|
| The app says the helper is "pinned to another build" / rejected | You rebuilt the app. Run `sudo ./install.sh <app>` again, then click "Check Again" in the app. |
| The helper does not start | `launchctl print system/<label>` → `last exit code`. Code 78 means `FANCONTROL_CLIENT_REQUIREMENT` is invalid, or the Mac is not Apple Silicon. Also see `log show --last 5m --predicate 'process == "amfid" OR sender == "AppleMobileFileIntegrity"'`. |
| You need to see helper activity | `/usr/bin/log stream --level debug --predicate 'subsystem == "<subsystem>" AND category == "fancontrol-helper"'` |
| The fans stay manual after a helper crash | Click "Restore automatic control" in the app (it recovers orphaned manual fans), or reboot. |
