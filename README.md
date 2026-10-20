# FanControl — DynamicNotch ファン制御統合パッケージ

統合設計書（`docs/integration-design.md`）の案C（全 Swift 実装 + SMAppService 方式の特権ヘルパー）の実装である。
SMC の読取（温度・RPM）はアプリ内で IOKit を直接呼び、書込だけを root の launchd ヘルパーに XPC 経由で依頼する。
Mach サービス名は `com.example.dynamicnotch.DynamicNotch.fanfi`（既存の FanFi と競合しない）。
**対応は Apple Silicon のみ（Intel は 2026-10-20 に廃止）**: 書込は `F<n>Md` + `F<n>Tg` だけ。arm64 でない Mac では
アプリが `FanControlError.unsupportedPlatform` で SMC を開かず、ヘルパーは起動時に終了する。
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
| `Support/` | launchd plist、`Helper-Info.plist`、`manual-install/`（Team ID なしの個人利用向け手動インストール: `install.sh` / `uninstall.sh` / `status.sh`。`docs/helper.md` §6） |
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

- 実 macOS SDK に対して `swift build` が警告 0 で通る。2026-10-20 から `swift-tools-version: 6.0`、全ターゲット（テスト含む）Swift 6 言語モード
  （strict concurrency complete）、デプロイメントターゲット macOS 26。`FanControlManager` は `@MainActor`、ポーリングは専用キューを executor とする actor（`docs/kit.md`「Threading model」）
- `swift test` で 196 tests（30 suites）が通る（2026-10-20、Swift 6 言語モード移行後。Xcode 26.6）
- 実機の SMC 読取（2026-10-19、Mac14,9 / M2 Pro）: `fanfi-probe` でファン 2 基（2317〜6800 RPM）と温度キー 259 個を取得。
  書込は未試行。結果と所見は `docs/integration.md` §6 Phase 1、生出力は `docs/verification/`
- Mac14,9 のダンプに基づく Apple Silicon 対応（2026-10-19）: `TemperatureSampleFilter`（`Tp*` の 0 °C 付近の偽値を置換）、
  `emergencySensorPrefixes` から `TG` を除外（`SafetyPolicy.defaultEmergencySensorPrefixes`。Intel 廃止で機種別の分岐は削除）、
  `SensorCatalog` に Apple Silicon の名前を追加。詳細は `docs/kit.md` と `docs/integration.md` §6/§8
- 集約センサー（2026-10-20）: `SensorAggregator` が `agg:cpu` / `agg:cpu.p` / `agg:cpu.e` / `agg:gpu`（グループ最大値）を合成し、センサー連動プロファイルが単一キーに依存しないようにした（`docs/kit.md`）
- 手動インストール（個人利用）モード（2026-10-20）: ヘルパーは LaunchDaemon plist の `FANCONTROL_CLIENT_REQUIREMENT`（アプリの cdhash 固定、形式を厳密に検証）でクライアントを検証し、
  アプリは自分に Team ID が無いか手動インストールを検出するとインストール済みヘルパーの cdhash を要件にする。スクリプトは `--dry-run` でスモークアプリに対して確認済み。
  実インストール・接続は未実施（root が必要。手順は `Tools/HelperSmokeApp/README.md`）
- 書込前コードレビュー（2026-10-20、`docs/verification/pre-write-review-2026-10-20.md`）: 復元順序（`Md`=0 を先に、`Tg`=0 は書き戻さない）、部分失敗時のロールバック、ヘルパーの書込ポリシー（`F<n>Mn` を許可リストから除外、0x40 書込ビット必須）を修正。初回書込の手順チェックリストも同文書
- `DynamicNotchIntegration/` の UI 8 ファイル（と PATCHES.md の断片）を実 SDK + Defaults 8.2.0 + Settings 3.1.2 で型検査:
  `Tools/IntegrationTypeCheck` で `swift build`（Swift 5 / Swift 6 言語モードとも警告・エラー 0）。DynamicNotch 側はスタブ（`docs/integration.md` §7）

テストは Swift Testing（`import Testing`）で書かれている。XCTest は Xcode.app にしか同梱されないため
XCTest から移行した。Xcode.app があれば（確認済み: Xcode 26.6 で `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → 196 tests 通過）、または Linux の Swift 6 ツールチェーンでは、そのまま `swift test` で動く。
Command Line Tools だけの環境では Testing.framework の検索パスを自分で渡す必要がある（下記）。
SMC の読取確認は `swift run fanfi-probe`（`--dump` で全キー、`--watch N` で繰返し）。読み取り専用で sudo も不要。

未確認:

- DynamicNotch の実プロジェクト内での UI コードのコンパイル（型検査は DynamicNotch 側スタブに対してのみ）
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

- Team ID のプレースホルダ置換（`Support/Helper-Info.plist` と `FanControlHelperConstants.teamIdentifierPlaceholder` の 2 か所。出荷前に必須）。
  Team ID が無い個人利用では代わりに手動インストール（アドホック署名 + `sudo Support/manual-install/install.sh <App.app>`、cdhash 固定。`docs/helper.md` §6）を使える
- Apple Silicon の `Ftst` キー（一部機種で必要との報告。現状は書込許可リスト外。Mac14,9 / macOS 26 には存在しない。他機種は実機確認後に判断）
- 温度閾値（既定: 強制最大 95 °C / 警告 90 °C、ヒステリシス 5 °C）の機種別妥当性
- 設計書 §5 のその他の項目（センサー名のローカライズ、ポーリング間隔の自動切替、制御開始タイミング、ライセンス）
