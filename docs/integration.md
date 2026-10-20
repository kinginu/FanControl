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
4. Build Settings（Info.plist の埋め込みは **手動 `-sectcreate` 方式に統一** する。以下は `Tools/HelperSmokeApp` で Xcode 26.6 により実ビルド確認済みの値）:
   - `PRODUCT_NAME = FanControlHelper`
   - `PRODUCT_BUNDLE_IDENTIFIER = com.example.dynamicnotch.DynamicNotch.fanfi`（署名 identifier になる。アプリはヘルパーに
     `identifier "com.example.dynamicnotch.DynamicNotch.fanfi"` を要求する: `FanControlHelperConstants.helperCodeSigningRequirement`）
   - `OTHER_LDFLAGS = $(inherited) -sectcreate __TEXT __info_plist "$(SRCROOT)/FanControl/Support/Helper-Info.plist"`
     （パスに空白が入りうるので引用符で囲む）
   - `GENERATE_INFOPLIST_FILE = NO`、`CREATE_INFOPLIST_SECTION_IN_BINARY = NO`、`INFOPLIST_FILE` は空。
     Xcode 26.6 での実測（2026-10-20）: `GENERATE_INFOPLIST_FILE = YES` だけなら生成 Info.plist はバイナリに入らず無害。
     `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` + `INFOPLIST_FILE` を併用すると Xcode が 2 つ目の `-sectcreate __TEXT __info_plist`
     （`Processed-Info.plist`）を渡す。リンクエラーにはならずセクションは 1 個だったが、どちらが採用されるかは保証が無いので二重指定はしない。
   - `ENABLE_HARDENED_RUNTIME = YES`
   - `SKIP_INSTALL = YES`
   - `MACOSX_DEPLOYMENT_TARGET = 14.6`（アプリと揃える）
   - 署名はアプリと同じ（`CODE_SIGN_STYLE`、`DEVELOPMENT_TEAM`、`CODE_SIGN_IDENTITY`）。

   ヘルパーのソース 6 ファイルは Xcode ターゲットで直接コンパイルされ、Core / SMC / XPC は静的リンクされる（`otool -L` にパッケージ由来の
   dylib は出ない）。パッケージの executable product `FanControlHelper` はアプリが参照しない限りビルドされない（名前が同じでも衝突しない）。

結果として Xcode プロジェクトに必要なターゲットは、既存の DynamicNotch アプリターゲットと新規の `FanControlHelper`
（Command Line Tool）の 2 つだけ。Core / SMC / XPC / Kit はローカル SwiftPM パッケージのライブラリ product としてリンクする。

## 3. アプリへの埋め込み

DynamicNotch アプリターゲットで:

1. **Build Phases ▸ Target Dependencies** に `FanControlHelper` を追加。
2. **Copy Files** フェーズを 2 つ追加:
   - Destination **Executables**（= `Contents/MacOS`）: `FanControlHelper`（Code Sign On Copy にチェック。コピー時に
     `--preserve-metadata=identifier,entitlements,flags` で再署名され、identifier と runtime フラグは保たれる）
   - Destination **Wrapper**, Subpath `Contents/Library/LaunchDaemons`: `FanControl/Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist`
3. ビルド後の配置を確認:
   ```
   DynamicNotch.app/Contents/MacOS/FanControlHelper
   DynamicNotch.app/Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist
   ```
   plist のファイル名は `FanControlHelperConstants.plistName` と一致していなければならない（違うと `SMAppService` の状態が `.notFound`）。
   launchd plist の `BundleProgram` は `Contents/MacOS/FanControlHelper`（バンドルルートからの相対パス）。

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
   codesign -dvvv --entitlements - DynamicNotch.app/Contents/MacOS/FanControlHelper   # Identifier, TeamIdentifier, flags に runtime(0x10000)
   launchctl plist __TEXT,__info_plist DynamicNotch.app/Contents/MacOS/FanControlHelper   # 埋め込み Info.plist（FanControlClientTeamID）
   codesign -d -r- DynamicNotch.app
   codesign --verify --deep --strict -v DynamicNotch.app
   ```
   `otool -s __TEXT __info_plist` は 16 進ダンプしか出さず、arm64 では `otool -X … | xxd -r -p` でも 32 ビットワードのバイト順が崩れて
   plist に戻らない。`launchctl plist` か `segedit <bin> -extract __TEXT __info_plist out.plist` を使う。
   - **アドホック署名（`CODE_SIGN_IDENTITY = -`）での注意**: Xcode 26.6 は `ENABLE_HARDENED_RUNTIME = YES` でもアドホック署名時に
     `-o runtime` を付けない（`flags=0x2(adhoc)` になる）。アドホックで確認するときは `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime`
     を足す（`Tools/HelperSmokeApp/project.yml`）。実 ID での署名では不要（付けても無害）。
   - **実署名後に確認**: Xcode は Command Line Tool ターゲットに `com.apple.application-identifier` entitlement を自動で注入する
     （アドホックでは値 = bundle ID。`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` でも消えない）。Developer ID 署名でプロビジョニングプロファイル無しに
     これが残ると launchd 起動時に拒否される恐れがあるので、Team ID 付きビルドで `codesign -d --entitlements -` を確認する（未確認）。

**最小アプリでの検証（2026-10-20）**: §1〜§4 のレシピを XcodeGen の最小アプリ `Tools/HelperSmokeApp`（`README.md`）で再現し、
Xcode 26.6 の `xcodebuild` でビルド・配置・埋め込み Info.plist・アドホック署名・識別子の一致を確認した（ビルドのみ。登録・起動・書込はしていない）。
証跡と見つかった不一致（launchd plist のファイル名がコードと不一致だったのを修正、ほか）は
[`verification/helper-bundle-smoke-2026-10-20.md`](verification/helper-bundle-smoke-2026-10-20.md)。

**代替: 手動インストール（個人利用モード、Team ID なし）**: Apple Developer Program が無く Team ID 署名ができない場合は、上記 1〜3 の代わりに
アプリとヘルパーを **アドホック署名**（`CODE_SIGN_IDENTITY = -`、Hardened Runtime を付けるなら `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime`）でビルドし、
ヘルパーを `sudo FanControl/Support/manual-install/install.sh <DynamicNotch.app>` で `/Library/PrivilegedHelperTools/` と `/Library/LaunchDaemons/` に手動で入れる
（helper.md §6）。§1〜§3 のターゲット・Copy Files 構成はそのままでよい（`install.sh` はバンドル内の `Contents/MacOS/FanControlHelper` をコピーする。
バンドル内の SMAppService 用 plist は使われない）。Team ID の置換（上記 1・2）は不要:
ヘルパーは LaunchDaemon plist の `FANCONTROL_CLIENT_REQUIREMENT`（アプリの cdhash を固定）でクライアントを検証し、アプリは自分に Team ID が無いこと・
手動インストールのファイルがあることを検出して、インストール済みヘルパーの cdhash を要件に使う（kit.md「Helper requirement and install status」）。
- アプリを再ビルドするたびに cdhash が変わるので `sudo install.sh` を再実行する（しないとヘルパーが接続を拒否する）。
- **Debug ビルドは `ENABLE_DEBUG_DYLIB = NO`**（または Release）にする。既定の Debug はアプリをスタブ + `DynamicNotch.debug.dylib` に分け、
  アドホック + Hardened Runtime ではライブラリ検証が dylib を拒否して起動しない（2026-10-20 にスモークアプリで確認）。
- 個人利用専用。配布には Team ID 方式を使う。手動インストールと SMAppService 登録を同時に入れない（Label / Mach サービス名が同じ）。

**App Sandbox:** DynamicNotch は **サンドボックス化してはいけない**（推奨）。どうしてもサンドボックスを有効にする場合は、
アプリの entitlements に次の 2 つの一時例外が必須（無いとアプリ内での SMC 読み取りとヘルパーへの XPC 接続がどちらも失敗する）:

| キー | 値 |
|---|---|
| `com.apple.security.temporary-exception.iokit-user-client-class` | `AppleSMCClient`（配列で指定） |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | `com.example.dynamicnotch.DynamicNotch.fanfi`（配列で指定） |

一時例外は Mac App Store 審査で拒否されうるため、Developer ID 配布（非サンドボックス）を前提とする。
ヘルパー（`FanControlHelper`）自体は root の launchd デーモンであり、**サンドボックス化しない**（App Sandbox entitlement を付けない）。

安全検査はヘルパーが最終責任を持つ（helper.md §4）: 書込許可リスト（`F<n>Tg` / `F<n>Md` / `FS! `。`F<n>Mn` は 2026-10-20 のレビューで除外）、
ペイロード 1〜32 バイトかつ SMC の `dataSize` と一致、`F<n>Tg`/`F<n>Mn` はセッション開始時に読んだハードウェア
`F<n>Mn`〜`F<n>Mx`（±1 RPM 許容）、`F<n>Md` は 0/1、`FS! ` は `1 << FNum` 未満。アプリ側のポーリング書込は
目標値の変化が 25 RPM（`FanControlManager.writeThresholdRPM`）以下なら書かない（kit.md）。

## 5. UI ファイルとパッチ

1. `FanControl/DynamicNotchIntegration/*.swift`（8 ファイル）を DynamicNotch アプリターゲットに追加する。
   各ファイルは `#if os(macOS)` で囲まれ、`Defaults` / `Settings` / `FanControlCore` / `FanControlKit` を import する。
   **注意:** `import Settings`（sindresorhus/Settings）と `import SwiftUI` を同じファイルで使うと、`Settings` が SwiftUI の
   `Settings` シーン（`struct Settings<Content>: Scene`）と衝突する。実 SDK + Settings 3.1.2 での型検査では、
   式の位置の `Settings.Container(…)` / `Settings.Section(…)` は解決できたが、型の位置（`extension Settings.PaneIdentifier`）は
   「'Settings' is ambiguous」、`Settings.Pane(…)` は SwiftUI 側に誤解決されてエラーになった。そのため `Settings.*` を使う
   ドロップインファイル（`FanControlGeneralTabView.swift` / `FanControlWidgetSettingsView.swift`）と PATCHES.md (d) では
   `import enum Settings.Settings`（スコープ付き import。Settings パッケージ自身が推奨）を併記している。パッケージ提供の
   `typealias AppSettings = Settings` を使う書き方でもよい。DynamicNotch の既存設定ビューが別の書き方をしていればそれに合わせてよい。
   Swift 6 言語モードでは PATCHES.md (d) の `static let fanControl` のために `@preconcurrency import Settings` が要る（PATCHES.md (d)）。
2. `PATCHES.md` の (a)〜(g) を既存ソースに適用する:
   (a) `NookWidget.fanControl`（tag 8）、(b) Nook グリッドの View 振り分け、(c) `WidgetsSettingsTabView`、
   (d) 設定ペイン登録、(e) `applicationDidFinishLaunching`、(f) `LiveActivity.fanAlert` と `LiveActivityView`、
   (g) 終了処理（パッチ不要。`FanControlManager` が `NSApplication.willTerminateNotification` で自動制御に戻す）。
3. 文字列: `Localizable/en.strings` と `ja.strings` の項目を、プロジェクトの `en.lproj/Localizable.strings` /
   `ja.lproj/Localizable.strings`（ソース側）にマージする。アプリ内に同梱されているのはコンパイル済み（バイナリ/UTF-16 plist）の
   `.strings` なので、ビルド成果物ではなくソースを編集する。String Catalog（`.xcstrings`）を使っている場合は
   ビルド後に自動抽出されたキーへ ja 訳を入力する（キーは英語文字列そのもの）。
4. ビルドして警告/エラーを解消する。`DynamicNotchApp/` への適用（2026-10-20）で必要だった差分は 2 点:
   `FanControlWidgetSettings` に `init()`（`Preferences` が `init()` を要求し、全引数既定値の init では満たせない。PATCHES.md (a)）、
   XcodeGen ではローカルパッケージ参照に `group:` を付けないと `../FanControl` のソースグループと衝突してドロップインがターゲットから落ちる
   （`DynamicNotchApp/project.yml`）。
   8 ファイルと PATCHES.md の断片は `Tools/IntegrationTypeCheck`（実 SDK + Defaults 8.2.0 +
   Settings 3.1.2、DynamicNotch 側はスタブ）で警告・エラー 0 を確認済み（§7）。実プロジェクトで出る差分はスタブと実ソースの違いに起因する。

## 6. Mac での検証チェックリスト（Phase 1 → 5）

実機（できれば Apple Silicon と Intel の両方、ファンレスの MacBook Air も）で順に確認する。

### Phase 1: 読み取り（ヘルパー不要）

**パッケージ単体（`fanfi-probe`、UI なし）**: 2026-10-19、MacBook Pro 14" Mac14,9（Apple M2 Pro）/ macOS 26.5.2（25F84）/
Swift 6.3.3（Command Line Tools のみ）で確認。SMC への書込は一切していない（probe は読み取り専用）。
出力: [`verification/Mac14,9-macOS26-probe.txt`](verification/Mac14,9-macOS26-probe.txt)、
[`verification/Mac14,9-macOS26-dump.txt`](verification/Mac14,9-macOS26-dump.txt)（`BMSN` のバッテリーシリアルのみ伏せ字）。

```sh
swift run fanfi-probe            # 機種・キー数・ファン・温度
swift run fanfi-probe --dump     # 全キーの型/サイズ/属性/生バイト
swift run fanfi-probe --watch 2  # ファン・温度を 2 秒ごとに再表示
```

- [x] 非特権プロセスから `AppleSMC` を開ける（`IOServiceMatching("AppleSMC")` → `IOServiceOpen` 成功）。`#KEY` = 2299、全キー列挙可。
- [x] `FanDiscovery.discoverFans`: `FNum` = 2、2 基とも `F<n>Mn` 2317 / `F<n>Mx` 6800 RPM（`flt `）。
      アイドル時 `F<n>Ac` = `F<n>Tg` = 0（ファン停止）、`F<n>Md` = 0 → `.automatic`。`F<n>ID` は存在せず名前は「Fan 1」「Fan 2」にフォールバック。`FS! ` も存在しない。
- [x] `SensorCatalog.discoverTemperatureSensors`: `T*` キー 259 個（`flt ` 250、`ioft` 9）がすべて −20〜130 °C に入り検出された。
      `ioft` はリトルエンディアンだった（修正前はビッグエンディアン扱いで 9 個とも範囲外として落ちていた）。`readTemperatures` の再読取も 259/259。
- [x] 型/コーデック: ファン・温度の経路は `flt `（LE Float32）と `ui8 ` のみで正しく復号。未対応だった `si64` を追加。`{jst`（4 キー、21 バイト構造体）は `.bytes` のまま。
- [ ] センサー名: 多くのキーが `SensorCatalog` の名前に当てはまらない、または値が温度として不自然（下記「Mac14,9 の所見」）。
      対応済み（パッケージ側）: Apple Silicon 向けに `TB1T`/`TB2T`（「Battery 1/2」）、`TaLP`/`TaRF`（「Airflow Left/Right」）、`TH0x`（「NAND (SSD)」）、`Ts1P`（「Palm Rest 2」）を追加。
      `Ts` 接頭辞（「Skin/Palm Rest」）は `Ts0C` などが 45〜55 °C で掌置き温度に見えないため廃止し、`Ts0P`/`Ts1P` だけ完全一致で命名。
      根拠のないキー（`TCMb`/`TCMz`/`TCDX`、`TVM*`、`TPD*`/`TRD*`、`Th0*`、`TD*`、`Tf*`、`TG*` ほか）は「Sensor XXXX」のまま。259 キーで名前が一意なことをテストで確認。
      各名前の出典（コミュニティ／Mac14,9 で値が整合）は `SensorCatalog.swift` のコメント。DynamicNotch 上での見え方は組込後に確認。
- [x] `Tp*` のちらつき対策: `TemperatureSampleFilter`（`FanControlCore`）を `FanControlManager` のポーリング経路に入れた。
      `Tp/Te/Tg/TC` の 10 °C 未満の値は直前の採用値（連続 5 回まで）→ 同接頭辞グループのその回の最大値 → 生値の順に置き換える（kit.md「Temperature sample filter」）。
      Mac14,9 のパターン（`0.00 / 6.70 / 8.43` など）はテストで再現済み。UI 上の表示とセンサー連動モードでの効き方は組込後に確認。
- [x] 集約センサー（`SensorAggregator`、kit.md「Aggregate sensors」）: フィルタ後の値から `agg:cpu`「CPU (max)」（`Tp/Te/TC`）、
      `agg:cpu.p`「CPU Performance Cores (max)」、`agg:cpu.e`「CPU Efficiency Cores (max)」、`agg:gpu`「GPU (max)」（Apple Silicon は `Tg`、Intel は `Tg/TG`）を
      `sensorReadings` の末尾に追加。`fanfi-probe` の各読取の後に「Aggregates」として表示される（2026-10-20、Mac14,9 で 4 つとも出ることを確認）。
      `.sensor(sensorKey: "agg:cpu", …)` が `plan` でそのまま解決されることはテストで確認。UI 上の表示は組込後に確認。
- [x] 緊急判定の接頭辞: Apple Silicon では `TG` を除外（`SafetyPolicy.default(appleSilicon:)`、`FanControlPlatform.isAppleSilicon`）。Intel は従来どおり `TG` を含む。
- [x] 以下の UI 項目は 2026-10-20 にDynamicNotch（`DynamicNotchApp/`）へ組み込んで一部実施（下記「DynamicNotch UI」）。

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
  - 2026-10-20 の再読取（アイドル、`fanfi-probe` 3 回）: `Tf06`/`Tf16`/`Tf26` = 105.31 / 93.08 / 88.81（セッション内では一定だが前日の 94.50 / 79.42 / 79.42 から変化）、
    `Tf02/12/22`・`Tf00/10/20`・`Tf01/11/21`・`Tf05/15/25` は前日とほぼ同じ一定値、`Tf04`/`Tf08`〜`Tf2E` は 50〜60 °C で変動（温度らしいが意味不明）。
    `Ta0V` は 0.00（前日の probe 出力では 52.97）、`Ta0W` は 9.50（前日 62.47）。
  - → これらは「ランキング除外キー」として `SensorCatalog.isExcludedFromRanking(_:)` に登録（`Tf` 接頭辞すべて＋上記の一定値キー。`Ta0W` は妥当な値を読むことがあるので除外しない）。
    検出・センサー タブでの表示は従来どおりで、「最も高温」の自動選択・`SensorAggregator.overview`・最高温センサーのフォールバック・温度ソートの上位から外す（kit.md）。
  - `Tp*`（P コア）は 3 つ組ごとに 50〜75 °C の実測値と `0.00 / 6.70 / 8.43`（または `0.00 / 4.63 / 5.32`、`0.00 / 6.03 / 7.43`）の固定パターンを読取ごとに行き来する。
    アイドル時の `--watch 1`（6 回）では片方のクラスタ（`Tp0*`、`Tp16`〜`Tp18`）がずっと固定パターンのままで、もう片方（`Tp1A` 以降）は実測値だった（クラスタの電源断と推測）。
    最大値（緊急判定）には影響しないが、センサー連動モードで単一の `Tp*` キーを選ぶと 0 °C 付近を読むことがある → `TemperatureSampleFilter` で対策（上記）。
  - `TCMz` は同時刻の `Tp*` 実測値の最大値と一致し（例 66.36 = `Tp1C`）、固定パターンの影響を受けなかった。`TCMb` も `Tp*` の値の一つと一致する。
    センサー連動モードで CPU 温度を使うなら単一の `Tp*` より `TCMz` が適している可能性がある（1 機種・短時間の観察のみ。名前は付けていない）。
  - `TG*`（`ioft`、33 °C 前後、`TB0T` とほぼ同値）は Intel では GPU 用接頭辞として `emergencySensorPrefixes` に入っているが、この機種では GPU の値に見えない（GPU は `Tg*`）→ Apple Silicon の既定から除外済み（上記）。
- 名前が付かないが関連が深そうなキー（値の推移からの推測を含むため要確認）: `TCMb`/`TCMz`/`TCDX`（CPU 系 55〜75 °C）、`TPD*`・`TRD*`（44 °C / 48 °C 前後の群）、
  `Th0*`（48 °C 前後）、`TVM0`/`TVm0`/`TVm1`（60〜67 °C）、`TD*`（29〜34 °C、`TDBP` 等）、`TB1T`/`TB2T` は「Battery 1T/2T」と表示されていた（`TB0T` と同値。「Battery 1/2」に変更済み）。
  `TH0a`/`TH0b`/`TH0x`（「Storage」、38 °C 前後）は SSD と思われるが未確認。

**DynamicNotch UI（2026-10-20、`DynamicNotchApp/`、Xcode 26.6 アドホック Debug、Mac14,9 / macOS 26.5.2）**

前提と方法: DynamicNotch のプロジェクト `DynamicNotchApp/` に §1〜§5 を適用して確認した
（`DynamicNotchApp/README.md`「FanControl 統合」）。シェルに画面収録・アクセシビリティ権限が無いため、DEBUG ビルドのフック
（`DynamicNotchApp/Sources/Support/DebugHooks.swift`）でアプリ内からウィンドウを PNG 化し、実ウィンドウに `NSEvent` のクリックを合成して
操作した（トグル・タブ・ラジオは本物の UI をクリック）。証跡: `DynamicNotchApp/.derivedData/shots/fc1/`（英語）、`fc-ja/`（日本語、`-AppleLanguages (ja)`）。
ヘルパーには一度も接続していない（ヘルパーログの `Accepted connection` は同時に動いていた HelperSmokeApp の pid のみ）。書込・登録・適用ボタンは押していない。
**注意**: 確認中、別プロセス（HelperSmokeApp、`.derivedData-next`）が書込セッションを持ちファンを手動で回していた（`fanfi-probe` で
`F0Md`=`F1Md`=1、`Tg`=6800）。ウィジェットの 6,7xx RPM はそのため。このアプリは同じバンドル ID なので UserDefaults を共有し、
スモークアプリのプロファイル「Custom」がアクティブとして表示された。

- [x] 設定 ▸ Fan Control ▸ 一般で「ファン制御を有効にする」を ON（チェックボックスをクリック、`fanControlGeneralSettings.isEnabled` = true）→ センサー タブに温度が並ぶ
      （キー/名前/温度、温度の降順）。ヘルパー状態は「手動インストール済み（個人利用モード）」「未接続」と表示（状態取得のみ）。（`fc1/enabled/`, `fc1/sensors/`）
- [x] Nook にウィジェット（`nookSettings.widgets` に `fanControl`）→ 「Fans」見出し、Fan 1 / Fan 2 と現在 RPM、RPM バー、温度、プロファイルメニュー（「Custom」）が表示され、
      約 2 秒の更新間隔で値が変わった（6,730 → 6,858 RPM）。**2x1 では温度が 2 件しか入らない**（ダブルワイドでは 3 件）。（`fc1/widget/`, `fc1/widget2/`）
      機能 OFF の間は「Fan control disabled」と表示（`fc1/open-disabled/`）。
- [x] 集約センサー: センサー タブの先頭に `agg:cpu`「CPU (max)」/`agg:cpu.p`/`agg:cpu.e`/`agg:gpu` が Σ 付きで並ぶ（温度ソートでも先頭）。
      `agg:cpu` = 75 °C が同時刻の `Tp*` の最大値（`Tp1K` 75 °C）と一致、`TCMz` とも一致。`Tp*` が 0 °C 付近を読む瞬間と `TG*` の除外は画面では確認していない。
- [ ] ウィジェットの温度（「最も高温の 3 センサーを表示」ON、既定）: **CPU/GPU 集約ではなく `Tf06` 105 °C / `Tf16` 93 °C / `Tf26` 89 °C が出た**。
      `Tf0x/1x/2x` は §6 の所見で「一定値、閾値等の可能性」とした群（2026-10-19 の probe では `Tf06` 94.50）で、温度ではない可能性が高い。
      これが常に最上位を占めるので、集約の二重表示防止は確認できない。赤表示も未確認（集約が 90 °C 未満だった）。
      **修正済み・アプリでの再確認待ち（2026-10-20）**: `Tf*` と一定値キーを `SensorCatalog.isExcludedFromRanking(_:)` で「最も高温」の候補から除外
      （ウィジェットは `SensorAggregator.hottestOverview` を使用）。Mac14,9 相当の読取値で `agg:cpu`/`agg:gpu` が選ばれ `Tf06` が選ばれないことをテストで確認
      （`SensorRankingTests`）。センサー タブでは除外キーも表示したまま、温度ソート時は実センサーの後ろに並べ、キー列に「?」マークとツールチップ
      （「一定値または不安定な値で、温度ではない可能性があります…」）を付け、温度を淡色表示する。DynamicNotchAppでウィジェットとセンサー タブを再確認すること。
      別件（未修正）: 2x1 ウィジェットは温度を 2 件しか出さない（`FanControlWidgetView` の `prefix(isCompact ? 2 : 4)`。ダブルワイドは 3 件）。
- [ ] プロファイル タブのセンサー連動ピッカー: 未確認（プロファイル編集を避けた）。
- [x] 2x1 / ダブルワイド切替（設定 ▸ Nook ▸ Widgets ▸ fanControl のラジオをクリック、`gridSize` 2 → 5）で幅が 100 pt → 250 pt になり、ダブルワイドは
      「Fans」「Temperatures」の 2 列表示。（`fc1/widgets-fc/`, `fc1/widget-wide/`）°C/°F 切替は未確認。
- [ ] ファンレス機 / SMC 不可環境: 該当機なし。
- [ ] Nook を閉じるとポーリングが止まる: 未計測。
- [ ] 「SMC ダンプを書き出す…」: 未実施（保存パネル操作が必要）。
- [x] 日本語: `ja.lproj`（生成物、`DynamicNotchApp/Support/merge-strings.py`）で「ファン制御」ペイン、「一般 / プロファイル / センサー」、「CPU（最大）」等の集約名、
      ウィジェットの「ファン」「温度」が日本語になる（`fc-ja/`）。プロファイル名「Custom」はユーザー作成名なので英語のまま。
- DynamicNotchApp の制約: Live Activity をノッチ左右に出す経路（`LiveActivityView`）がDynamicNotchApp では使われていないため、PATCHES.md (f) の `fanAlert` 表示は確認できない。

### Phase 2/3: ヘルパー登録
- [ ] 一般タブのヘルパー状態が「未インストール」→「ヘルパーをインストール…」→「承認待ち」になり、案内文と「ログイン項目を開く」が表示される。
- [ ] システム設定 ▸ 一般 ▸ ログイン項目と機能拡張（macOS 15）/ ログイン項目（macOS 14）で DynamicNotch を許可 →「再確認」で「インストール済み」。
- [ ] `.notFound`（plist 配置ミス）では「アプリバンドル内に見つかりません」と案内のみ表示され、インストールボタンは出ない。
- [ ] `sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi` でサービスが見える。
- [ ] `log stream --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'` に接続ログ。

**手動インストール（個人利用モード、helper.md §6）の場合**（上の SMAppService の項目の代わり。書込はしない）:
- [ ] `./install.sh --dry-run <App.app>` が署名検証・アプリ／ヘルパーの cdhash・生成 plist（`Program`、`FANCONTROL_CLIENT_REQUIREMENT`）を表示し、何も変更しない。
- [ ] `sudo ./install.sh <App.app>` が完了し、`./status.sh <App.app>` で 2 ファイルが root 所有で存在、「the app's cdhash matches the pinned requirement」。
- [ ] 一般タブのヘルパー状態が「手動インストール済み（個人利用モード）」になり、`install.sh` / `uninstall.sh` の案内が出る（インストールボタンは出ない）。
- [ ] 接続（書込なしの `version`。スモークアプリなら「Helper version」）→ `helper protocol 1, build 1.0 (1)`。ログに
      `Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to <cdhash>` と `Accepted connection …`。
- [ ] `sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi` で `path = /Library/LaunchDaemons/…plist`、`program = /Library/PrivilegedHelperTools/…`、
      environment に `FANCONTROL_CLIENT_REQUIREMENT`。AMFI がヘルパーを拒否していないこと（`com.apple.application-identifier` の件、helper.md §6「注意」）。
- [ ] 否定系: アプリを再ビルドして `install.sh` を再実行しないまま接続 → 接続が無効化されエラー（案内文に `install.sh` の再実行）。再実行後は接続できる。
- [ ] 否定系: 別 identifier・別 cdhash のアドホック署名プロセスからの接続は拒否される（`codesign -s - -i com.example.dynamicnotch.DynamicNotch` で署名した別バイナリでも拒否されること）。
- [ ] 後片付け: `sudo ./uninstall.sh` → `launchctl print` でサービスが消え、状態表示が「未インストール」に戻る。

### Phase 4: 書き込み・プロファイル

**初回書込（2026-10-20、HelperSmokeApp + 手動インストールモード、Mac14,9）**: Fan 1 を固定 3000 RPM にして戻すまでを実施し成功。`F0Md`=1 → `F0Tg`=3000 で current が約 3 秒で 3000 に追随、`F0Md`=0 だけで target が SMC の値に即座に戻り current も数秒で収束した。記録: [`verification/first-write-2026-10-20.md`](verification/first-write-2026-10-20.md)。以下のチェックリストはこの結果を反映している。

- [x] （HelperSmokeApp）固定 3000 RPM の書込で `F0Md`=1、`F0Tg`=3000、`F0Ac` が追随する。Fan 2 は影響なし。
- [x] （HelperSmokeApp）「自動制御に戻す」で `F0Md`=0 → SMC 制御に戻る（`Tg` の書き戻し不要）。セッション無しで押しても何も書かない。
> **最初の書込の前に** `docs/verification/pre-write-review-2026-10-20.md` の「初回書込の手順」に従う
> （別ターミナルで `swift run fanfi-probe --watch 1` を流し、逃げ道 `F<n>Md` = 0 を先に確認する）。
- [ ] 最初は「固定 3000 RPM」程度の 1 ファン（`F0`）だけで、`F0Md`=1 → `F0Tg`=3000 の順に書かれ、`F0Ac` が数秒で目標付近に追従すること。
      `F0Md` が 1 のまま `F0Tg` が 0 に留まる／`F0Ac` が 0 のまま、なら即「自動制御に戻す」。
- [ ] 「自動制御に戻す」→ `F0Md`=0、`F0Ac` が SMC 制御（アイドルなら数十秒で 0 RPM）に戻ること。ヘルパーは `F0Tg` を記録値（0）に書き戻さない（helper.md §4）。
- [ ] `Mn` 未満の目標値（`enforceHardwareMinimum = false` で 1000 RPM 等）を適用 → `rpmOutOfRange` エラーで**何も書かれない**こと（`F0Md` が 0 のまま）。
- [ ] プロファイル タブで「最大」を適用 → 接続状態が「接続済み（ファンを制御中）」、ファンが最大回転へ。
      Apple Silicon では `F0Md`=1 → `F0Tg` 書込、Intel では `FS! ` ビット → `F0Tg` 書込で回転数が変わること（`F0Ac` を確認）。
- [ ] 新規プロファイルで「固定」スライダ / 「センサー連動」（センサー・開始/最大温度）を設定して保存 → 適用 → 期待通りの回転数。（2026-10-20 HelperSmokeApp: `agg:cpu` 45→75 °C を全ファンに適用 → 75 °C 超で 6800、74.35 °C で 6702 と線形カーブどおり。UI 経由は未実施。`verification/first-write-2026-10-20.md`）
- [ ] 組み込みプロファイルは編集・削除できず、複製はできる。
- [ ] アプリ再起動後も保存したプロファイルとアクティブ選択が残る。
- [ ] 「自動制御に戻す」でファンが SMC 制御に戻る。機能を OFF にしても戻る。アプリ終了時（⌘Q）も戻る。
- [x] 手動制御中に `kill -9` → ヘルパーがセッションを解放しファンが自動に戻る（helper.md §5）。（2026-10-20 HelperSmokeApp: 約 2 秒で automatic に復帰。`verification/first-write-2026-10-20.md`）
- [x] 手動制御中にヘルパーへ `sudo launchctl kill SIGTERM system/<label>` → ヘルパーが復元して終了コード 0、ファンは automatic（2026-10-20、同上）。
- [ ] ウィジェットのプロファイルメニューから切替できる。
- [ ] 機能 OFF の間はプロファイル タブの「適用」が無効で、説明文が表示される。
- [ ] 監視停止中に手動プロファイルを適用すると監視が自動で開始される。
- [ ] 適用直後にポーリングが走っても、旧プロファイルの目標値に書き戻されない（`log stream` のヘルパー書込ログで確認）。
- [ ] ヘルパーを `sudo kill -STOP` で停止させて書込 → 約 8 秒で「timeout」エラーになり、以後の操作が詰まらない（確認後 `kill -CONT`）。
      `kill -CONT` 後、旧接続の解放でヘルパーが復元し `F<n>Md`=0 になること。
- [ ] 手動制御中にヘルパーを `sudo kill -9`（SIGKILL。復元は走らない）→ `fanfi-probe` で `F<n>Md`=1 のまま残ることを確認し、
      「自動制御に戻す」で（セッションが無くても）`F<n>Md`=0 に戻ること（`restoreDefaultControl` の孤立手動状態の回収）。

### Phase 5: 高度機能
- [ ] 負荷をかけて CPU/GPU センサーが 90°C（`SafetyPolicy.highTemperatureAlert`）以上 → ウィジェットが赤表示、Live Activity「高温」とノッチの一時展開。85°C 以下で解除。
- [x] 書込セッション中、95°C（`emergencyTemperature`）以上で全ファン最大に強制される（自動プロファイルでも）。（2026-10-20 HelperSmokeApp: 閾値を 55 °C に下げて検証。automatic だった Fan 2 も 6800 に強制され、既定閾値に戻すと即座にプロファイル目標へ復帰。`verification/first-write-2026-10-20.md`）
      90°C（95 − `alertHysteresis`）以下に下がるまで解除されない（`FanControlManager.emergencyOverrideActive`）。
- [ ] ファン停止（目標 > 0 で実測 0 が 3 回連続）→ 該当ファン行に警告アイコン、Live Activity「ファン停止」（テストは固定モードで物理的に止める等、注意して行う）。
- [ ] 警告トグルを OFF にすると Live Activity が出ない。
- [x] 手動プロファイル適用中にスリープ → 復帰後約 5 秒で再適用される（2026-10-20 HelperSmokeApp で確認。**ただし復帰直後は SMC が `Tg` を 0 にリセットし `Md`=1 のままなので数秒間ファンが停止する**。`verification/first-write-2026-10-20.md` テスト 4、要対応）（「スリープ解除後にプロファイルを再適用」ON 時。
      OFF にすると再適用せず、復帰約 5 秒後に書込セッションを閉じる（ヘルパーがセッション前の値に戻す）。
      設定は `FanControlAlertCoordinator` が `FanControlManager.reapplyProfileAfterWake` に同期）。
- [ ] 書込セッション無しで Nook を閉じても、警告が 1 つでも ON なら低頻度ポーリング（`max(5×間隔, 10 秒)`）が続き警告が出る。両方 OFF なら停止する。
- [ ] バッテリー駆動で更新間隔 10 秒・Nook 非表示時停止の効果を確認。

## 7. この Linux 環境で検証できなかったこと

- **SwiftUI / Defaults / Settings を使う UI コードの型検査は Mac で実施済み（2026-10-19）**。作業用パッケージ
  `Tools/IntegrationTypeCheck`（`README.md` 参照）で、`DynamicNotchIntegration/*.swift` の 8 ファイルを実 macOS 26 SDK
  （SwiftUI / AppKit）、実 `FanControlCore` / `FanControlKit`、**Defaults 8.2.0** と **Settings 3.1.2**（いずれも当時の最新安定版）に対して
  コンパイルし、Swift 5 言語モード・Swift 6 言語モード（`TYPECHECK_SWIFT6=1`）とも警告・エラー 0。8 ファイルは DynamicNotch 側の
  シンボルを参照しないためスタブ無しで通る。PATCHES.md (a)〜(f) の断片も、ホストアプリに倣ったスタブ
  （`NookWidget` / `NookGridSizeType` / `Preferences` / `WidgetPrefs` / `LiveActivity` / `ActiveLiveActivitiesManager` など）に対して型検査した。
  見つかった問題と修正:
  - PATCHES.md (d): `extension Settings.PaneIdentifier` が SwiftUI の `Settings` と曖昧、`Settings.Pane(…)` が SwiftUI 側に誤解決
    → `import enum Settings.Settings` を追加（§5）。ドロップインの 2 ファイルにも予防的に同じ import を追加（変更前もコンパイルは通っていた）。
  - PATCHES.md (d): グローバル `let FanControlSettingsPaneController: () -> SettingsPane = { … }` は Swift 6 モードで
    非 Sendable のグローバル変数・main actor 隔離の初期値としてエラー → `@MainActor func FanControlSettingsPaneController() -> SettingsPane` に変更。
    Swift 6 モードでは `PaneIdentifier` が非 Sendable のため `@preconcurrency import Settings` も必要。
  - ドロップイン 8 ファイル本体の型エラーは無かった。
  `FanControlKit` の macOS 依存部は実 SDK でビルド済み（README「検証状況」）。
- UI が参照する Kit/Core の API（メンバー名、引数ラベル、`async`/`throws`、読み取り専用か否か、static か否か、
  `HelperInstallStatus` / `HelperConnectionState` の case）は実装と突き合わせ済み。`FanControlManager` は `@MainActor` ではない
  （`@unchecked Sendable`、状態はメインスレッドで更新）。UI はメインスレッドから呼び、async メソッドは `Task { @MainActor in … }` で待つ。
- `Settings.Section(label:content:)` / `Settings.Container(contentWidth:)` / `Settings.Pane(identifier:title:toolbarIcon:)` /
  `Settings.PaneHostingController(pane:)` は Settings 3.1.2 の実 API で型検査済み。DynamicNotch が古い Settings（2.x）を
  固定していれば差異がありうるので、実プロジェクトの Package.resolved を確認する（参照ソースでは `Section { … }`）。
- `WidgetPrefs` / `Preferences` の実際の要件はスタブでの推定（`gridSizeType` のみ）。実プロジェクトで追加要件があれば
  PATCHES.md (a) の `extension FanControlWidgetSettings: Preferences, WidgetPrefs` に足す。
- `NookWidget` の View 振り分け箇所、`ActiveLiveActivitiesManager` インスタンスの保持場所はホスト側のソースから特定できていない（PATCHES.md 参照）。
- SMC 読取はパッケージ単体で Mac14,9 / macOS 26 にて確認済み（§6 Phase 1）。SMC 書込、ヘルパー登録、署名要件は未検証。

## 8. 未決事項（設計書 §5 より）

- **Team ID**（§5.1）: `Helper-Info.plist` と `teamIdentifierPlaceholder` の実値。出荷前に必須。
- **Mach サービス名**（§5.2）: `com.example.dynamicnotch.DynamicNotch.fanfi` で既存 FanFi と非競合。両方が同時に SMC を書くと互いに上書きし合うため、併用時の注意をユーザーに示すかは要判断。
- **新しい Apple Silicon の `Ftst` キー**（§5.7, helper.md §4）: 一部機種では `F<n>Md` だけでは目標値が効かず `Ftst` アンロックが必要との報告がある。現状ヘルパーの書込許可リスト外（2026-10-20 のレビューで `F<n>Mn` も許可リストから外した）。Phase 4 で実機確認後に追加を判断。
  Mac14,9（M2 Pro）/ macOS 26 には `Ftst` キー自体が存在しない（読取で keyNotFound、§6 Phase 1）。この機種では許可リストに足しても書けない。
- **温度閾値**（§5.6）: 警告 90°C（ヒステリシス 5°C）、強制最大 95°C は暫定値。機種別に妥当性を確認し、設定 UI に出すか決める（現状 UI には出していない）。
  対象センサー接頭辞は実装済み: Apple Silicon は `Tp/Te/TC/Tg`、Intel は `Tp/Te/TC/Tg/TG`（`SafetyPolicy.default(appleSilicon:)`。Mac14,9 では `TG*` は GPU ではなく 33 °C 前後の `ioft` キー）。
  判定は `sysctl hw.optional.arm64`（Rosetta 下でも Apple Silicon と判定）。`Tf06` は 94.5〜105 °C の一定値だが接頭辞外（§6 Phase 1 の所見参照。ランキング除外キーは緊急判定の接頭辞に一致しないことをテストで確認）。
  要確認: 他の Apple Silicon 機種でも `TG*` が GPU でないか、`TC*`（`TCMz` 等）を対象に含めたままでよいか。
  センサー値フィルタ（`TemperatureSampleFilter`、下限 10 °C・保持 5 回・グループ最大値へのフォールバック）も暫定値。急な下降は棄却しない方針（kit.md）。
  センサー連動の CPU センサー → 集約センサーで対応: `agg:cpu`（`Tp/Te/TC` の最大値）などを仮想センサーとして提供し、センサー連動の既定センサーを `agg:cpu` にした（kit.md「Aggregate sensors」）。
  残る判断: `agg:cpu` に `TC*` を含めるか（Mac14,9 の `TCMz` は `Tp*` 最大値と一致し無害だが、他機種の `TC*` の意味は未確認）、最大値以外（平均など）の集約が必要か。
- **センサー名**（§5.7）: `SensorCatalog` の名称はコミュニティ情報で英語固定。Apple Silicon 向けに一部追加済み（§6 Phase 1）。
  未決: `TCMz`/`TCMb`/`TCDX`、`TVM*`、`TPD*`/`TRD*`、`Th0*`、`TD*`、`Tf*` などの名称（根拠が見つからず「Sensor XXXX」のまま）、他機種での検証、`Tp*` の P/E コア区別（コミュニティ間で不一致）、ローカライズ方針。
  非温度／不安定キー: `SensorCatalog.rankingExcludedPrefixes`（`Tf`、全機種）と `rankingExcludedKeys`（Mac14,9 で一定値の `TH1a`/`TH1b`/`TVMD`/`Ta0C/D/G/H/K/L/V`/`Tz11`〜`Tz18`/`Tz1j`）を
  自動選択・ランキングから除外（表示・明示選択は可）。`Tf*` の意味は不明で、除外は Mac14,9 の観察のみに基づく（`Tf04` 等は温度らしく変動するが一括除外）。
  他機種で除外キーが実温度だった場合や、別の一定値キーが上位に来る場合は表を見直す。
- **ポーリング間隔**（§5.4）: 1/2/5/10 秒の選択式。電源状態による自動切替は未実装。
- **制御開始タイミング**（§5.5）: 既定は機能 OFF。ON かつ「起動時に監視を開始」で起動時に監視（読み取り）を開始、OFF の場合はウィジェット初表示時に開始。ファン書き込みはユーザーがプロファイルを適用したときのみ。
- **ライセンス**（§5.8）: 法務確認。
