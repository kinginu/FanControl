# FanControl — DynamicNotch ファン制御統合パッケージ

統合設計書（`docs/integration-design.md`）の案C（全 Swift 実装 + SMAppService 方式の特権ヘルパー）の実装である。
SMC の読取（温度・RPM）はアプリ内で IOKit を直接呼び、書込だけを root の launchd ヘルパーに XPC 経由で依頼する。
Mach サービス名は `com.example.dynamicnotch.DynamicNotch.fanfi`（既存の FanFi と競合しない）。
ホストアプリのプロジェクトに依存せずビルド・テストできるよう、
本実装は DynamicNotch 本体から切り離した独立 SwiftPM パッケージとして作成し、Xcode プロジェクトへローカルパッケージとして組み込む方針にしている。

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `Sources/FanControlCore` | 純ロジック: SMC キー/型/コーデック、モデル、検出、制御エンジン、プロファイル（Linux でもテスト可） |
| `Sources/FanControlSMC` | IOKit AppleSMC 読取/書込クライアント |
| `Sources/FanControlXPC` | ヘルパーとの XPC プロトコル・定数・書込許可リスト |
| `Sources/FanControlKit` | `FanControlManager` など app 側の層 |
| `Sources/FanControlHelper` | 特権 launchd デーモン |
| `Sources/FanControlProbe` | 読み取り専用の診断 CLI `fanfi-probe`（Phase 1 検証用。SMC には書き込まない） |
| `Support/` | launchd plist、`Helper-Info.plist` |
| `DynamicNotchIntegration/` | DynamicNotch ターゲットにドロップインする SwiftUI/設定/Live Activity ファイル、`PATCHES.md`、Localizable |
| `Tests/` | ユニットテスト（Core / SMC / XPC / Kit） |
| `docs/` | `integration.md`、`helper.md`、`kit.md`、実機出力 `verification/` |

## フェーズ対応（設計書 §6）

| Phase | 対応する実装 |
|---|---|
| Phase 1 | `FanControlCore` + `FanControlSMC`（読取）、検証用 `fanfi-probe` |
| Phase 2 | `DynamicNotchIntegration` のウィジェット/設定 |
| Phase 3 | `FanControlHelper` + `FanControlXPC` + `HelperInstaller` |
| Phase 4 | `FanControlManager` の制御/プロファイル + `FanWriteStrategy` |
| Phase 5（一部） | 警告、Live Activity コーディネータ、スリープ復帰時の再適用 |

## 検証状況

Linux 上で確認済み:

- `swift build` が通る
- 全ファイルが `swiftc -parse` を通る
- macOS 専用コードは SDK シグネチャのスタンドインで型検査済み（`docs/kit.md` 末尾）

Mac（Apple Silicon, macOS 26, Swift 6.3.3 / Command Line Tools）で確認済み:

- 実 macOS SDK に対して `swift build` が警告 0 で通る（Swift 5 言語モード。`-swift-version 6` でも診断 0）
- `swift test` で 70 tests（14 suites）が通る
- 実機の SMC 読取（2026-10-19、Mac14,9 / M2 Pro）: `fanfi-probe` でファン 2 基（2317〜6800 RPM）と温度キー 259 個を取得。
  書込は未試行。結果と所見は `docs/integration.md` §6 Phase 1、生出力は `docs/verification/`

テストは Swift Testing（`import Testing`）で書かれている。XCTest は Xcode.app にしか同梱されないため
XCTest から移行した。Xcode.app があれば、または Linux の Swift 6 ツールチェーンでは、そのまま `swift test` で動く。
Command Line Tools だけの環境では Testing.framework の検索パスを自分で渡す必要がある（下記）。
SMC の読取確認は `swift run fanfi-probe`（`--dump` で全キー、`--watch N` で繰返し）。読み取り専用で sudo も不要。

未確認:

- SwiftUI / Defaults / Settings を使う UI コードの型検査（`DynamicNotchIntegration/` はパッケージ外）
- DynamicNotch UI 上での読取表示、実機での SMC 書込、ヘルパー登録、署名要件

```
swift build
swift test

# Command Line Tools のみ（Xcode.app なし）の場合:
D=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $D/Frameworks \
  -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib
```

## 参照ドキュメント

- `docs/integration.md` — Xcode への組み込み手順と Mac での検証チェックリスト
- `docs/helper.md` — 特権ヘルパー（署名、登録、XPC、セッション、安全検査）
- `docs/kit.md` — app 側 `FanControlKit`（スレッドモデル、ポーリング、制御、永続化）
- `DynamicNotchIntegration/PATCHES.md` — DynamicNotch 既存ソースへの手作業パッチ (a)〜(g)

## 未決事項

- Team ID のプレースホルダ置換（`Support/Helper-Info.plist` と `FanControlHelperConstants.teamIdentifierPlaceholder` の 2 か所。出荷前に必須）
- Apple Silicon の `Ftst` キー（一部機種で必要との報告。現状は書込許可リスト外。Mac14,9 / macOS 26 には存在しない。他機種は実機確認後に判断）
- 温度閾値（既定: 強制最大 95 °C / 警告 90 °C、ヒステリシス 5 °C）の機種別妥当性
- 設計書 §5 のその他の項目（センサー名のローカライズ、ポーリング間隔の自動切替、制御開始タイミング、ライセンス）
