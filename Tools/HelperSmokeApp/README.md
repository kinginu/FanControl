# HelperSmokeApp

`docs/integration.md` §1〜§4 / `docs/helper.md` §1〜§2 のヘルパー埋め込みレシピを、DynamicNotch 本体に入れる前に確かめるための最小アプリ
（XcodeGen）。2026-10-20 の検証結果は [`../../docs/verification/helper-bundle-smoke-2026-10-20.md`](../../docs/verification/helper-bundle-smoke-2026-10-20.md)。

| ターゲット | 種類 | 内容 |
|---|---|---|
| `FanControlSmoke` | macOS アプリ（`LSUIElement`、メニューバー） | ローカルパッケージ `../..` の `FanControlCore` / `FanControlKit` をリンク。ウィンドウに `HelperInstaller.status()`（手動インストール時は `installedManually`）、ヘルパー要件のモード（Team ID / manual (cdhash)、アプリの Team ID、固定するヘルパー cdhash）と `FanControlManager` のファン・センサー値（読取のみ）を表示。ボタン（この順）: 「Helper version」（XPC の `version` のみ、書込なし）、「Install helper」（`SMAppService.register`。手動インストール時は何もしない）、「Fan 1 → 3000 RPM…」（確認ダイアログの後に SMC 書込）、「Apply sensor-linked (agg:cpu 45→75 °C)…」、「Emergency test: set threshold to 55 °C…」/「restore default thresholds」（メモリ上の `safetyPolicy` のみ変更）、「Apply first profile」（Automatic）/「Restore automatic」。毎秒更新のライブ状態（ファンごとの current/target/mode、セッション・接続、`agg:cpu`、緊急/警告フラグ、`lastError`）も表示。実 API につながっている |
| `FanControlHelper` | Command Line Tool | `../../Sources/FanControlHelper/*.swift` を直接コンパイルし、`FanControlCore` / `FanControlSMC` / `FanControlXPC` をリンク。`-sectcreate` で `../../Support/Helper-Info.plist` を埋め込む |

アプリは Copy Files でヘルパーを `Contents/MacOS/`、`../../Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist` を
`Contents/Library/LaunchDaemons/` に入れる。bundle ID は DynamicNotch と同じ `com.example.dynamicnotch.DynamicNotch`
（`FanControlHelperConstants.appBundleIdentifier` と launchd plist の `AssociatedBundleIdentifiers` に合わせるため）。
macOS 14.0 以上、Swift 5 言語モード、App Sandbox なし、Hardened Runtime あり。

## 生成とビルド

Xcode 26.6 が `xcode-select` されていない環境では `DEVELOPER_DIR` を指定する。

```sh
cd FanControl/Tools/HelperSmokeApp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

成果物は `.derivedData/Build/Products/Debug/FanControlSmoke.app`。確認:

```sh
APP=.derivedData/Build/Products/Debug/FanControlSmoke.app
find "$APP" -not -path '*/_CodeSignature/*'
launchctl plist __TEXT,__info_plist "$APP/Contents/MacOS/FanControlHelper"
plutil -p "$APP/Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist"
codesign -d --entitlements - -vv "$APP" "$APP/Contents/MacOS/FanControlHelper"
codesign --verify --deep --strict -v "$APP"
```

既定はアドホック署名。Xcode はアドホック署名では Hardened Runtime を付けないため、`project.yml` で
`OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime` を指定している（実 ID の署名でも無害）。
生成物（`*.xcodeproj`、`.derivedData/`、`.build/`）は `.gitignore` 済み。

`ENABLE_DEBUG_DYLIB = NO` も指定している。既定の Debug ビルドはアプリをスタブ + `FanControlSmoke.debug.dylib`（SwiftUI プレビュー用）に分けるが、
アドホック署名 + Hardened Runtime ではライブラリ検証がこの dylib を拒否し（`mapping process and mapped file (non-platform) have different Team IDs`）、
アプリが起動しなかった（2026-10-20 確認。NO にした後は起動する）。

## Team ID が決まったら

1. 署名: `project.yml` の `settings.base` で `DEVELOPMENT_TEAM: <TeamID>`、`CODE_SIGN_IDENTITY: "Apple Development"`（配布確認なら
   `"Developer ID Application"`）にして `xcodegen generate`、またはコマンドラインで上書きする:
   ```sh
   xcodebuild ... build DEVELOPMENT_TEAM=<TeamID> CODE_SIGN_IDENTITY="Apple Development"
   ```
2. Team ID の置換（本体と共通の 2 か所）:
   - `FanControl/Support/Helper-Info.plist` の `FanControlClientTeamID`（`TEAMID0000`）
   - `FanControl/Sources/FanControlXPC/FanControlHelperConstants.swift` の `teamIdentifierPlaceholder`（`TEAMID0000`）
3. 再ビルド後に確認: `codesign -dvvv` で両方の `TeamIdentifier` が同じ Team ID、flags に `runtime`。
   `launchctl plist __TEXT,__info_plist …/FanControlHelper` の `FanControlClientTeamID` が実 Team ID。
   ヘルパーの entitlements に `com.apple.application-identifier` が残っていないか（残る場合、プロファイル無しの Developer ID 署名では
   launchd 起動時に拒否される恐れ。検証記録「署名」参照）。

## 登録テスト（integration.md §6 Phase 2/3。未実施・手順のみ）

**書込はしない。** Phase 2/3 はヘルパーの登録と接続までで、ファン書込（Phase 4）は `docs/verification/pre-write-review-2026-10-20.md`
の手順に従って別途行う。ウィンドウの「Apply first profile」は押さない。

1. Team ID 付きでビルドした `FanControlSmoke.app` を `/Applications` にコピーして起動（`SMAppService` はバンドルの場所を見るため、
   DerivedData からではなく固定の場所から起動する）。メニューバーの扇アイコン ▸ Show Window。
2. 表示: `HelperInstaller.status()` が `notRegistered`。plist の配置・名前が誤っていれば `notFound`。
3. 「Install helper」→ `requiresApproval` になり、システム設定 ▸ 一般 ▸ ログイン項目と機能拡張（macOS 15+）/ ログイン項目（macOS 14）が開く。
   アプリ名で表示される項目を許可 →「Refresh status」で `enabled`。
4. 端末で確認:
   ```sh
   sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi
   log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
   ```
5. 接続確認は書込を伴わない「Helper version」（`HelperClient.version()`）で行う → `helper protocol 1, build 1.0 (1)`。
   署名要件を満たさない場合（Team ID 不一致・アドホック署名）は接続が無効化されエラーになる。
6. 後片付け: アプリから `HelperInstaller().unregister()`（UI には無い）、またはシステム設定で項目をオフにしてアプリを削除。
   `launchctl print` でサービスが消えたことを確認する。DynamicNotch 本体と bundle ID・Mach サービス名が同じなので、本体の検証前に必ず登録を解除する。

## 手動インストールモードでのテスト（個人利用、Team ID なし。docs/helper.md §6）

アドホック署名のままヘルパーを LaunchDaemon として手動で入れ、XPC 接続（Phase 2/3 相当）→ 初回書込（Phase 4）まで確かめる手順。
**root が必要な操作と SMC 書込はユーザー自身が、各ステップを確認しながら実行する。** スモークアプリと DynamicNotch 本体は bundle ID・Mach サービス名が同じなので、
本体を入れる前に `sudo uninstall.sh` で必ず外す。SMAppService 方式で登録済みなら先に登録を解除する（`install.sh` は検出すると中止する）。

1. **ビルド**（上記「生成とビルド」と同じ。アドホック署名）:
   ```sh
   cd FanControl/Tools/HelperSmokeApp
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodegen generate
   xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
     -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
   APP="$PWD/.derivedData/Build/Products/Debug/FanControlSmoke.app"
   ```
   アプリを別の場所（`/Applications` など）にコピーして使う場合は、コピー後のパスを `install.sh` に渡す（cdhash はコピーしても変わらないが、確認対象を一致させるため）。
2. **予行**（root 不要・何も変更しない）:
   ```sh
   ../../Support/manual-install/install.sh --dry-run "$APP"
   ```
   アプリ／ヘルパーの identifier・cdhash、生成される plist（`Program` = `/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi`、
   `FANCONTROL_CLIENT_REQUIREMENT` = `identifier "com.example.dynamicnotch.DynamicNotch" and cdhash H"<アプリの cdhash>"`）と実行予定のコマンドを確認する。
   `com.apple.application-identifier` の警告は想定どおり（helper.md §6「注意」）。
3. **インストール**（ユーザーが実行）:
   ```sh
   sudo ../../Support/manual-install/install.sh "$APP"
   ../../Support/manual-install/status.sh "$APP"     # root 不要。"the app's cdhash matches the pinned requirement"
   ```
4. **監視を用意**（別ターミナル）:
   ```sh
   log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
   ```
5. **起動**: `open "$APP"` → メニューバーの扇アイコン ▸ Show Window。表示を確認:
   - `HelperInstaller.status(): installedManually`
   - `Helper requirement mode: manual (cdhash) · app team none (ad-hoc) · helper cdhash <40 桁>`（`status.sh` の installed helper cdhash と一致）
6. **接続確認（書込なし）**: 「Helper version」→ `helper protocol 1, build 1.0 (1)`。ログに
   `Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to <アプリの cdhash>` と `Accepted connection …`。
   `sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi` で `state = running`、`program = /Library/PrivilegedHelperTools/…`。
   失敗する場合: ヘルパーが起動しない → `log show --last 5m --predicate 'process == "amfid" OR sender == "AppleMobileFileIntegrity"'` と
   `launchctl print` の `last exit code`（78 なら `FANCONTROL_CLIENT_REQUIREMENT` が不正）。接続が無効化される → `status.sh "$APP"` で cdhash の一致を確認し、
   違えば `sudo install.sh "$APP"` を再実行。
7. （任意）**否定系**: アプリを再ビルド（ソースを 1 行変えるなど）して `install.sh` を再実行せずに「Helper version」→ エラー（`install.sh` 再実行の案内付き）。
   再実行後は通る。
8. **初回書込（Phase 4）**: `../../docs/verification/pre-write-review-2026-10-20.md` の「初回書込の手順」に従う。前提の「同じ Team ID で署名し登録・承認」は
   ここでは「手順 3〜6 が済んでいること」に読み替える。**各ステップでユーザーが明示的に確認してから進む**:
   1. 別ターミナルで `cd FanControl && swift run fanfi-probe --watch 1`（`F0Md`=0, `F0Tg`=0, `F0Ac`=0 を記録）と上記ログ。
   2. 逃げ道を先に確認: 「Restore automatic」が押せること、`sudo launchctl kill SIGTERM system/com.example.dynamicnotch.DynamicNotch.fanfi` でヘルパーを止められること。
      最後の手段は再起動。
   3. 「Fan 1 → 3000 RPM…」→ 確認ダイアログで「Write F0Md = 1, F0Tg = 3000」（Fan 1 だけ固定 3000 RPM、Fan 2 は自動）。
      期待: ログに `F0Md` → `F0Tg`、`fanfi-probe` で `F0Md`=1・`F0Tg`=3000・`F0Ac` が数秒で 3000 付近、`F1Md`=0 のまま。
      **中止条件**（`F0Tg` が 0 のまま、`F0Ac` が 10 秒以上 0、ログに `badRequest` / `smcError` など）→ すぐ「Restore automatic」。
   4. 「Restore automatic」→ `F0Md`=0、`F0Ac` がアイドルなら数十秒で 0 へ。ログに `Failed to restore` が無いこと。
   5. 以降（Mn/Mx、2 ファンなど）は integration.md §6 Phase 4 の順に。結果は `docs/verification/` に保存する。
   6. **ヘルパー停止時の復元**（Phase 4）: 「Fan 1 → 3000 RPM…」で固定した状態から、別ターミナルで
      `sudo launchctl kill SIGTERM system/com.example.dynamicnotch.DynamicNotch.fanfi`。
      期待: ヘルパーのログに復元処理、`fanfi-probe --watch 1` で `F0Md`=0（`F0Tg` は元の値）、ファンが自動制御へ戻る。launchd が KeepAlive で再起動する場合は再起動を確認。
      続けて同じ手順で `sudo launchctl kill SIGKILL …`（`kill -9` 相当）を試す。期待: ヘルパーが再起動したとき（または XPC 切断の検出時）に `F0Md`=0 へ戻る。
      戻らない場合は直ちに「Restore automatic」、それでも駄目なら再起動。
   7. **センサー連動**: 「Apply sensor-linked (agg:cpu 45→75 °C)…」→ 確認ダイアログ。全ファンを `.sensor("agg:cpu", 45, 75)` で動かす
      （一時プロファイル "Smoke sensor-linked" を保存。「Restore automatic」で削除）。ウィンドウ上部のライブ表示（毎秒更新）に
      ファンごとの current / target / mode と `agg:cpu` の温度が出る。
      期待: 45 °C 以下では target が min（2317 付近）、75 °C 以上で max（6800）、その間は温度に比例。`fanfi-probe --watch 1` の `F0Tg`/`F1Tg` と
      ライブ表示の target が一致し、`F*Md`=1、`F*Ac` が追従。負荷（`yes > /dev/null` を数本）で target が上がり、止めると下がる。終了は「Restore automatic」→ `F*Md`=0。
   8. **緊急オーバーライド**: 先にセンサー連動か 3000 RPM 固定でセッションを開く。次に「Emergency test: set threshold to 55 °C…」。
      期待: 現在の CPU 温度が 55 °C 超なら数秒内に `emergencyOverrideActive: true` と `highTempAlertActive: true`、全ファンの target が各 `F*Mx`（6800）、
      `fanfi-probe` で `F*Tg`=Mx。ホットセンサー表示は `Tp*`/`Tg*` など。温度が 55 °C 未満なら負荷をかけてから確認。
      「Emergency test: restore default thresholds」→ ヒステリシス後に `emergencyOverrideActive: false`、target がプロファイルどおりに戻る。
      閾値は保存されない（アプリ再起動で既定へ）。終了は「Restore automatic」。
   9. **スリープ／ウェイク**: ファンを固定またはセンサー連動にした状態でスリープ（`pmset sleepnow`）→ 復帰。
      期待: 復帰 5 秒後にプロファイルが再適用され（`reapplyProfileAfterWake` が既定 true）、`fanfi-probe` で `F*Md`=1 と `F*Tg` がライブ表示の target に一致。
      スリープ中に SMC が自動へ戻った場合も再適用で戻る。確認後「Restore automatic」で `F*Md`=0。
9. **後片付け**: アプリを終了 → `sudo ../../Support/manual-install/uninstall.sh` → `status.sh` で 2 ファイルが missing、`launchctl print` でサービスが消えたこと。
