# Manual helper install (developer / personal-use mode)

These scripts install `FanControlHelper` as a plain LaunchDaemon. Use them when you **have no
Developer ID / Team ID** and so cannot use `SMAppService`, for example while developing, or on
your own Mac. For apps you give to other people, use the `SMAppService` path instead
([docs/integration.md](../../docs/integration.md) §4). The full design and threat model are in
[docs/helper.md](../../docs/helper.md) §6.

| File | Purpose |
|---|---|
| `install.sh` | Verifies the app and its embedded helper, pins the app's cdhash, installs the helper and the plist, and bootstraps the job. Idempotent: if the installed files are already exactly what it would install and the job is loaded, it changes nothing and does not restart the helper (`--force` reinstalls anyway). |
| `uninstall.sh` | Boots the job out (the helper restores automatic fan control on SIGTERM) and removes both files. Like `install.sh`, it only touches what `install.sh` wrote: it refuses `com.apple.*` labels and a plist without `FANCONTROL_CLIENT_REQUIREMENT` (e.g. another vendor's daemon under a mistyped label), refuses to boot out a loaded job whose plist is missing, and without the plist removes the helper file only if it is signed with the helper identifier. With nothing installed it says so and exits 0. |
| `status.sh` | Read-only (no root needed): shows both files, the pinned requirement, the helper cdhash and launchd state. Given an app, it also checks whether the app's cdhash is the pinned one. Exits 1 if something needs fixing. |
| `common.sh` | The manual-install layer (sourced): installed paths, the client requirement, the plist generator, launchd queries, `load_identifiers_from_app`. Tests check that its values match the Swift code. |
| `FanControlHelper.manual.plist` | The LaunchDaemon template. Its placeholder values make the helper refuse to start if the template is installed unfilled. |

The scripts share two files one level up (a flat copy with both files next to the scripts works
too, which is how a host app bundles them; [docs/helper.md](../../docs/helper.md) §6 "Installing
from the app"):

| File | Purpose |
|---|---|
| `../lib.sh` | Generic library: `info`/`warn`/`die`, `parse_cli` (`--help`, `--dry-run`, `--app`), `run` (prints instead of running with `--dry-run`), `require_root`, `resolve_app`, a per-run temporary directory removed on exit, plist helpers (`plist_string`, `embedded_info_plist`, which reads a bare executable's `__TEXT,__info_plist` with `launchctl plist`), code-signing helpers (`cdhash_of`, `signing_identifier`, entitlement checks) and `is_root_protected`. |
| `../identifiers.sh` | The identifier rules (mirrors `FanControlIdentifiers.swift`): defaults, fallbacks, validation, `resolve_identifiers_from_plist`. Also used by `../embed-helper-config.sh`. |

All three scripts take the same options: `-h`/`--help`, `-n`/`--dry-run` (no root needed, changes
nothing; `status.sh` is always read-only) and `--app <path>` (the positional form
`script.sh /path/to/App.app` still works). Wrong usage exits 64. Run
`../../Tools/test-support-scripts.sh` after changing any of them: it builds a fake ad-hoc signed
app with a fake helper in a temporary directory and tests the functions and the scripts' no-root
modes (no root, nothing installed).

## Usage

```sh
# Build the app (with the helper embedded at Contents/MacOS/FanControlHelper), ad-hoc signed.
# For Debug + Hardened Runtime, set ENABLE_DEBUG_DYLIB = NO, or the app will not launch.

./install.sh --dry-run --app /path/to/YourApp.app   # preview: verifies, prints plist and commands, changes nothing
sudo ./install.sh --app /path/to/YourApp.app        # install (re-run after EVERY rebuild of the app)
./status.sh --app /path/to/YourApp.app              # "the app's cdhash matches the pinned requirement"
sudo ./uninstall.sh --app /path/to/YourApp.app      # remove (the app argument supplies the label)
```

What gets installed:

- `/Library/PrivilegedHelperTools/<label>` (root:wheel 0755)
- `/Library/LaunchDaemons/<label>.plist` (root:wheel 0644). It is launched on demand through its
  Mach service. Its `EnvironmentVariables.FANCONTROL_CLIENT_REQUIREMENT` is
  `identifier "<app bundle id>" and cdhash H"<app cdhash>"`.

`<label>` (`FanControlMachServiceName`) and `<app bundle id>` (`FanControlClientBundleIdentifier`)
are read from the helper's embedded Info.plist, so a host with its own identifiers needs no edits
here (docs/helper.md, "Configuring identifiers"). `install.sh` refuses an app whose Info.plist
resolves to different identifiers than its helper, and never overwrites a LaunchDaemon plist it
did not write. Without an app argument, `status.sh` and `uninstall.sh` use the defaults
(`com.example.dynamicnotch.DynamicNotch[.fanfi]`); pass the app (`sudo ./uninstall.sh --app
/path/to/YourApp.app`) or override them:
`sudo FANCONTROL_MACH_SERVICE_NAME=com.acme.Notch.helper ./uninstall.sh`.

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
| The app says the helper is "pinned to another build" / rejected | You rebuilt the app. Run `sudo ./install.sh --app <app>` again, then click "Check Again" in the app. `./status.sh --app <app>` shows the mismatch. |
| The helper does not start | `launchctl print system/<label>` → `last exit code`. Code 78 means `FANCONTROL_CLIENT_REQUIREMENT` is invalid, or the Mac is not Apple Silicon. Also see `log show --last 5m --predicate 'process == "amfid" OR sender == "AppleMobileFileIntegrity"'`. |
| You need to see helper activity | `/usr/bin/log stream --level debug --predicate 'subsystem == "<subsystem>" AND category == "fancontrol-helper"'` |
| The fans stay manual after a helper crash | Click "Restore automatic control" in the app (it recovers orphaned manual fans), or reboot. |
