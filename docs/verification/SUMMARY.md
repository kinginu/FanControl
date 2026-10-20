# Hardware verification summary

**Machine:** MacBook Pro 14" **Mac14,9** (Apple M2 Pro), two fans (`Mn` 2317 / `Mx` 6800 RPM),
macOS 26.5.2, Xcode 26.6, Swift 6.3.3.
**Dates:** 2026-10-19 (reads) and 2026-10-20 (writes).
**No other model has been tested.**

**Setup for every write test:**

- `Tools/HelperSmokeApp`, ad-hoc signed, Debug build with `ENABLE_DEBUG_DYLIB = NO`.
- The helper installed in **manual-install mode** (`sudo Support/manual-install/install.sh`),
  with the client cdhash pinned.
- `fanfi-probe --watch 1` (read-only, 1 s samples) running alongside
  `/usr/bin/log stream --predicate 'subsystem == "<subsystem>" AND category == "fancontrol-helper"'`.
- The user pressed each button after confirming the step. Logs and probe output were checked
  after every step.

The detailed logs are in Japanese. The quoted log lines and probe samples in them are English or
numeric.

| Log | Contents |
|---|---|
| [`Mac14,9-macOS26-probe.txt`](Mac14,9-macOS26-probe.txt), [`Mac14,9-macOS26-dump.txt`](Mac14,9-macOS26-dump.txt) | Raw `fanfi-probe` output and the full key dump (the battery serial is redacted) |
| [`pre-write-review-2026-10-20.md`](pre-write-review-2026-10-20.md) | Code review of the write path before the first write, and the first-write procedure |
| [`helper-bundle-smoke-2026-10-20.md`](helper-bundle-smoke-2026-10-20.md) | `xcodebuild` check of the embedding recipe; the first manual-install launch |
| [`first-write-2026-10-20.md`](first-write-2026-10-20.md) | Every write test below, with timestamps and probe samples |
| [`adversarial-review-2026-10-20.md`](adversarial-review-2026-10-20.md) | A multi-perspective review: 19 findings, 7 confirmed and fixed |

## Results

| # | Test | How | Result |
|---|---|---|---|
| R1 | SMC reads without privileges | `fanfi-probe`, `--dump`, `--watch` | ✅ `AppleSMC` opens unprivileged; 2299 keys; 2 fans; 259 temperature keys. Found `ioft` is little-endian, `0x80` = read bit, `0x40` = write bit. |
| B1 | Helper embedding recipe | XcodeGen + `xcodebuild` (Debug/Release) | ✅ Bundle layout, embedded Info.plist, identifiers and signature consistent. Fixed: launchd plist file name ≠ `plistName`; ad-hoc signing needs `--options=runtime`. |
| B2 | Manual install and connection | `sudo install.sh`, then XPC `version` | ✅ launchd starts the helper as root on demand; `Client requirement mode: MANUAL INSTALL`; the pinned app is accepted. AMFI logs -67688 for Xcode's injected entitlements, but AppleSystemPolicy allows the launch. |
| W1 | **First write** | Fan 1 fixed at 3000 RPM | ✅ `F0Md=1` → `F0Tg=3000`; current follows within ~3 s and stays at 2996–3021 for 26 samples. Fan 2 is unaffected. |
| W2 | **Restore by `Md = 0` only** | "Restore automatic" with a session open | ✅ The target jumps straight to the SMC's own value (2468), and current converges in ~3 s. **No `Tg` write-back is needed**, which confirms the restore design. With no session and no manual fan, nothing is written. |
| W3 | Client `kill -9` | `kill -9 <app pid>` during manual control | ✅ Helper log: `Owner pid … went away; releasing session`; the fan is automatic again within ~2 s. |
| W4 | Helper SIGTERM | `sudo launchctl kill SIGTERM system/<label>` | ✅ `SIGTERM received` → session restored → exit code 0; the fan is automatic. |
| W5 | Sensor-linked curve | All fans `.sensor(agg:cpu, 45 → 75 °C)` while cooling from 93 °C | ✅ 6800 above 75 °C; at 74.35 °C the target is **6702** (the formula gives 6703). |
| W6 | Emergency override | Threshold lowered in memory to 55 °C with a session open | ✅ Both fans forced to 6800, **including Fan 2, which was in automatic mode**. After restoring 95/90/5, they returned to the profile at once. |
| W7 | Sleep/wake, before the fix | Fan 1 at 3000; lid closed for 63 s | ⚠️ Found: after wake both fans were `manual(0)` (`Tg` reset to 0, manual kept) until the app re-applied ~5 s later. |
| W8 | **Sleep/wake, after the fix** | Same, 211 s sleep, with the helper's `PowerObserver` and the app's wake re-apply plus drift detection | ✅ `manual(0)` in **one** sample only (pass criterion: never two in a row). The profile was restored in ~2 s and the RPM caught up in ~6 s. New finding: the SMC wakes fans at **`Md = 3`**, `Tg = 0`, and resets them to `Md = 0` itself after 1–2 s. Wake attempt 1 is therefore lost, and attempt 2 makes the target stick. |

Side observation (W4): once, a single sample showed both fans jumping by about 1000 RPM above
their targets, and the next sample was back to normal. The cause (a read glitch, or the SMC
stepping in) is unknown.

## Not verified

- `SMAppService` registration and approval, and Team ID code-signing requirements, in both
  directions.
- Profiles applied through a full UI (presets, custom slots, the curve editor), the hunting test
  under constant load, an `Mn` violation producing `rpmOutOfRange` with nothing written, and
  freezing the helper (`kill -STOP`) to trigger the timeout path.
- SIGKILL of the helper followed by "Restore automatic" recovering the orphaned manual fans.
- Alerts (90 °C, fan anomaly), power-aware polling on battery, and the warning for other
  controllers.
- Other models, fanless Macs, and Intel (unsupported).
- `Md = 1` with `Tg < Mn`, which the helper refuses, so it should not occur. Whether the SMC
  enforces `Mn` in manual mode.

## First-write procedure

Repeat this on any new machine before trusting the stack.

1. **Monitor.** In separate terminals, run `swift run fanfi-probe --watch 1` and the helper
   `log stream`. Record the idle state (for example `F0Md=0 F0Tg=0 F0Ac=0`).
2. **Confirm the escape routes first.** Check that "Restore automatic control" works, and that
   `sudo launchctl kill SIGTERM system/<label>` stops the helper, which restores the fans. The
   last resort is a reboot, or an SMC reset: shut down, wait 30 s, start up.
3. **One fan, a modest fixed RPM.** Set Fan 1 to 3000 RPM and leave the other fans automatic.
   - Expected: `F0Md=1`, `F0Tg=3000`, `F0Ac` near 3000 within a few seconds, and the other fans
     unchanged.
   - **Abort** (press "Restore automatic") if `F0Tg` stays 0 while `F0Md=1`, if `F0Ac` stays 0
     for more than 10 s, if it does not settle near the target, or if the log shows
     `badRequest` / `smcError`.
4. **Restore.** Expect `F0Md=0` with the target taken over by the SMC, and no `Failed to restore`
   in the log.
5. Only then try `Mn`, `Mx`, both fans, profile switching, ⌘Q, `kill -9` and sleep/wake, as in
   [integration.md](../integration.md) §6.
