# DynamicNotch への Fan Control 統合手順

対象: DynamicNotch の実 Xcode プロジェクト（最小 macOS 14.6、バンドル ID `com.example.dynamicnotch.DynamicNotch`）。
設計: `docs/integration-design.md`（§4 UI/ウィジェット/Live Activity/設定、§6 段階案 = 案C）。
ヘルパーの詳細: `docs/helper.md`。

## 0. 構成物

| パス | 内容 |
|---|---|
| `FanControl/Package.swift` | SwiftPM パッケージ（ライブラリ `FanControlCore` / `FanControlSMC` / `FanControlXPC` / `FanControlKit`、および Linux/CI 確認専用の実行ファイル `FanControlHelper`。後者は同梱しない。§2 参照） |
| `FanControl/Support/Helper-Info.plist` | ヘルパーに埋め込む Info.plist（`FanControlClientTeamID` を含む） |
| `FanControl/Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist` | launchd plist（唯一の正本。パッケージ内の他の場所にコピーは無い） |
| `FanControl/DynamicNotchIntegration/*.swift` | DynamicNotch ターゲットにコピーするドロップイン UI ファイル（下表） |
| `FanControl/DynamicNotchIntegration/PATCHES.md` | 既存ソースへの手作業パッチ (a)〜(g) |
| `FanControl/DynamicNotchIntegration/Localizable/{en,ja}.strings` | 追加文字列（UTF-8 ソース） |

ドロップインファイル:

| ファイル | 内容 |
|---|---|
| `FanControlWidgetSettings.swift` | `FanControlWidgetSettings` / `FanControlGeneralSettings`（Defaults 永続化）、`Defaults.Keys`、表示用フォーマッタ |
| `FanControlWidgetSettingsView.swift` | 設定 ▸ ウィジェット ▸ Fan Control（グリッドサイズ、表示ファン/センサー、°C/°F、プロファイル選択・目標 RPM 表示） |
| `FanControlSettingsView.swift` | 「Fan Control」設定ペイン（TabView: 一般/プロファイル/センサー＋エラーフッタ） |
| `FanControlGeneralTabView.swift` | 有効化、更新間隔、自動開始、非表示時停止、スリープ復帰再適用、警告、ヘルパー状態/インストール、自動制御復帰、SMC ダンプ書き出し |
| `FanControlProfilesTabView.swift` | プロファイル一覧・適用・作成/複製/削除、ファン毎のモード編集（自動/固定/センサー連動） |
| `FanControlSensorsTabView.swift` | 全センサー表（キー/名前/温度、ソート可） |
| `FanControlWidgetView.swift` | Nook ウィジェット本体（medium 100pt / doubleWide 250pt） |
| `FanControlLiveActivity.swift` | `FanControlAlertView`（Live Activity 表示）と `FanControlAlertCoordinator`（警告状態・一時展開通知・一般設定 `pollingInterval` / `reapplyProfileAfterWake`、および「いずれかの警告が ON」を `keepAlertsWhilePaused` として `FanControlManager` へ同期） |

## 1. パッケージの追加とリンク

1. Xcode で DynamicNotch プロジェクトを開き、**File ▸ Add Package Dependencies… ▸ Add Local…** で `FanControl/` フォルダ（`Package.swift` がある階層）を選ぶ。
   リポジトリ内に置く場合は `$(SRCROOT)/FanControl` を推奨（以降のパスはこの前提）。
2. DynamicNotch アプリターゲットの **General ▸ Frameworks, Libraries, and Embedded Content** に
   `FanControlCore` と `FanControlKit` を追加する（`FanControlSMC` / `FanControlXPC` は Kit 経由で推移的にリンクされる）。
3. DynamicNotch は既に sindresorhus の `Defaults` と `Settings` を使っているので、追加の依存は不要。

## 2. ヘルパーターゲット

ヘルパーは **Xcode の Command Line Tool ターゲットとしてのみ** 作る（詳細と理由は `docs/helper.md` §1）。
SwiftPM の executable product `FanControlHelper` を同梱してはいけない。SwiftPM のビルドは `Helper-Info.plist` を
Mach-O に埋め込まないため、ヘルパーが Team ID をプレースホルダ `TEAMID0000` にフォールバックし、すべてのクライアントを拒否する。


1. **File ▸ New ▸ Target ▸ macOS ▸ Command Line Tool**、名前 `FanControlHelper`、言語 Swift。
2. 自動生成された `main.swift` を削除し、`FanControl/Sources/FanControlHelper/*.swift` を追加（ファイル参照のみ、コピー不要）。
3. ターゲットの Frameworks に `FanControlCore` / `FanControlSMC` / `FanControlXPC` を追加。
4. Build Settings（Info.plist の埋め込みは **手動 `-sectcreate` 方式に統一** する）:
   - `PRODUCT_NAME = FanControlHelper`
   - `PRODUCT_BUNDLE_IDENTIFIER = com.example.dynamicnotch.DynamicNotch.fanfi`（署名 identifier になる。アプリはヘルパーに
     `identifier "com.example.dynamicnotch.DynamicNotch.fanfi"` を要求する: `FanControlHelperConstants.helperCodeSigningRequirement`）
   - `OTHER_LDFLAGS = -sectcreate __TEXT __info_plist $(SRCROOT)/FanControl/Support/Helper-Info.plist`
   - `GENERATE_INFOPLIST_FILE = NO` と `CREATE_INFOPLIST_SECTION_IN_BINARY = NO`（どちらかが YES だと Xcode も
     `__info_plist` セクションを作り、手動 `-sectcreate` と重複してリンクエラーになるか、生成側の Info.plist に
     `FanControlClientTeamID` が入らない）。`INFOPLIST_FILE` は空のままにする。
   - `ENABLE_HARDENED_RUNTIME = YES`
   - `SKIP_INSTALL = YES`
   - `MACOSX_DEPLOYMENT_TARGET = 14.6`（アプリと揃える）

結果として Xcode プロジェクトに必要なターゲットは、既存の DynamicNotch アプリターゲットと新規の `FanControlHelper`
（Command Line Tool）の 2 つだけ。Core / SMC / XPC / Kit はローカル SwiftPM パッケージのライブラリ product としてリンクする。

## 3. アプリへの埋め込み

DynamicNotch アプリターゲットで:

1. **Build Phases ▸ Target Dependencies** に `FanControlHelper` を追加。
2. **Copy Files** フェーズを 2 つ追加:
   - Destination **Executables**（= `Contents/MacOS`）: `FanControlHelper`（Code Sign On Copy にチェック）
   - Destination **Wrapper**, Subpath `Contents/Library/LaunchDaemons`: `FanControl/Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist`
3. ビルド後の配置を確認:
   ```
   DynamicNotch.app/Contents/MacOS/FanControlHelper
   DynamicNotch.app/Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist
   ```

## 4. 署名と Team ID

1. `FanControl/Support/Helper-Info.plist` の `FanControlClientTeamID` を DynamicNotch の実 Team ID に置き換える。
2. `FanControl/Sources/FanControlXPC/FanControlHelperConstants.swift` の `FanControlHelperConstants.teamIdentifierPlaceholder`（`TEAMID0000`）も同じ値にする
   （Info.plist が読めなかった場合のフォールバック。プレースホルダのままだとすべてのクライアントを拒否する）。
   Team ID の置換箇所はこの 2 か所（`Support/Helper-Info.plist` と `teamIdentifierPlaceholder`）。後者を置き換えない場合のみ
   3 か所目として実行時の `FanControlManager.shared.clientTeamID` が必要（下記）。
   加えてアプリ側がヘルパーの署名を検証する（`HelperClient` が接続ごとに `setCodeSigningRequirement` で
   `FanControlHelperConstants.helperCodeSigningRequirement(teamID:)` を課す）。この Team ID は
   `FanControlManager.shared.clientTeamID`（既定値は `teamIdentifierPlaceholder`）。上記 2 の定数を置き換えれば追加作業は不要。
   定数を置き換えない場合は、起動時（最初のヘルパー呼び出し前、PATCHES.md (e)）に
   `FanControlManager.shared.clientTeamID = "<TeamID>"` を設定する。いずれかを怠るとヘルパーへの接続がすべて失敗する。
3. アプリとヘルパーを **同じ Team ID** で署名し、両方 **Hardened Runtime** を有効にする。配布時はアプリ全体を公証する。
4. 確認:
   ```sh
   codesign -dvvv DynamicNotch.app/Contents/MacOS/FanControlHelper   # TeamIdentifier, flags=0x10000(runtime)
   otool -s __TEXT __info_plist DynamicNotch.app/Contents/MacOS/FanControlHelper | head
   codesign -d -r- DynamicNotch.app
   ```

**App Sandbox:** DynamicNotch は **サンドボックス化してはいけない**（推奨）。どうしてもサンドボックスを有効にする場合は、
アプリの entitlements に次の 2 つの一時例外が必須（無いとアプリ内での SMC 読み取りとヘルパーへの XPC 接続がどちらも失敗する）:

| キー | 値 |
|---|---|
| `com.apple.security.temporary-exception.iokit-user-client-class` | `AppleSMCClient`（配列で指定） |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | `com.example.dynamicnotch.DynamicNotch.fanfi`（配列で指定） |

一時例外は Mac App Store 審査で拒否されうるため、Developer ID 配布（非サンドボックス）を前提とする。
ヘルパー（`FanControlHelper`）自体は root の launchd デーモンであり、**サンドボックス化しない**（App Sandbox entitlement を付けない）。

安全検査はヘルパーが最終責任を持つ（helper.md §4）: 書込許可リスト（`F<n>Tg` / `F<n>Md` / `FS! ` / `F<n>Mn`）、
ペイロード 1〜32 バイトかつ SMC の `dataSize` と一致、`F<n>Tg`/`F<n>Mn` はセッション開始時に読んだハードウェア
`F<n>Mn`〜`F<n>Mx`（±1 RPM 許容）、`F<n>Md` は 0/1、`FS! ` は `1 << FNum` 未満。アプリ側のポーリング書込は
目標値の変化が 25 RPM（`FanControlManager.writeThresholdRPM`）以下なら書かない（kit.md）。

## 5. UI ファイルとパッチ

1. `FanControl/DynamicNotchIntegration/*.swift`（8 ファイル）を DynamicNotch アプリターゲットに追加する。
   各ファイルは `#if os(macOS)` で囲まれ、`Defaults` / `Settings` / `FanControlCore` / `FanControlKit` を import する。
   **注意:** `import Settings`（sindresorhus/Settings）と `import SwiftUI` を同じファイルで使うと、`Settings` が SwiftUI の
   `Settings` シーン（`struct Settings<Content>: Scene`）と衝突して `Settings.Container` / `Settings.Section` /
   `Settings.Pane` が曖昧または誤解決になることがある。DynamicNotch の既存設定ビュー（`LiveActivitiesSettingsView` など）が
   使っている書き方（モジュール修飾や typealias など）をそのまま `FanControlGeneralTabView.swift` と PATCHES.md (d) にも適用すること。
2. `PATCHES.md` の (a)〜(g) を既存ソースに適用する:
   (a) `NookWidget.fanControl`（tag 8）、(b) Nook グリッドの View 振り分け、(c) `WidgetsSettingsTabView`、
   (d) 設定ペイン登録、(e) `applicationDidFinishLaunching`、(f) `LiveActivity.fanAlert` と `LiveActivityView`、
   (g) 終了処理（パッチ不要。`FanControlManager` が `NSApplication.willTerminateNotification` で自動制御に戻す）。
3. 文字列: `Localizable/en.strings` と `ja.strings` の項目を、プロジェクトの `en.lproj/Localizable.strings` /
   `ja.lproj/Localizable.strings`（ソース側）にマージする。アプリ内に同梱されているのはコンパイル済み（バイナリ/UTF-16 plist）の
   `.strings` なので、ビルド成果物ではなくソースを編集する。String Catalog（`.xcstrings`）を使っている場合は
   ビルド後に自動抽出されたキーへ ja 訳を入力する（キーは英語文字列そのもの）。
4. ビルドして警告/エラーを解消する（このリポジトリでは型検査できていない。§7 参照）。

## 6. Mac での検証チェックリスト（Phase 1 → 5）

実機（できれば Apple Silicon と Intel の両方、ファンレスの MacBook Air も）で順に確認する。

### Phase 1: 読み取り（ヘルパー不要）

**パッケージ単体（`fancontrol-probe`、UI なし）**: 2026-10-19、MacBook Pro 14" Mac14,9（Apple M2 Pro）/ macOS 26.5.2（25F84）/
Swift 6.3.3（Command Line Tools のみ）で確認。SMC への書込は一切していない（probe は読み取り専用）。
出力: [`verification/Mac14,9-macOS26-probe.txt`](verification/Mac14,9-macOS26-probe.txt)、
[`verification/Mac14,9-macOS26-dump.txt`](verification/Mac14,9-macOS26-dump.txt)（`BMSN` のバッテリーシリアルのみ伏せ字）。

```sh
swift run fancontrol-probe            # 機種・キー数・ファン・温度
swift run fancontrol-probe --dump     # 全キーの型/サイズ/属性/生バイト
swift run fancontrol-probe --watch 2  # ファン・温度を 2 秒ごとに再表示
```

- [x] 非特権プロセスから `AppleSMC` を開ける（`IOServiceMatching("AppleSMC")` → `IOServiceOpen` 成功）。`#KEY` = 2299、全キー列挙可。
- [x] `FanDiscovery.discoverFans`: `FNum` = 2、2 基とも `F<n>Mn` 2317 / `F<n>Mx` 6800 RPM（`flt `）。
      アイドル時 `F<n>Ac` = `F<n>Tg` = 0（ファン停止）、`F<n>Md` = 0 → `.automatic`。`F<n>ID` は存在せず名前は「Fan 1」「Fan 2」にフォールバック。`FS! ` も存在しない。
- [x] `SensorCatalog.discoverTemperatureSensors`: `T*` キー 259 個（`flt ` 250、`ioft` 9）がすべて −20〜130 °C に入り検出された。
      `ioft` はリトルエンディアンだった（修正前はビッグエンディアン扱いで 9 個とも範囲外として落ちていた）。`readTemperatures` の再読取も 259/259。
- [x] 型/コーデック: ファン・温度の経路は `flt `（LE Float32）と `ui8 ` のみで正しく復号。未対応だった `si64` を追加。`{jst`（4 キー、21 バイト構造体）は `.bytes` のまま。
- [ ] センサー名: 多くのキーが `SensorCatalog` の名前に当てはまらない、または値が温度として不自然（下記「Mac14,9 の所見」）。
- [ ] 以下の UI 項目は未実施（Xcode.app が無いため DynamicNotch へ未組込）。

**Mac14,9 の所見（ダンプから読み取れる範囲）**

- 属性ビット: 読取に成功した 2170 キーはすべて `0x80` を持ち、`0x80` の無い 54 キーはすべて読取失敗 → `0x80` は読取ビット。
  書込候補の `F<n>Tg` = `0xd4`、`F<n>Md` = `0xd0` は `0x40` を持ち、`F<n>Mn` = `0x84`、`F<n>Mx` = `0x85`、`FNum` = `0x80` は持たない。
  `SMCKeyInfo.isWritable` を `0x40` に変更（書込は未試行なので推定）。
- `Ftst` は存在しない（`keyInfo` が `0x84` keyNotFound）。`F<n>Md`（`ui8 ` 1 バイト）、`F<n>Tg`（`flt ` 4 バイト）、`F<n>Ac`（`flt `、attr `0x84`）は存在。
  他に `F<n>Dc`（`flt `, `0x95`）、`F<n>Fb`（`ui8 `）、`F<n>Fc`（`ui16`）、`F<n>St`（`ui8 `, 値 3）、`F<n>Sf`（`ui16`, 値 0）、`FOff`（`ui8 `, 値 1）、`FRmp`、`FOFC`、`FBAD` があるが意味は未確認。
- 整数型のエンディアンはキーごとに異なる: `#KEY`・`FOFC`・`F<n>Fc` はビッグエンディアン、バッテリー系（`B*`）や観測した `ui64`/`si64` はリトルエンディアンに見える。
  `SMCCodec` の整数はビッグエンディアンのまま（ファン/温度経路は影響なし）。整数キーを新たに使う場合は実機で確認すること。
- 読取失敗 126 キー: 32 バイト超（`SMCClient` は 32 バイトまで）42 個、`0x80` 無し 54 個（両方に該当 11 個）、残り 41 個は `0x80` ありで SMC がエラーを返す。
- 温度として不自然な値（`--watch 3` で 4 回読んで確認）:
  - 負値で一定: `Tf02` −12.23、`Tf12` −12.80、`Tf22` −11.38（ほか `Tf00`/`Tf10` ≈ −0.1〜0.1）。
  - 一定値: `Tf06` 94.50、`Tf16`/`Tf26` 79.42、`Ta0D`/`Ta0H`/`Ta0L` 9.50、`Tf01`/`Tf11`/`Tf21` 5.7〜12.2。温度ではなく閾値等の可能性があるが未確認。
  - 常に 0.00: `TH1a`, `TH1b`, `TVMD`, `Ta0C/G/K/V`, `Tz11`〜`Tz18`, `Tz1j`。
  - `Tp*`（P コア）は 3 つ組ごとに 50〜75 °C の実測値と `0.00 / 6.70 / 8.43`（または `0.00 / 4.63 / 5.32`）の固定パターンを読取ごとに行き来する。
    最大値（緊急判定）には影響しないが、センサー連動モードで単一の `Tp*` キーを選ぶと 0 °C 付近を読むことがある。
  - `TG*`（`ioft`、33 °C 前後、`TB0T` とほぼ同値）は Intel では GPU 用接頭辞として `emergencySensorPrefixes` に入っているが、この機種では GPU の値に見えない（GPU は `Tg*`）。
- 名前が付かないが関連が深そうなキー（値の推移からの推測を含むため要確認）: `TCMb`/`TCMz`/`TCDX`（CPU 系 55〜75 °C）、`TPD*`・`TRD*`（44 °C / 48 °C 前後の群）、
  `Th0*`（48 °C 前後）、`TVM0`/`TVm0`/`TVm1`（60〜67 °C）、`TD*`（29〜34 °C、`TDBP` 等）、`TB1T`/`TB2T` は「Battery 1T/2T」と表示される（`TB0T` と同値）。
  `TH0a`/`TH0b`/`TH0x`（「Storage」、38 °C 前後）は SSD と思われるが未確認。

**DynamicNotch UI（未実施）**

- [ ] 設定 ▸ Fan Control ▸ 一般で「ファン制御を有効にする」を ON → センサー タブに温度が並ぶ（キー/名前/温度、ソート可）。
- [ ] Nook にウィジェット（設定 ▸ ウィジェットで Fan Control を追加）→ ファン名・現在 RPM・RPM バー・温度 3 件が表示され、更新間隔どおりに変わる。
- [ ] 2x1 / ダブルワイド切替で幅が 100pt / 250pt になる。°C/°F 切替が反映される。
- [ ] ファンレス機では「ファンが見つかりません」、SMC が開けない環境では「SMC を利用できません」。
- [ ] 機能 OFF でウィジェットに「ファン制御は無効です」。Nook を閉じるとポーリングが止まる（Activity Monitor で CPU 使用がほぼ 0）。
- [ ] 「SMC ダンプを書き出す…」で保存したテキストにキー一覧が出る（未知機種のセンサー名調査用）。ダンプ作成中も UI が固まらず、ボタンが無効化されインジケータが出る。

### Phase 2/3: ヘルパー登録
- [ ] 一般タブのヘルパー状態が「未インストール」→「ヘルパーをインストール…」→「承認待ち」になり、案内文と「ログイン項目を開く」が表示される。
- [ ] システム設定 ▸ 一般 ▸ ログイン項目と機能拡張（macOS 15）/ ログイン項目（macOS 14）で DynamicNotch を許可 →「再確認」で「インストール済み」。
- [ ] `.notFound`（plist 配置ミス）では「アプリバンドル内に見つかりません」と案内のみ表示され、インストールボタンは出ない。
- [ ] `sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi` でサービスが見える。
- [ ] `log stream --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'` に接続ログ。

### Phase 4: 書き込み・プロファイル
- [ ] プロファイル タブで「最大」を適用 → 接続状態が「接続済み（ファンを制御中）」、ファンが最大回転へ。
      Apple Silicon では `F0Md`=1 → `F0Tg` 書込、Intel では `FS! ` ビット → `F0Tg` 書込で回転数が変わること（`F0Ac` を確認）。
- [ ] 新規プロファイルで「固定」スライダ / 「センサー連動」（センサー・開始/最大温度）を設定して保存 → 適用 → 期待通りの回転数。
- [ ] 組み込みプロファイルは編集・削除できず、複製はできる。
- [ ] アプリ再起動後も保存したプロファイルとアクティブ選択が残る。
- [ ] 「自動制御に戻す」でファンが SMC 制御に戻る。機能を OFF にしても戻る。アプリ終了時（⌘Q）も戻る。
- [ ] 手動制御中に `kill -9` → ヘルパーがセッションを解放しファンが自動に戻る（helper.md §5）。
- [ ] ウィジェットのプロファイルメニューから切替できる。
- [ ] 機能 OFF の間はプロファイル タブの「適用」が無効で、説明文が表示される。
- [ ] 監視停止中に手動プロファイルを適用すると監視が自動で開始される。
- [ ] 適用直後にポーリングが走っても、旧プロファイルの目標値に書き戻されない（`log stream` のヘルパー書込ログで確認）。
- [ ] ヘルパーを `sudo kill -STOP` で停止させて書込 → 約 8 秒で「timeout」エラーになり、以後の操作が詰まらない（確認後 `kill -CONT`）。

### Phase 5: 高度機能
- [ ] 負荷をかけて CPU/GPU センサーが 90°C（`SafetyPolicy.highTemperatureAlert`）以上 → ウィジェットが赤表示、Live Activity「高温」とノッチの一時展開。85°C 以下で解除。
- [ ] 書込セッション中、95°C（`emergencyTemperature`）以上で全ファン最大に強制される（自動プロファイルでも）。
      90°C（95 − `alertHysteresis`）以下に下がるまで解除されない（`FanControlManager.emergencyOverrideActive`）。
- [ ] ファン停止（目標 > 0 で実測 0 が 3 回連続）→ 該当ファン行に警告アイコン、Live Activity「ファン停止」（テストは固定モードで物理的に止める等、注意して行う）。
- [ ] 警告トグルを OFF にすると Live Activity が出ない。
- [ ] 手動プロファイル適用中にスリープ → 復帰後約 5 秒で再適用される（「スリープ解除後にプロファイルを再適用」ON 時。
      OFF にすると再適用せず、復帰約 5 秒後に書込セッションを閉じる（ヘルパーがセッション前の値に戻す）。
      設定は `FanControlAlertCoordinator` が `FanControlManager.reapplyProfileAfterWake` に同期）。
- [ ] 書込セッション無しで Nook を閉じても、警告が 1 つでも ON なら低頻度ポーリング（`max(5×間隔, 10 秒)`）が続き警告が出る。両方 OFF なら停止する。
- [ ] バッテリー駆動で更新間隔 10 秒・Nook 非表示時停止の効果を確認。

## 7. この Linux 環境で検証できなかったこと

- **SwiftUI / Defaults / Settings を使う UI コードの型検査は未実施**。`swiftc -parse`（構文のみ）は全ファイル通過。
  `FanControlWidgetSettings.swift` だけは Defaults のスタブと実 `FanControlCore` で型検査・実行（エンコード/デコード、既定値、表示センサー選択、温度整形）を確認した。
  `FanControlKit` 側は macOS SDK のスタンドイン（シグネチャのスタブ）で型検査済み（`docs/kit.md` 末尾）。
- UI が参照する Kit/Core の API（メンバー名、引数ラベル、`async`/`throws`、読み取り専用か否か、static か否か、
  `HelperInstallStatus` / `HelperConnectionState` の case）は実装と突き合わせ済み。`FanControlManager` は `@MainActor` ではない
  （`@unchecked Sendable`、状態はメインスレッドで更新）。UI はメインスレッドから呼び、async メソッドは `Task { @MainActor in … }` で待つ。
- `Settings.Section(label:content:)` / `Settings.Container` / `Settings.Pane` のシグネチャは sindresorhus/Settings の公開 API に基づく推定。
  DynamicNotch 内の実際の使い方（参照ソースでは `Section { … }`）と違えば合わせる。
- `NookWidget` の View 振り分け箇所、`WidgetPrefs` / `Preferences` プロトコルの要件、`ActiveLiveActivitiesManager` インスタンスの保持場所はホスト側のソースから特定できていない（PATCHES.md 参照）。
- SMC 読取はパッケージ単体で Mac14,9 / macOS 26 にて確認済み（§6 Phase 1）。SMC 書込、ヘルパー登録、署名要件は未検証。

## 8. 未決事項（設計書 §5 より）

- **Team ID**（§5.1）: `Helper-Info.plist` と `teamIdentifierPlaceholder` の実値。出荷前に必須。
- **Mach サービス名**（§5.2）: `com.example.dynamicnotch.DynamicNotch.fanfi` で既存 FanFi と非競合。両方が同時に SMC を書くと互いに上書きし合うため、併用時の注意をユーザーに示すかは要判断。
- **新しい Apple Silicon の `Ftst` キー**（§5.7, helper.md §4）: 一部機種では `F<n>Md` だけでは目標値が効かず `Ftst` アンロックが必要との報告がある。現状ヘルパーの書込許可リスト外。Phase 4 で実機確認後に追加を判断。
  Mac14,9（M2 Pro）/ macOS 26 には `Ftst` キー自体が存在しない（読取で keyNotFound、§6 Phase 1）。この機種では許可リストに足しても書けない。
- **温度閾値**（§5.6）: 警告 90°C（ヒステリシス 5°C）、強制最大 95°C、対象センサー接頭辞 `Tp/Te/TC/Tg/TG` は暫定値（Mac14,9 では `TG*` は GPU ではなく 33 °C 前後の `ioft` キー。`Tf06` は 94.5 °C 一定だが接頭辞外。§6 Phase 1 の所見参照）。機種別に妥当性を確認し、設定 UI に出すか決める（現状 UI には出していない）。
- **センサー名**（§5.7）: `SensorCatalog` の名称はコミュニティ情報で英語固定。機種別検証とローカライズ方針が未定。
- **ポーリング間隔**（§5.4）: 1/2/5/10 秒の選択式。電源状態による自動切替は未実装。
- **制御開始タイミング**（§5.5）: 既定は機能 OFF。ON かつ「起動時に監視を開始」で起動時に監視（読み取り）を開始、OFF の場合はウィジェット初表示時に開始。ファン書き込みはユーザーがプロファイルを適用したときのみ。
- **ライセンス**（§5.8）: 法務確認。
