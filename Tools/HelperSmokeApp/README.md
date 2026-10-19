# HelperSmokeApp

`docs/integration.md` §1〜§4 / `docs/helper.md` §1〜§2 のヘルパー埋め込みレシピを、DynamicNotch 本体に入れる前に確かめるための最小アプリ
（XcodeGen）。2026-10-20 の検証結果は [`../../docs/verification/helper-bundle-smoke-2026-10-20.md`](../../docs/verification/helper-bundle-smoke-2026-10-20.md)。

| ターゲット | 種類 | 内容 |
|---|---|---|
| `FanControlSmoke` | macOS アプリ（`LSUIElement`、メニューバー） | ローカルパッケージ `../..` の `FanControlCore` / `FanControlKit` をリンク。ウィンドウに `HelperInstaller.status()` と `FanControlManager` のファン・センサー値（読取のみ）を表示。ボタン: 「Helper version」（XPC の `version` のみ、書込なし）、「Install helper」（`SMAppService.register`）、「Apply first profile」/「Restore automatic」（SMC 書込）。実 API につながっている（**ビルド確認用。今回は押していない**） |
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
