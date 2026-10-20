# ヘルパー埋め込みレシピの最小アプリ検証（2026-10-20）

`docs/integration.md` §1〜§4 と `docs/helper.md` §1〜§2 の Xcode 側手順（Command Line Tool ターゲット + `-sectcreate` +
Copy Files 2 つ）を、DynamicNotch 本体に適用する前に最小アプリ `Tools/HelperSmokeApp`（XcodeGen）で実際に `xcodebuild` して確かめた記録。

**ビルドのみ。** アプリは起動していない。`SMAppService.register()` は呼んでいない。`/Library`・`~/Library/LaunchDaemons` には何も入れていない。SMC 書込なし。

## 環境

- MacBook Pro Mac14,9（Apple M2 Pro）、macOS 26.5（BuildMachineOSBuild 25F84）
- Xcode 26.6（17F113、`DTXcode` 2660）、macOS 26.5 SDK（25F70）。`xcode-select` は CLT のままなので `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を指定
- XcodeGen 2.46.0
- 署名 ID なし（`security find-identity -v -p codesigning` → 0 件）→ アドホック署名（`CODE_SIGN_IDENTITY=-`）

## ビルド

```sh
cd FanControl/Tools/HelperSmokeApp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

結果: `** BUILD SUCCEEDED **`（Debug / Release とも）。コンパイラ警告 0（出たのは `appintentsmetadataprocessor` の
「Metadata extraction skipped. No AppIntents.framework dependency found.」のみ）。
ビルドされたターゲット: プロジェクト `FanControlSmoke` の `FanControlSmoke`（アプリ）と `FanControlHelper`（Command Line Tool、
`Sources/FanControlHelper/*.swift` 6 ファイルを直接コンパイル）、ローカルパッケージ `FanControl` の `FanControlCore` / `FanControlSMC` /
`FanControlXPC` / `FanControlKit`。パッケージの executable product `FanControlHelper` / `fanfi-probe` はビルドされない（参照していないため）。
パッケージのライブラリはすべて静的リンクで、アプリ・ヘルパーとも `Frameworks/` は無い（`otool -L` にパッケージ由来の dylib なし）。

## バンドル配置（Debug）

```
FanControlSmoke.app
FanControlSmoke.app/Contents
FanControlSmoke.app/Contents/_CodeSignature
FanControlSmoke.app/Contents/_CodeSignature/CodeResources
FanControlSmoke.app/Contents/Info.plist
FanControlSmoke.app/Contents/Library
FanControlSmoke.app/Contents/Library/LaunchDaemons
FanControlSmoke.app/Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist
FanControlSmoke.app/Contents/MacOS
FanControlSmoke.app/Contents/MacOS/__preview.dylib
FanControlSmoke.app/Contents/MacOS/FanControlHelper
FanControlSmoke.app/Contents/MacOS/FanControlSmoke
FanControlSmoke.app/Contents/MacOS/FanControlSmoke.debug.dylib
FanControlSmoke.app/Contents/PkgInfo
```

`__preview.dylib` / `FanControlSmoke.debug.dylib` は Debug ビルドの `ENABLE_DEBUG_DYLIB`（SwiftUI プレビュー用）によるもの。
Release ビルドでは `Contents/MacOS/` は `FanControlSmoke` と `FanControlHelper` だけになる:

```
FanControlSmoke.app/Contents/Info.plist
FanControlSmoke.app/Contents/PkgInfo
FanControlSmoke.app/Contents/MacOS/FanControlSmoke
FanControlSmoke.app/Contents/MacOS/FanControlHelper
FanControlSmoke.app/Contents/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist
```

```
Contents/MacOS/__preview.dylib:             Mach-O 64-bit dynamically linked shared library arm64
Contents/MacOS/FanControlHelper:            Mach-O 64-bit executable arm64
Contents/MacOS/FanControlSmoke:             Mach-O 64-bit executable arm64
Contents/MacOS/FanControlSmoke.debug.dylib: Mach-O 64-bit dynamically linked shared library arm64
```

→ integration.md §3 の配置（`Contents/MacOS/FanControlHelper`、`Contents/Library/LaunchDaemons/<plistName>`）どおり。
launchd plist の `BundleProgram` = `Contents/MacOS/FanControlHelper`（バンドルルートからの相対パス）が実ファイルと一致する。

## ヘルパーに埋め込まれた Info.plist

`__info_plist` セクションは arm64 スライスに 1 つだけ（重複なし）:

```
Section
  sectname __info_plist
   segname __TEXT
      addr 0x000000010006501c
      size 0x0000000000000446
```

`launchctl plist __TEXT,__info_plist FanControlSmoke.app/Contents/MacOS/FanControlHelper`:

```
{
	"CFBundleShortVersionString" = "1.0";
	"CFBundleIdentifier" = "com.example.dynamicnotch.DynamicNotch.fanfi";
	"CFBundleName" = "FanControlHelper";
	"FanControlClientTeamID" = "TEAMID0000";
	"CFBundleVersion" = "1";
	"CFBundleInfoDictionaryVersion" = "6.0";
};
```

`segedit <helper> -extract __TEXT __info_plist out.plist && plutil -p out.plist` でも同じ内容（`plutil -lint` OK）。
`otool -X -s __TEXT __info_plist … | xxd -r -p` は **使えない**: arm64 の `otool` は 32 ビットワード単位（リトルエンディアン順）で
16 進表示するため、そのまま逆変換するとバイト順が崩れて plist にならない。確認には `launchctl plist` か `segedit -extract` を使う。

`SMAuthorizedClients` は無い（SMJobBless 方式を使わないため不要。helper.md §3）。クライアント制限は `FanControlClientTeamID` による
`setCodeSigningRequirement` で行う。`FanControlClientTeamID` はプレースホルダ `TEAMID0000` のまま。

## アプリの Info.plist

```
{
  "BuildMachineOSBuild" => "25F84"
  "CFBundleDevelopmentRegion" => "en"
  "CFBundleDisplayName" => "FanControlSmoke"
  "CFBundleExecutable" => "FanControlSmoke"
  "CFBundleIdentifier" => "com.example.dynamicnotch.DynamicNotch"
  "CFBundleInfoDictionaryVersion" => "6.0"
  "CFBundleName" => "FanControlSmoke"
  "CFBundlePackageType" => "APPL"
  "CFBundleSupportedPlatforms" => [
    0 => "MacOSX"
  ]
  "DTCompiler" => "com.apple.compilers.llvm.clang.1_0"
  "DTPlatformBuild" => "25F70"
  "DTPlatformName" => "macosx"
  "DTPlatformVersion" => "26.5"
  "DTSDKBuild" => "25F70"
  "DTSDKName" => "macosx26.5"
  "DTXcode" => "2660"
  "DTXcodeBuild" => "17F113"
  "LSMinimumSystemVersion" => "14.0"
  "LSUIElement" => true
}
```

## LaunchDaemons plist（バンドル内）

```
{
  "AssociatedBundleIdentifiers" => [
    0 => "com.example.dynamicnotch.DynamicNotch"
  ]
  "BundleProgram" => "Contents/MacOS/FanControlHelper"
  "Label" => "com.example.dynamicnotch.DynamicNotch.fanfi"
  "MachServices" => {
    "com.example.dynamicnotch.DynamicNotch.fanfi" => true
  }
  "ProcessType" => "Adaptive"
  "RunAtLoad" => false
}
```

## 署名（アドホック）

```
$ codesign -d --entitlements - -vv FanControlSmoke.app
Executable=.derivedData/Build/Products/Debug/FanControlSmoke.app/Contents/MacOS/FanControlSmoke
Identifier=com.example.dynamicnotch.DynamicNotch
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=454 flags=0x10002(adhoc,runtime) hashes=3+7 location=embedded
Signature=adhoc
Info.plist entries=19
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=4
Internal requirements count=0 size=12
[Dict]
	[Key] com.apple.security.get-task-allow
	[Value]
		[Bool] true

$ codesign -d --entitlements - -vv FanControlSmoke.app/Contents/MacOS/FanControlHelper
Executable=.derivedData/Build/Products/Debug/FanControlSmoke.app/Contents/MacOS/FanControlHelper
Identifier=com.example.dynamicnotch.DynamicNotch.fanfi
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=2348 flags=0x10002(adhoc,runtime) hashes=62+7 location=embedded
Signature=adhoc
Info.plist entries=6
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources=none
Internal requirements count=0 size=12
[Dict]
	[Key] com.apple.application-identifier
	[Value]
		[String] com.example.dynamicnotch.DynamicNotch.fanfi
	[Key] com.apple.security.get-task-allow
	[Value]
		[Bool] true

$ codesign --verify --deep --strict -v FanControlSmoke.app
.derivedData/Build/Products/Debug/FanControlSmoke.app: valid on disk
.derivedData/Build/Products/Debug/FanControlSmoke.app: satisfies its Designated Requirement
```

- 両方 `flags=0x10002(adhoc,runtime)` で Hardened Runtime が付いている。ただし **`ENABLE_HARDENED_RUNTIME = YES` だけでは付かなかった**:
  Xcode 26.6 はアドホック署名（`CODE_SIGN_IDENTITY=-`）のとき `codesign` に `-o runtime` を渡さず、最初のビルドは `flags=0x2(adhoc)` だった。
  `OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime` を足して解決（実 ID での署名では Xcode が自分で `-o runtime` を付ける。
  重複指定は `codesign -o runtime --options=runtime` で問題ないことを確認）。
- ヘルパーは Copy Files（Code Sign On Copy）時に `codesign --force --sign - --preserve-metadata=identifier,entitlements,flags` で再署名され、
  identifier・entitlements・runtime フラグが保たれる。
- 署名 identifier: アプリ `com.example.dynamicnotch.DynamicNotch`、ヘルパー `com.example.dynamicnotch.DynamicNotch.fanfi`
  （ヘルパーは `PRODUCT_BUNDLE_IDENTIFIER` から。Info.plist の `CFBundleIdentifier` とも一致）。
- `TeamIdentifier=not set`（アドホック）。`anchor apple generic … certificate leaf[subject.OU] = …` の要件はアドホック署名では満たせないので、
  XPC 接続の実動作確認は Team ID 付き署名が必要（未実施）。
- **要確認（Team ID 取得後）**: Xcode はヘルパー（Command Line Tool）に `com.apple.application-identifier` を自動で注入した
  （`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` でも消えない）。アプリ側には付かない。`com.apple.security.get-task-allow` は
  アドホック署名では Release でも付いた（実 ID の Release / Archive では付かないはず）。Developer ID 署名でプロビジョニングプロファイル無しに
  `application-identifier` が残ると launchd 起動時に AMFI に拒否される可能性があるため、実署名後に `codesign -d --entitlements -` で確認する。

## 識別子の突き合わせ

| 項目 | 値 | 出所 |
|---|---|---|
| Mach サービス名 | `com.example.dynamicnotch.DynamicNotch.fanfi` | `FanControlHelperConstants.machServiceName`、launchd plist `MachServices`・`Label` |
| plist ファイル名 | `com.example.dynamicnotch.DynamicNotch.fanfi.plist` | `FanControlHelperConstants.plistName`、バンドル内の実ファイル名（修正後） |
| ヘルパー実行ファイル | `FanControlHelper` | `helperExecutableName`、`BundleProgram` 末尾、`Contents/MacOS/` の実ファイル |
| ヘルパー identifier | `com.example.dynamicnotch.DynamicNotch.fanfi` | `helperIdentifier`、`PRODUCT_BUNDLE_IDENTIFIER`、Helper-Info.plist `CFBundleIdentifier`、codesign Identifier |
| アプリ bundle ID | `com.example.dynamicnotch.DynamicNotch` | `appBundleIdentifier`、launchd plist `AssociatedBundleIdentifiers`、アプリ Info.plist `CFBundleIdentifier`、codesign Identifier |
| Team ID | `TEAMID0000`（プレースホルダ） | Helper-Info.plist `FanControlClientTeamID`、`teamIdentifierPlaceholder`（実 Team ID は未定） |

ヘルパー／アプリのバイナリ内の文字列（`strings | grep`）も上表の値だけ（`.poll` は `FanControlManager` のポーリングキュー名）:

```
<string>com.example.dynamicnotch.DynamicNotch.fanfi</string>
<string>TEAMID0000</string>
com.example.dynamicnotch.DynamicNotch
com.example.dynamicnotch.DynamicNotch.fanfi
com.example.dynamicnotch.DynamicNotch.fanfi.plist
TEAMID0000
com.example.dynamicnotch.DynamicNotch
com.example.dynamicnotch.DynamicNotch.fanfi
com.example.dynamicnotch.DynamicNotch.fanfi.plist
com.example.dynamicnotch.DynamicNotch.fanfi.poll
TEAMID0000
```

## 見つかった不一致と対処

1. **launchd plist のファイル名がコードと不一致（修正済み）**: リポジトリの実ファイルは
   `Support/LaunchDaemons/com.dynamicnotch.DynamicNotch.fanfi.plist`（コミット 0759466「Rename project identifiers」で
   `com.example.` が抜けた名前にリネームされていた）だが、`FanControlHelperConstants.plistName`・plist 内の `Label`/`MachServices`・
   integration.md / helper.md はすべて `com.example.dynamicnotch.DynamicNotch.fanfi.plist`。このままだと
   `SMAppService.daemon(plistName:)` がバンドル内に plist を見つけられず `.notFound` になる。
   → ファイルを `com.example.dynamicnotch.DynamicNotch.fanfi.plist` にリネーム（中身は変更なし。git では未ステージ）。
2. **Hardened Runtime がアドホック署名で付かない**（上記「署名」）→ スモークアプリでは `OTHER_CODE_SIGN_FLAGS` で対処。
   本体のレシピでは実 ID 署名が前提なので不要だが、アドホックで確認するときの注意として integration.md §4 に追記。
3. **integration.md §2 の説明の誤り**: 「`GENERATE_INFOPLIST_FILE` / `CREATE_INFOPLIST_SECTION_IN_BINARY` のどちらかが YES だと
   重複してリンクエラー」は Xcode 26.6 では再現しなかった（ヘルパー単体で設定を変えて試した。いずれも arm64 で `__info_plist` は 1 個）:
   - `GENERATE_INFOPLIST_FILE = YES`（`CREATE_… = NO`）: 生成 Info.plist はバイナリに入らず、`-sectcreate` 側だけが入る。影響なし。
   - `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` + `INFOPLIST_FILE = Helper-Info.plist` + 手動 `-sectcreate`: Xcode が
     `Processed-Info.plist` で 2 つ目の `-sectcreate __TEXT __info_plist` を渡すが、リンクエラーも警告も出ずセクションは 1 個。
     どちらが採用されたかは内容が同一のため判別できない。二重指定は避ける（手動 `-sectcreate` 方式に統一、の結論は変わらない）。
   → integration.md §2 の記述を実測に合わせて修正。
4. **確認コマンドの誤り**: integration.md §4 / helper.md §5 の `otool -s __TEXT __info_plist … | head` は 16 進ダンプで中身を確認できない
   → `launchctl plist __TEXT,__info_plist <helper>` に変更。§4 の「`flags=0x10000(runtime)`」はアドホックでは `0x10002(adhoc,runtime)`。
5. Helper-Info.plist 冒頭コメントの「または INFOPLIST_FILE + CREATE_INFOPLIST_SECTION_IN_BINARY = YES」は手動 `-sectcreate` 統一方針と食い違う
   → コメントを統一方針に合わせて修正（キー・値は変更なし）。

識別子（Mach サービス名・bundle ID・identifier）の値そのものの不一致は、上記 1 のファイル名以外には無かった。

## 未検証（Team ID が必要）

- 実 ID（Apple Development / Developer ID）での署名、`TeamIdentifier`、`anchor apple generic` 要件の充足
- ヘルパーの entitlements（`com.apple.application-identifier` 注入）の扱い
- `SMAppService.register()` → 承認 → `launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi`、XPC 接続（integration.md §6 Phase 2/3）

## 追記: 起動確認と手動インストールモード（2026-10-20）

- 上記の Debug ビルド（アドホック + Hardened Runtime）は **起動できなかった**:
  `dyld: Library not loaded: @rpath/FanControlSmoke.debug.dylib … not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`。
  Debug の `ENABLE_DEBUG_DYLIB`（スタブ + `.debug.dylib` 分割）とライブラリ検証の組み合わせで、アドホック署名には Team ID が無いため。
  `project.yml` に `ENABLE_DEBUG_DYLIB: NO` を追加 → `Contents/MacOS/` は `FanControlSmoke` と `FanControlHelper` のみになり、起動することを確認（数秒起動して終了。ボタンは押していない。読取のみ）。
  アドホック署名で DynamicNotch 本体を動かす場合も同じ設定が必要（integration.md §4「代替: 手動インストール」）。
- Team ID が無いため、アドホック署名のまま使う手動インストール（個人利用）モードを追加した（helper.md §6）。
  `Support/manual-install/install.sh --dry-run` をこのビルドに対して実行し、署名検証・identifier・cdhash 取得（`CDHash=` 1 行）・plist 生成・コマンド列が期待どおりであることを確認。
  実インストール（root）・ヘルパー起動・XPC 接続は未実施（手順は `Tools/HelperSmokeApp/README.md`「手動インストールモードでのテスト」）。
- アドホック署名 + Hardened Runtime + `com.apple.application-identifier` entitlement を持つ小さな実行ファイルは、ユーザープロセスとしては AMFI に拒否されず起動した。
  launchd から root で起動したときの挙動は未確認。
