# IntegrationTypeCheck

`FanControl/DynamicNotchIntegration/*.swift`（DynamicNotch アプリターゲットに追加するドロップインファイル 9 つ。うち
`FanControlSettingsStorage.swift` はアプリ全体の設定保存層 `SettingsStore`）を、実 macOS SDK（SwiftUI / AppKit）に対して型検査するための
作業用 SwiftPM パッケージ。サードパーティ依存は無い（2026-10-20 に sindresorhus/Defaults 依存を撤去し、設定保存を
`SettingsStore` に置換。保存形式は Defaults 8.2 と同一）。2026-10-20 に sindresorhus/Settings への依存を撤去した（ホストの設定ウィンドウは
SwiftUI 標準の `Settings` シーン。PATCHES.md (d)）。
DynamicNotch の実 Xcode プロジェクトが無い環境でも UI コードをコンパイルできるようにするためのもので、成果物は出荷しない。
`FanControl/Package.swift` には含めていない（独立したパッケージ）。

## 実行方法

```
cd FanControl/Tools/IntegrationTypeCheck
swift build                      # Swift 5 言語モード
TYPECHECK_SWIFT6=1 swift build   # この target だけ Swift 6 言語モード（strict concurrency complete）
```

`Build complete!` で警告・エラー 0 なら合格。ネットワーク不要。

```
swift test                       # FanControlSettingsCompatTests: Fan Control の設定キーが Defaults 8.2 の保存形式
                                 # （JSON 文字列）のまま読めることを、ユーザー設定の写し（DynamicNotchApp/Tests/
                                 # SettingsStorageTests/Fixtures）で確認。DN_SETTINGS_PLIST=<export> で別の写しを使う
```
Command Line Tools のみ（Xcode.app 無し）の環境で動く。

## 構成

| パス | 内容 |
|---|---|
| `Package.swift` | ローカルパッケージ `../..`（`FanControlCore` / `FanControlKit`）のみに依存（リモート依存なし。`Package.resolved` も無い） |
| `Tests/FanControlSettingsCompatTests/` | 設定保存の互換性テスト（上記） |
| `Sources/IntegrationTypeCheck/FanControl*.swift` | `../../../../DynamicNotchIntegration/*.swift` への **シンボリックリンク**（SwiftPM はリンク先をそのままコンパイルする）。ソースは複製しない |
| `Sources/IntegrationTypeCheck/DynamicNotchStubs.swift` | DynamicNotch 側シンボルのスタブと、`PATCHES.md` の断片の書き写し（下記） |

ドロップインファイルを追加・改名したら、シンボリックリンクも作り直す:

```
cd Sources/IntegrationTypeCheck
for f in ../../../../DynamicNotchIntegration/*.swift; do ln -sf "$f" .; done
```

## スタブしているもの

ドロップインファイル自体は DynamicNotch 側のシンボルを（コメント以外で）参照しないため、スタブ無しでコンパイルできる。
`DynamicNotchStubs.swift` は `PATCHES.md` の断片を型検査するために、次を ホストアプリでの使い方に倣って最小限で宣言している:

- `Preferences` / `WidgetPrefs` プロトコル（要件は資料に無いため、共通の準拠と `gridSizeType` のみ）
- `NookWidget`（既存 case は `timer` のみに省略）と `NookWidget.NookGridSizeType`（small = 0 / medium = 2 / doubleWide = 5）
- `LiveActivity`（`battery` と `fanAlert` のみ）、`ActiveLiveActivitiesManager`（`insertSync` / `removeSync`）
- `BlankView`、`TimerWidgetView`、`TimerWidgetSettingsView`（既存の switch 分岐の代用）
- `AppSettings.PaneIdentifier`（ホストの設定タブ ID。DynamicNotchApp  `DynamicNotchApp/Sources/SettingsRootView.swift` と同じ形）

続けて `PATCHES.md` の (a)(b)(c)(d)(e)(f) の断片を書き写している。**PATCHES.md を変えたらこのファイルも手で合わせること。**
(g) はパッチ不要なので対象外。
