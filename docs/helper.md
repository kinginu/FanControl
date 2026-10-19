# FanControlHelper（特権ヘルパー）

DynamicNotch のファン制御で SMC に書き込むための root 権限 launchd デーモン。
`SMAppService`（macOS 13+）で登録する。読み取り（温度・RPM）はアプリ本体が `FanControlSMC.SMCClient` で直接行い、**書き込みだけ**このヘルパーを XPC 経由で使う（設計書 §3.3 の Step 7）。

関連ソース:

| パス | 内容 |
|---|---|
| `Sources/FanControlXPC/FanControlHelperConstants.swift` | Mach サービス名、plist 名、Team ID プレースホルダ、書込許可リスト |
| `Sources/FanControlXPC/FanControlHelperProtocol.swift` | `@objc` XPC プロトコル、エラーコード、`makeHelperInterface()` |
| `Sources/FanControlSMC/` | IOKit AppleSMC アクセス（`SMCConnection`, `SMCClient`） |
| `Sources/FanControlHelper/` | デーモン本体（`main.swift`, `HelperListenerDelegate`, `HelperService`, `SessionRegistry`） |
| `Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fancontrol.plist` | launchd plist（唯一の正本） |
| `Support/Helper-Info.plist` | ヘルパー実行ファイルに埋め込む Info.plist テンプレート |

## 1. バンドル配置

```
DynamicNotch.app/Contents/
  MacOS/DynamicNotch
  MacOS/FanControlHelper                                  ← ヘルパー実行ファイル
  Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fancontrol.plist
```

Xcode での設定:

1. **Xcode の Command Line Tool ターゲット** `FanControlHelper` を追加し（**必須**）、`Sources/FanControlHelper/*.swift` をソースに含め、依存モジュール（Core / SMC / XPC）は SwiftPM パッケージをローカル依存として追加してライブラリ product をリンクする。
   **SwiftPM の executable product `FanControlHelper` をそのまま同梱してはいけない。** SwiftPM のビルドは `Helper-Info.plist` を Mach-O に埋め込まない（`Package.swift` に `unsafeFlags` は入れない方針）ため、`Bundle.main.infoDictionary` に `FanControlClientTeamID` が無く、`HelperConfiguration.teamID` がプレースホルダ `TEAMID0000` にフォールバックして**すべてのクライアントを拒否する**。SwiftPM の executable product は Linux/CI での構文・ビルド確認用にすぎない。
2. ヘルパーの Other Linker Flags:
   `-sectcreate __TEXT __info_plist $(SRCROOT)/FanControl/Support/Helper-Info.plist`
   （素の実行ファイルなので Info.plist を Mach-O に埋め込む。`Bundle.main.infoDictionary` から `FanControlClientTeamID` と `CFBundleVersion` を読む。）
   この手動方式に統一し、`GENERATE_INFOPLIST_FILE = NO`、`CREATE_INFOPLIST_SECTION_IN_BINARY = NO`、`INFOPLIST_FILE` は空にする
   （Xcode 側でもセクションを作ると重複する）。`PRODUCT_BUNDLE_IDENTIFIER = com.example.dynamicnotch.DynamicNotch.fancontrol`
   （署名 identifier。アプリはヘルパーにこの identifier を要求する。§2）。
3. DynamicNotch アプリターゲットに **Copy Files** フェーズを 2 つ追加:
   - Destination `Executables`（= `Contents/MacOS`）: `FanControlHelper`
   - Destination `Wrapper`, Subpath `Contents/Library/LaunchDaemons`: `com.example.dynamicnotch.DynamicNotch.fancontrol.plist`
   launchd plist の正本は `Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fancontrol.plist` のみ（SwiftPM ターゲット内にはコピーを置かない）。plist の配置は Xcode の Copy Files が担う。
4. アプリターゲットの Target Dependencies に `FanControlHelper` を追加。

## 2. 署名

- アプリとヘルパーは **同じ Team ID（DynamicNotch の Developer ID）** で署名し、両方とも **Hardened Runtime** を有効にする。公証（notarization）もアプリ全体で行う。
- ヘルパーは接続ごとに `NSXPCConnection.setCodeSigningRequirement(_:)`（macOS 13+）で次の要件を課す。満たさないクライアントの接続はシステムが無効化する:
  ```
  anchor apple generic and identifier "com.example.dynamicnotch.DynamicNotch" and certificate leaf[subject.OU] = "<TeamID>"
  ```
- `<TeamID>` は `Helper-Info.plist` の `FanControlClientTeamID`。未設定時は `FanControlHelperConstants.teamIdentifierPlaceholder`（`TEAMID0000`）にフォールバックし警告ログを出す（＝実質すべてのクライアントを拒否）。**出荷前に `Support/Helper-Info.plist` と `teamIdentifierPlaceholder` の 2 か所を実 Team ID に置換**（設計書 §5.1）。
- 逆方向にアプリもヘルパーを検証する: `HelperClient` は新しい接続ごとに `setCodeSigningRequirement` で
  ```
  anchor apple generic and identifier "com.example.dynamicnotch.DynamicNotch.fancontrol" and certificate leaf[subject.OU] = "<TeamID>"
  ```
  （`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)`）を課す。`<TeamID>` は `FanControlManager.shared.clientTeamID`
  （既定値 `teamIdentifierPlaceholder`）。定数を実 Team ID に置換するか、起動時に `clientTeamID` を設定する。
- **App Sandbox:** ヘルパーは root の launchd デーモンで、**サンドボックス化しない**（App Sandbox entitlement を付けない。
  IOKit の AppleSMC 書込と XPC リスナーに必要）。DynamicNotch 本体も非サンドボックスが前提。サンドボックス化する場合は
  アプリに `com.apple.security.temporary-exception.iokit-user-client-class` = `AppleSMCClient`（アプリ内での SMC 読み取り用）と
  `com.apple.security.temporary-exception.mach-lookup.global-name` = `com.example.dynamicnotch.DynamicNotch.fancontrol`（ヘルパーへの接続用）が必須
  （docs/integration.md §4）。
- 開発中（Apple Development 署名）は `anchor apple generic` を満たすので、Team ID を開発チームのものにすれば動作する。

## 3. 登録（アプリ側）

```swift
import ServiceManagement

let service = SMAppService.daemon(plistName: FanControlHelperConstants.plistName)
switch service.status {
case .notRegistered: try service.register()          // 初回書込時に呼ぶ（設計書 §3.3）
case .requiresApproval: SMAppService.openSystemSettingsLoginItems() // ユーザー承認待ち
case .enabled: break                                  // 接続可能
case .notFound: /* plist がバンドルに無い・配置ミス */ break
@unknown default: break
}
```

- `register()` 直後は通常 `.requiresApproval` になり、ユーザーが「システム設定 > 一般 > ログイン項目と機能拡張」（macOS 15）/「ログイン項目」（macOS 14）で許可するまで起動しない。`openSystemSettingsLoginItems()` で該当画面を開ける。`AssociatedBundleIdentifiers` により設定画面には DynamicNotch として表示される。
- 承認後はオンデマンド起動（`RunAtLoad` = false、`MachServices` で接続時に launchd が起動）。
- 接続: `NSXPCConnection(machServiceName: FanControlHelperConstants.machServiceName, options: .privileged)`、`remoteObjectInterface = makeHelperInterface()`。
- アプリ側の各呼び出しは `HelperClient.callTimeout`（既定 8 秒）で打ち切られる。タイムアウト時は
  `helperConnectionFailed("timeout")` となり接続を invalidate する（＝ヘルパー側ではセッション解放・値の復元が走る）。
- 接続後に `version(reply:)` を呼び、`protocolVersion` が一致しなければ `unregister()` → `register()` で更新する。
- アンインストール: `try await service.unregister()`。

### SMJobBless / `SMAuthorizedClients` を使わない理由

従来の `SMJobBless` + Info.plist の `SMAuthorizedClients` / `SMPrivilegedExecutables` 方式は:

- macOS 13 で非推奨。ヘルパーを `/Library/PrivilegedHelperTools` にコピーするためアプリ更新時の差し替え・削除が煩雑。
- `SMAppService` はヘルパーをアプリバンドル内に置いたまま登録でき、アプリ削除で一緒に消え、承認 UI も OS 標準。
- DynamicNotch の最小 OS は 14.6 なので `SMAppService` で十分。
- Mach サービス名は他のファン制御アプリのヘルパーと競合しない名前にする（§5.2）。

## 4. XPC プロトコルとセッション

`FanControlHelperProtocol`（すべて reply の先頭 `Int` が `FanControlHelperErrorCode`）:

| メソッド | 説明 |
|---|---|
| `version` | `(protocolVersion, ビルド文字列)` |
| `openSession` | 排他書込セッションを開く |
| `writeKey(key, bytes)` | 許可キーへ生バイト（big-endian）を書く。要セッション |
| `closeSession` | セッションを閉じる |
| `readKeyInfo(key)` | `(rc, dataSize, typeFourCC, attributes, message)`。セッション不要 |

エラーコード: `0 ok / 1 notSessionOwner / 2 sessionNotOpen / 3 invalidKey / 4 keyNotAllowed / 5 smcUnavailable / 6 smcError / 7 badRequest`。

**単一オーナーセッション（設計書 §5.3 (a)）**

- セッションは開いた XPC 接続（pid + 接続 ID）に属する。他の接続からの `openSession` / `writeKey` / `closeSession` は `notSessionOwner`。
- オーナー pid のプロセスが既に存在しない場合は次の `openSession` で自動回収。
- 接続の invalidation / interruption（アプリ終了・クラッシュ）でセッションを解放。
- セッション中に書いた各キーの **書込前の値** を初回書込の直前に記録する。記録（読み取り）に失敗した場合は書込自体を `6 smcError` で拒否する。
- close / 解放 / ヘルパーの SIGTERM 時に、まず速度系キー（`F<n>Tg`, `F<n>Mn`）を記録値に戻し、その後モード系キーを**固定の自動値**に戻す: `F<n>Md` = 0、`FS! ` = 記録値からこのセッションが立てたビットを落とした値（記録値そのものには戻さない。前のセッションの手動状態を再現しないため）。モード系の復元に失敗したら 1 回だけ再試行し、成否にかかわらずセッションは解放する。これによりクライアントがクラッシュしてもファンが手動固定のまま残らない。
- AppleSMC 接続はセッション中のみ保持。セッション開始時に `FNum` と各ファンのハードウェア `F<n>Mn` / `F<n>Mx` を読み、書込値の検証に使う。

**書込許可リスト**（`FanControlHelperConstants.allowedWriteKeyPatterns`）:

| パターン | 用途 |
|---|---|
| `^F[0-9]Tg$` | 目標回転数 |
| `^F[0-9]Md$` | ファンモード（Apple Silicon） |
| `^FS! $` | 強制モードビットマスク（Intel） |
| `^F[0-9]Mn$` | 最小回転数（Intel の「最小値＝目標値」手法） |

加えて、キーは 4 文字 ASCII、ペイロードは 1〜32 バイト、かつ SMC が返す `dataSize` と一致しなければ拒否する。

**値の検証**（ヘルパーが安全性の最終責任を持つ。ペイロードはキーの型で `SMCCodec.decode` して判定）:

| キー | 条件 | 違反時 |
|---|---|---|
| `F<n>Md` | 0 または 1 | `7 badRequest` |
| `F<n>Tg`, `F<n>Mn` | セッション開始時に読んだハードウェア `F<n>Mn`〜`F<n>Mx`（丸め誤差として ±1 RPM 許容） | `7 badRequest`（Mn/Mx が読めなかったファンは `6 smcError`） |
| `FS! ` | `1 << FNum` 以上のビットを含まない | `7 badRequest`（`FNum` が読めなければ `6 smcError`） |

アプリ側の `SafetyPolicy.enforceHardwareMinimum = false` はクライアント側の計画にしか効かず、最小値未満の目標値はヘルパーが拒否する。
ヘルパー自身は書込頻度を制限しない。アプリ側（`FanControlManager`）がポーリング由来の書込を、目標値の変化が 25 RPM（`writeThresholdRPM`）以下なら省略する（docs/kit.md）。

### プラットフォーム別の書込手順

- **Apple Silicon**: `F<n>Md` を `1` にしてから `F<n>Tg` を書かないと目標値が反映されない。`F<n>Md` = `0` で自動制御に戻る。
  （一部の新しい機種では追加のアンロックキー `Ftst` が必要との報告があるが、現状は許可リスト外。実機で確認後に追加を検討。）
- **Intel**: `FS! `（ui16 ビットマスク、bit n = ファン n を強制）を立てて `F<n>Tg` を書く。または `F<n>Mn` を目標値に設定する手法。ビットを 0 に戻す／`Mn` を元に戻すと自動制御。
- 値のエンコード（`fpe2`, `flt ` など）はアプリ側（`FanControlCore.SMCCodec`）の責務。ヘルパーは上記の検証を通ったバイト列をそのまま書く。

## 5. Mac での手動テスト

```sh
# 1. ビルド・署名済みの DynamicNotch.app を /Applications に置き、アプリから register() → 設定で承認
# 2. launchd の状態
sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fancontrol
# 3. ログ
log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
# 4. 埋め込み Info.plist / 署名の確認
otool -s __TEXT __info_plist DynamicNotch.app/Contents/MacOS/FanControlHelper | head
codesign -dvvv --entitlements - DynamicNotch.app/Contents/MacOS/FanControlHelper
codesign -d -r- DynamicNotch.app
```

確認項目:

1. アプリから `version` → `(1, "1.0 (1)")` が返る。
2. `openSession` → `writeKey("F0Md", [1])` → `writeKey("F0Tg", <fpe2/flt エンコード値>)` で回転数が変わる（`F0Ac` を読んで確認）。
3. 許可外キー（例 `TC0P`）は `4 keyNotAllowed`、サイズ不一致は `7 badRequest`。
4. 別プロセス（署名済み 2 つ目のビルド）から `openSession` → `1 notSessionOwner`。
5. 手動制御中にアプリを `kill -9` → ログに "went away; releasing session"、ファンが自動制御に戻る。
   ヘルパーを `sudo launchctl kill SIGTERM system/com.example.dynamicnotch.DynamicNotch.fancontrol` で止めても同様に自動制御に戻る（ログに "SIGTERM received"）。
   範囲外の目標値（`F0Mn` 未満など）や `F0Md` = 2 は `7 badRequest`。
6. 未署名・別 Team ID のクライアントは接続が即座に無効化される。
7. `SMAppService.daemon(plistName:).unregister()` 後、`launchctl print` でサービスが消える。
