# FanControl documentation

Start with the [package README](../README.md) for what FanControl is, the quick start and the
safety model. Then:

| Document | Read it when you want to… |
|---|---|
| [architecture.md](architecture.md) | See how the modules, the app-side components and the root helper fit together (diagrams), and where each safety decision lives |
| [integration.md](integration.md) | Add the package and the helper to an Xcode app: targets, embedding, identifiers, signing, UI wiring, and the hardware checklist (Phase 1 → 5) |
| [kit.md](kit.md) | Understand the app side (`FanControlKit`): the `FanControlManager` facade and its components, threading, the control loop, curves, profiles, thresholds, persistence, errors, notifications, tests |
| [helper.md](helper.md) | Understand the privileged helper: identifiers, bundle layout, signing, `SMAppService` registration, the XPC protocol and session, write validation, sleep/wake, and the manual-install mode with its threat model |
| [`../Support/manual-install/README.md`](../Support/manual-install/README.md) | Install the helper by hand (developers and personal use, no Team ID) |
| [`../Tools/HelperSmokeApp/README.md`](../Tools/HelperSmokeApp/README.md) | Build the minimal sample host that embeds the helper; it was the bench for every hardware test |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | Build, test and change the code (Swift 6 rules, safety rules, clean room) |
| [NAMING.md](NAMING.md) | See why the project is called FanControl and which other names were considered |

## Verification records

[verification/SUMMARY.md](verification/SUMMARY.md) summarises what was verified on hardware
(Mac14,9, macOS 26.5, 2026-10-19/20) and holds the **first-write procedure** to repeat on a new
machine. The other files in [verification/](verification/) are the dated logs behind it. They are
historical records in Japanese: they describe the code as it was on that date, and the
implementation has moved on since. The current behaviour is the one described in the documents
above.

| Record | Contents |
|---|---|
| [verification/SUMMARY.md](verification/SUMMARY.md) | Results table, what is not verified, first-write procedure |
| [verification/pre-write-review-2026-10-20.md](verification/pre-write-review-2026-10-20.md) | Review of the write path before the first SMC write |
| [verification/helper-bundle-smoke-2026-10-20.md](verification/helper-bundle-smoke-2026-10-20.md) | `xcodebuild` check of the embedding recipe; first manual-install launch |
| [verification/first-write-2026-10-20.md](verification/first-write-2026-10-20.md) | First write, restore, `kill -9`, SIGTERM, curves, emergency, sleep/wake |
| [verification/adversarial-review-2026-10-20.md](verification/adversarial-review-2026-10-20.md) | Multi-perspective review: 19 findings, 7 confirmed and fixed |
| [Mac14,9-macOS26-probe.txt](verification/Mac14,9-macOS26-probe.txt), [Mac14,9-macOS26-dump.txt](verification/Mac14,9-macOS26-dump.txt) | Raw `fanfi-probe` output and the full SMC key dump |

## Conventions

- Documentation is English only. (Earlier Japanese copies of these documents were removed; they
  remain in the git history.)
- Code is referred to by type and member names, not by line numbers.
- When code changes, update kit.md, helper.md, integration.md and the manual-install README in
  the same change ([CONTRIBUTING.md](../CONTRIBUTING.md)).
