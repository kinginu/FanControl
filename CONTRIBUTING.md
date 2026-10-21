# Contributing

Thanks for helping. This package writes to the SMC of real machines as root, so every change is
reviewed with safety first.

## Build and test

```sh
swift build
swift test                       # Swift Testing (import Testing), not XCTest
swift run fanfi-probe --watch 2  # read-only check against real hardware
```

- If you have Xcode but `xcode-select` points to Command Line Tools, prefix the commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Command Line Tools only** (no Xcode.app). Testing.framework is not on the default search
  path, so pass it explicitly:
  ```sh
  D=/Library/Developer/CommandLineTools/Library/Developer
  swift test -Xswiftc -F -Xswiftc $D/Frameworks \
    -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib
  ```
- `FanControlCore` and the pure parts of `FanControlXPC` / `FanControlKit` also build and test on
  Linux with a Swift 6 toolchain. Keep pure logic free of Apple frameworks so that it stays that
  way.
- To check the helper embedding, use the sample host: `cd Tools/HelperSmokeApp && xcodegen generate`
  and then `xcodebuild … CODE_SIGN_IDENTITY=-` (see its README).

A change is ready when `swift build` produces **zero warnings** and the whole test suite passes
(587 tests in 79 suites at 1.0.1). CI ([.github/workflows/ci.yml](.github/workflows/ci.yml))
runs both with warnings as errors, plus `Tools/test-support-scripts.sh`, on every pull request;
`main` only accepts pull requests that pass them. Run them locally before you send a change.

## Swift 6 rules

- Every target, tests included, uses the Swift 6 language mode (`swiftLanguageModes: [.v6]`)
  with complete strict concurrency, and the deployment target is macOS 26. Do not lower either.
- **No `nonisolated(unsafe)`.** `@unchecked Sendable` only for a type whose state is protected by
  a lock, with a comment explaining why (today only `HelperClient`). Prefer checked `Sendable`
  types built on `Synchronization.Mutex`, or actors.
- SMC I/O never runs on the main actor. `FanControlManager` is `@MainActor`; the poller and the
  power observer are actors on dedicated serial queues.
- Put decisions in **pure, unit-tested types** (`HelperWritePolicy`, `PowerTransitionPolicy`,
  `FanWriteStrategy`, `HelperConnectionGate`, `UnsettledFanDetector`, …). Keep the IOKit/XPC glue
  thin.
- No `unsafeFlags` in `Package.swift`.

## Safety rules for changes

- The helper is the safety authority. **Do not widen the write allowlist** (`F<n>Md`, `F<n>Tg`)
  or relax value validation without a hardware log that shows why the change is needed and that
  it is safe. Adding a model-specific unlock key falls under this rule.
- Restore must keep ending in `F<n>Md ← 0`. Never write an idle snapshot `Tg` back while a fan is
  manual.
- Any change to the write path, restore or sleep/wake needs tests for the pure policy **and** a
  note in `docs/verification/`, saying how it was checked on hardware or that it was not.
- Keep `docs/kit.md`, `docs/helper.md`, `docs/integration.md`, `docs/architecture.md` and the
  manual-install scripts consistent with the code. Refer to code by type and member names, not by
  line numbers. `ManualInstallScriptConsistencyTests` checks that the scripts
  (`Support/identifiers.sh`, `Support/manual-install/`) match the Swift constants and
  `FanControlIdentifiers`.
- When testing writes on hardware, follow the procedure in
  [docs/verification/SUMMARY.md](docs/verification/SUMMARY.md#first-write-procedure).

## No vendor binaries, clean room

- Do not commit binaries, frameworks, assets or generated projects (`*.xcodeproj` is generated
  by XcodeGen; `.derivedData/` and `.build/` are ignored).
- Do not add third-party dependencies to the library targets. The package has none today.
- **Clean room:** do not copy code from other fan-control apps or any other closed-source
  software, and do not commit their binaries or resources. You may read
  permissively licensed open source (MIT, BSD, Apache) to learn techniques, but write your own
  code; never copy it verbatim. SMC key knowledge must come from public community documentation
  or from your own reads on your own hardware (`fanfi-probe --dump`); cite which one in a comment.
- Hardware dumps may contain serial numbers. Redact them (for example `BMSN`) before committing.

## Versioning

The package uses Semantic Versioning; the current release is **1.0.1**. Record every
user-visible change under an "Unreleased" heading in [CHANGELOG.md](CHANGELOG.md), and bump
`FanControlHelperConstants.protocolVersion` (and say so in the changelog) whenever the XPC
contract changes.

## Commits and pull requests

- Keep commits small and focused, and write the message in the imperative mood.
- Write documentation in English. The dated logs under `docs/verification/` (other than
  `SUMMARY.md`) are historical records in Japanese and are not updated.
- In a PR, state what you verified on which Mac model and macOS version, and what you could not
  verify.
