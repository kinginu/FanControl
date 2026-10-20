# Project name candidates

The package needs a neutral public name. It must not be **FanFi** (an existing fan-control app)
or **DynamicNotch** (the private host). The working name **FanControl** is also a poor choice:
it collides with the widely used Windows app "FanControl" (Rem0o) and with several GitHub repos
of the same name. The module prefix (`FanControlCore`, …), the probe name (`fanfi-probe`) and
the helper label should change together with the project name.
<!-- TODO: verify after refactor — renaming touches Package.swift, module names, the helper label and the scripts; do it in one commit after the identifier refactor. -->

The collision check was run on 2026-10-20 as quick web searches (GitHub, the App Store, general
web). It is **not** exhaustive and is **not** a trademark search. Before you pick a name, run an
exact-name search on github.com, on the Mac App Store, on the Swift Package Index, and in a
trademark database (USPTO / EUIPO / JPO).

## Candidates

| Name | Idea | Collision check (2026-10-20) |
|---|---|---|
| **Ventwise** | "wise about airflow" | No Mac app or GitHub project found. A 2025 UK trademark journal entry covers ventilation software with an unknown owner and name, so check the trademark first. |
| **Airwarden** | A warden that guards the fans; fits the "helper is the safety authority" model | No app or repo found. Similar names exist in other fields (AirGuard is an Android tracker detector; Warden is a Sentry CLI). |
| **Draftline** | Draft as in air draft; the curve line | No app or repo found. Draftbit and Draftwise are unrelated products with similar names. |
| **Tachyfan** | From tachometer | No results found. |
| **SiliconAir** / **AirSMC** | Descriptive: Apple Silicon + air / SMC | No results found. "Silicon" with "Air" may read as a MacBook Air reference; avoid Apple-like branding. |
| **FanSentry** | Watchdog | Not recommended: NZXT sells the "Sentry" fan-controller hardware line. |

## Names already taken (avoid)

- **FanControl**: a popular Windows app (Rem0o) and several macOS repos.
- **CurveFan**: an Apple Silicon fan controller on GitHub with a privileged helper, a very close
  match.
- **MacFansControl**, **SoloFan**, **FanBar**: existing macOS fan utilities. Macs Fan Control and
  smcFanControl are well-known apps.
- **SMCKit**: an existing Swift SMC library (beltex, Intel only).
- **Breezeway**: an existing hospitality software company.
- **FanFi**: an existing fan-control app.

## Recommendation

**Airwarden** or **Ventwise**, in that order. Both are short, neither contains "Mac" or "Apple",
both work as a package name (`AirwardenCore`, `AirwardenKit`, a `airwarden-probe` CLI, a
`dev.<owner>.airwarden.helper` label) and as an app name, and neither showed a collision in the
quick check.

Sources consulted (search results, 2026-10-20):

- [CurveFan](https://github.com/BeastOrange/CurveFan)
- [SMCKit](https://github.com/beltex/SMCKit)
- [FanBar](https://github.com/helson-lin/FanBar/wiki)
- [SoloFan](https://www.producthunt.com/products/solofan-mac-fan-control-monitoring)
- [Macs Fan Control (Homebrew)](https://formulae.brew.sh/cask/macs-fan-control)
- [FanControl repo example](https://github.com/Lakypayiui/FanControl)
- [smcFanControl (AppleVis)](https://www.applevis.com/apps/mac/utilities/smcfancontrol)
- [NZXT Sentry](https://www.bhphotovideo.com/c/product/1165538-REG/nzxt_sen2_001_sentry_2_full_system.html)
- [UK Trade Mark Journal 2025/021](https://www.ipo.gov.uk/t-tmj/tm-journals/2025-021/UK00004184187.html)
