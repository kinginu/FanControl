# IntegrationTypeCheck

`FanControl/DynamicNotchIntegration/*.swift`（DynamicNotch アプリターゲットに追加するドロップイン SwiftUI ファイル 8 つ）を、
実 macOS SDK（SwiftUI / AppKit）と実際のサードパーティパッケージ（[sindresorhus/Defaults](https://github.com/sindresorhus/Defaults)・
[sindresorhus/Settings](https://github.com/sindresorhus/Settings)）に対して型検査するための作業用 SwiftPM パッケージ。
DynamicNotch の実 Xcode プロジェクトが無い環境でも UI コードをコンパイルできるようにするためのもので、成果物は出荷しない。
`FanControl/Package.swift` には含めていない（独立したパッケージ）。

## 実行方法

```
cd FanControl/Tools/IntegrationTypeCheck
swift build                      # Swift 5 言語モード
TYPECHECK_SWIFT6=1 swift build   # この target だけ Swift 6 言語モード（strict concurrency complete）
```

`Build complete!` で警告・エラー 0 なら合格。初回は GitHub から Defaults / Settings を取得する（ネットワークが必要）。
Command Line Tools のみ（Xcode.app 無し）の環境で動く。

## 構成

| パス | 内容 |
|---|---|
| `Package.swift` | ローカルパッケージ `../..`（`FanControlCore` / `FanControlKit`）、Defaults `from: 8.2.0`、Settings `from: 3.0.0` に依存 |
| `Package.resolved` | 検証に使った版: **Defaults 8.2.0**、**Settings 3.1.2**（2026-10-19 時点の最新安定版。Defaults 9 は beta のみ） |
| `Sources/IntegrationTypeCheck/FanControl*.swift` | `../../../../DynamicNotchIntegration/*.swift` への **シンボリックリンク**（SwiftPM はリンク先をそのままコンパイルする）。ソースは複製しない |
| `Sources/IntegrationTypeCheck/DynamicNotchStubs.swift` | DynamicNotch 側シンボルのスタブと、`PATCHES.md` の断片の書き写し（下記） |

ドロップインファイルを追加・改名したら、シンボリックリンクも作り直す:

```
cd Sources/IntegrationTypeCheck
for f in ../../../../DynamicNotchIntegration/*.swift; do ln -sf "$f" .; done
```

## スタブしているもの

8 つのドロップインファイル自体は DynamicNotch 側のシンボルを（コメント以外で）参照しないため、スタブ無しでコンパイルできる。
`DynamicNotchStubs.swift` は `PATCHES.md` の断片を型検査するために、次を ホストアプリでの使い方に倣って最小限で宣言している:

- `Preferences` / `WidgetPrefs` プロトコル（要件は資料に無いため、共通の準拠と `gridSizeType` のみ）
- `NookWidget`（既存 case は `timer` のみに省略）と `NookWidget.NookGridSizeType`（small = 0 / medium = 2 / doubleWide = 5）
- `LiveActivity`（`battery` と `fanAlert` のみ）、`ActiveLiveActivitiesManager`（`insertSync` / `removeSync`）
- `BlankView`、`TimerWidgetView`、`TimerWidgetSettingsView`（既存の switch 分岐の代用）

続けて `PATCHES.md` の (a)(b)(c)(d)(e)(f) の断片を書き写している。**PATCHES.md を変えたらこのファイルも手で合わせること。**
(g) はパッチ不要なので対象外。
