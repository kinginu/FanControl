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

A change is ready when `swift build` produces **zero warnings** and the whole test suite passes.
<!-- TODO: verify after refactor — CI is planned; once it exists, describe the required checks here. -->

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
  it is safe. Adding an unlock key such as `Ftst` falls under this rule.
- Restore must keep ending in `F<n>Md ← 0`. Never write an idle snapshot `Tg` back while a fan is
  manual.
- Any change to the write path, restore or sleep/wake needs tests for the pure policy **and** a
  note in `docs/verification/`, saying how it was checked on hardware or that it was not.
- Keep `docs/kit.md`, `docs/helper.md`, `docs/integration.md` and the manual-install scripts
  consistent with the code. `ManualInstallScriptConsistencyTests` checks that the scripts match
  the Swift constants.
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

## Commits and pull requests

- Keep commits small and focused, and write the message in the imperative mood.
- Write documentation in English. The Japanese files under `docs/ja/` are historical and are
  not kept up to date.
- In a PR, state what you verified on which Mac model and macOS version, and what you could not
  verify.
