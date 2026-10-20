# FanControlHelper（特権ヘルパー）

DynamicNotch のファン制御で SMC に書き込むための root 権限 launchd デーモン。
`SMAppService`（macOS 13+）で登録する（Team ID 付き署名が前提。Team ID が無い個人利用では §6 の手動インストールを使う）。読み取り（温度・RPM）はアプリ本体が `FanControlSMC.SMCClient` で直接行い、**書き込みだけ**このヘルパーを XPC 経由で使う（設計書 §3.3 の Step 7）。

関連ソース:

| パス | 内容 |
|---|---|
| `Sources/FanControlXPC/FanControlHelperConstants.swift` | Mach サービス名、plist 名、Team ID プレースホルダ、書込許可リスト |
| `Sources/FanControlXPC/FanControlHelperProtocol.swift` | `@objc` XPC プロトコル、エラーコード、`makeHelperInterface()` |
| `Sources/FanControlSMC/` | IOKit AppleSMC アクセス（`SMCConnection`, `SMCClient`） |
| `Sources/FanControlHelper/` | デーモン本体（`main.swift`, `HelperListenerDelegate`, `HelperService`, `SessionRegistry`） |
| `Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist` | launchd plist（唯一の正本） |
| `Support/Helper-Info.plist` | ヘルパー実行ファイルに埋め込む Info.plist テンプレート |
| `Sources/FanControlXPC/ManualInstallMode.swift` | 手動インストール（個人利用）モードの定数・要件文字列ビルダー・検証（§6） |
| `Support/manual-install/` | 手動インストール用スクリプト `install.sh` / `uninstall.sh` / `status.sh` と LaunchDaemon plist テンプレート（§6） |

## 1. バンドル配置

```
DynamicNotch.app/Contents/
  MacOS/DynamicNotch
  MacOS/FanControlHelper                                  ← ヘルパー実行ファイル
  Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist
```

Xcode での設定:

1. **Xcode の Command Line Tool ターゲット** `FanControlHelper` を追加し（**必須**）、`Sources/FanControlHelper/*.swift` をソースに含め、依存モジュール（Core / SMC / XPC）は SwiftPM パッケージをローカル依存として追加してライブラリ product をリンクする。
   **SwiftPM の executable product `FanControlHelper` をそのまま同梱してはいけない。** SwiftPM のビルドは `Helper-Info.plist` を Mach-O に埋め込まない（`Package.swift` に `unsafeFlags` は入れない方針）ため、`Bundle.main.infoDictionary` に `FanControlClientTeamID` が無く、`HelperConfiguration.teamID` がプレースホルダ `TEAMID0000` にフォールバックして**すべてのクライアントを拒否する**。SwiftPM の executable product は Linux/CI での構文・ビルド確認用にすぎない。
2. ヘルパーの Other Linker Flags:
   `$(inherited) -sectcreate __TEXT __info_plist "$(SRCROOT)/FanControl/Support/Helper-Info.plist"`
   （素の実行ファイルなので Info.plist を Mach-O に埋め込む。`Bundle.main.infoDictionary` から `FanControlClientTeamID` と `CFBundleVersion` を読む。）
   この手動方式に統一し、`GENERATE_INFOPLIST_FILE = NO`、`CREATE_INFOPLIST_SECTION_IN_BINARY = NO`、`INFOPLIST_FILE` は空にする
   （Xcode 側でもセクションを作ると `-sectcreate __TEXT __info_plist` が二重に渡る。Xcode 26.6 ではエラーにならないがどちらが残るか保証が無い）。
   設定値の全体と実ビルドでの確認結果は integration.md §2〜§4 と `docs/verification/helper-bundle-smoke-2026-10-20.md`（最小アプリ `Tools/HelperSmokeApp`）。`PRODUCT_BUNDLE_IDENTIFIER = com.example.dynamicnotch.DynamicNotch.fanfi`
   （署名 identifier。アプリはヘルパーにこの identifier を要求する。§2）。
3. DynamicNotch アプリターゲットに **Copy Files** フェーズを 2 つ追加:
   - Destination `Executables`（= `Contents/MacOS`）: `FanControlHelper`
   - Destination `Wrapper`, Subpath `Contents/Library/LaunchDaemons`: `com.example.dynamicnotch.DynamicNotch.fanfi.plist`
   launchd plist の正本は `Support/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist` のみ（SwiftPM ターゲット内にはコピーを置かない）。plist の配置は Xcode の Copy Files が担う。
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
  anchor apple generic and identifier "com.example.dynamicnotch.DynamicNotch.fanfi" and certificate leaf[subject.OU] = "<TeamID>"
  ```
  （`FanControlHelperConstants.helperCodeSigningRequirement(teamID:)`）を課す。`<TeamID>` は `FanControlManager.shared.clientTeamID`
  （既定値 `teamIdentifierPlaceholder`）。定数を実 Team ID に置換するか、起動時に `clientTeamID` を設定する。
- **App Sandbox:** ヘルパーは root の launchd デーモンで、**サンドボックス化しない**（App Sandbox entitlement を付けない。
  IOKit の AppleSMC 書込と XPC リスナーに必要）。DynamicNotch 本体も非サンドボックスが前提。サンドボックス化する場合は
  アプリに `com.apple.security.temporary-exception.iokit-user-client-class` = `AppleSMCClient`（アプリ内での SMC 読み取り用）と
  `com.apple.security.temporary-exception.mach-lookup.global-name` = `com.example.dynamicnotch.DynamicNotch.fanfi`（ヘルパーへの接続用）が必須
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
- オーナー pid のプロセスが既に存在しない場合は次の `openSession` で自動回収。同じ pid の**別の接続**から `openSession` が来た場合（クライアント側タイムアウトで旧接続を捨てた直後など）も、旧セッションを終了（復元）してから新しい接続に渡す。
- 接続の invalidation / interruption（アプリ終了・クラッシュ）でセッションを解放。
- セッション中に書いた各キーの **書込前の値** を初回書込の直前に記録する。記録（読み取り）に失敗した場合は書込自体を `6 smcError` で拒否する。
- close / 解放 / ヘルパーの SIGTERM 時の復元（`HelperWritePolicy.restore`、書込前レビュー 2026-10-20 で順序を変更。`docs/verification/pre-write-review-2026-10-20.md`）:
  1. `F<n>Mn` を記録値に戻す（現在は許可リスト外なので通常は記録されない）。
  2. モード系キーを**固定の自動値**に戻す: `F<n>Md` = 0、`FS! ` = 記録値からこのセッションが立てたビットを落とした値（記録値そのものには戻さない。前のセッションの手動状態を再現しないため）。「このセッションが立てたビット」は、書込値のうちセッション開始時の記録値で**立っていなかった**ビットだけ（`HelperWritePolicy.newlySetForceBits`。記録時点で SMC や他のツールが立てていたビットは数えないので、復元・スリープ・復帰でも落とさない）。失敗したら 1 回だけ再試行する。
  3. `F<n>Tg` は、このセッションでモード系キー（`F<n>Md` または `FS! ` のビット）を書いて**いない**ファン（target-only）だけ記録値に戻す。値はハードウェア `Mn`〜`Mx` にクランプする。
  モードを自動に戻したファンの `F<n>Tg` は書かない（自動制御中は SMC が目標値を持つ）。Apple Silicon ではアイドル時の記録値が `Tg` = 0（`Mn` 未満）で、
  旧実装のように `F<n>Md` = 1 のまま書き戻すとファン停止を指令することになり、続く `Md` = 0 が失敗すると手動 0 RPM のまま残る恐れがあった。
  モードの復元に失敗したファンの `F<n>Tg` も書き戻さず、最後に検証済みの目標値（`Mn`〜`Mx` 内）のまま残す（ログに記録）。
  復元の書込は値の検証（下表）を通さない。成否にかかわらずセッションは解放する。これによりクライアントがクラッシュしてもファンが手動固定のまま残らない。
- AppleSMC 接続はセッション中のみ保持。セッション開始時に `FNum` と各ファンのハードウェア `F<n>Mn` / `F<n>Mx` を読み、書込値の検証に使う。
- クライアントの成功した書込はキーごとに最後の値（`lastWritten` = クライアントの意図）として保持し、スリープ／復帰時の再適用に使う（§5「スリープ／復帰」）。ヘルパー自身の電源処理の書込はここに記録しない。

**書込許可リスト**（`FanControlHelperConstants.allowedWriteKeyPatterns`）:

| パターン | 用途 |
|---|---|
| `^F[0-9]Tg$` | 目標回転数 |
| `^F[0-9]Md$` | ファンモード（Apple Silicon） |
| `^FS! $` | 強制モードビットマスク（Intel） |

`F<n>Mn`（Intel の「最小値＝目標値」手法）は 2026-10-20 に許可リストから外した（アプリは書かない。Apple Silicon では読取専用 `0x84`）。`Ftst` などのアンロックキーも許可しない。

加えて、キーは 4 文字 ASCII、ペイロードは 1〜32 バイト、かつ SMC が返す `dataSize` と一致しなければ拒否する。
さらに SMC が返す属性に書込ビット `0x40`（`SMCKeyInfo.isWritable`）が無いキーは `7 badRequest` で拒否する。

**値の検証**（ヘルパーが安全性の最終責任を持つ。ペイロードはキーの型で `SMCCodec.decode` して判定。実装は `FanControlXPC.HelperWritePolicy.validate` で単体テスト済み）:

| キー | 条件 | 違反時 |
|---|---|---|
| `F<n>Md` | 0 または 1 | `7 badRequest` |
| `F<n>Tg` | セッション開始時に読んだハードウェア `F<n>Mn`〜`F<n>Mx`（丸め誤差として ±1 RPM 許容） | `7 badRequest`（Mn/Mx が読めなかったファンは `6 smcError`） |
| `FS! ` | `1 << FNum` 以上のビットを含まない | `7 badRequest`（`FNum` が読めなければ `6 smcError`） |

アプリ側の `SafetyPolicy.enforceHardwareMinimum = false` はクライアント側の計画にしか効かず、最小値未満の目標値はヘルパーが拒否する
（アプリ側でも `FanWriteStrategy.writes(for:)` が書込列を作る前に `rpmOutOfRange` で拒否するので、`F<n>Md` = 1 だけ書かれて `F<n>Tg` で失敗する状態にはならない）。
ヘルパー自身は書込頻度を制限しない。アプリ側（`FanControlManager`）がポーリング由来の書込を、目標値の変化が 25 RPM（`writeThresholdRPM`）以下なら省略する（docs/kit.md）。

### プラットフォーム別の書込手順

- **Apple Silicon**: `F<n>Md` を `1` にしてから `F<n>Tg` を書く（自動モード中の `F<n>Tg` 書込は SMC に上書き／拒否される可能性があるため。実機では未確認）。`F<n>Md` = `0` で自動制御に戻る。
  `F<n>Md` = 1 と `F<n>Tg` の間に失敗した場合はアプリが `F<n>Md` = 0 に戻す（kit.md「部分的な失敗」）。
  （一部の新しい機種では追加のアンロックキー `Ftst` が必要との報告があるが、現状は許可リスト外。実機で確認後に追加を検討。
  Mac14,9 / macOS 26 では `Ftst` は存在しない。同機種の属性は `F<n>Md` = `0xd0`（`ui8 `）、`F<n>Tg` = `0xd4`（`flt `）で書込ビット `0x40` あり、
  `F<n>Mn` = `0x84` は `0x40` なし（integration.md §6 Phase 1）。いずれも書込は未試行。）
- **Intel**: `FS! `（ui16 ビットマスク、bit n = ファン n を強制）を立てて `F<n>Tg` を書く。ビットを 0 に戻すと自動制御。（`F<n>Mn` を目標値に設定する手法は使わない。）
- 値のエンコード（`fpe2`, `flt ` など）はアプリ側（`FanControlCore.SMCCodec`）の責務。ヘルパーは上記の検証を通ったバイト列をそのまま書く。

## 5. Mac での手動テスト

```sh
# 1. ビルド・署名済みの DynamicNotch.app を /Applications に置き、アプリから register() → 設定で承認
# 2. launchd の状態
sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi
# 3. ログ
log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
# 4. 埋め込み Info.plist / 署名の確認
launchctl plist __TEXT,__info_plist DynamicNotch.app/Contents/MacOS/FanControlHelper
codesign -dvvv --entitlements - DynamicNotch.app/Contents/MacOS/FanControlHelper
codesign -d -r- DynamicNotch.app
```

確認項目:

1. アプリから `version` → `(1, "1.0 (1)")` が返る。
2. `openSession` → `writeKey("F0Md", [1])` → `writeKey("F0Tg", <fpe2/flt エンコード値>)` で回転数が変わる（`F0Ac` を読んで確認）。
3. 許可外キー（例 `TC0P`）は `4 keyNotAllowed`、サイズ不一致は `7 badRequest`。
4. 別プロセス（署名済み 2 つ目のビルド）から `openSession` → `1 notSessionOwner`。
5. （スリープ／復帰）手動制御中にスリープ → 復帰。ログに `Power: system will sleep; … handed back to the SMC: F0Md=0 …` と `Power: wake recovery 1/3 … wrote …` が出て、`fanfi-probe --watch 1` で復帰後に `manual(0)` のサンプルが出ないこと（下の「スリープ／復帰」）。
6. 手動制御中にアプリを `kill -9` → ログに "went away; releasing session"、ファンが自動制御に戻る。
   ヘルパーを `sudo launchctl kill SIGTERM system/com.example.dynamicnotch.DynamicNotch.fanfi` で止めても同様に自動制御に戻る（ログに "SIGTERM received"）。
   範囲外の目標値（`F0Mn` 未満など）や `F0Md` = 2、`F0Mn` への書込（Apple Silicon は `0x40` なし、かつ許可リスト外）は `7 badRequest` / `4 keyNotAllowed`。
   復元後、`fanfi-probe` で `F0Md` = 0 であること、および `F0Tg` が記録値（アイドル時 0）に**書き戻されていない**（SMC が自分で決めた値になる）ことをログ（"Failed to restore" が出ていないこと）と合わせて確認する。
7. 未署名・別 Team ID のクライアントは接続が即座に無効化される。
8. `SMAppService.daemon(plistName:).unregister()` 後、`launchctl print` でサービスが消える。

### スリープ／復帰（2026-10-20 実装、同日 11:22–11:26 の実機再テストで合格）

背景（`docs/verification/first-write-2026-10-20.md` テスト 4）: スリープをまたぐと SMC は `F<n>Tg` を 0 にリセットし `F<n>Md` = 1 を保持する（スリープ前に automatic だったファンも）。
復帰直後はファンが「手動・目標 0」= 停止状態になり、アプリの復帰通知が遅れればそのまま残る。ヘルパーは安全性の最終責任者なので、アプリに頼らず自分で処理する。

再テスト（同ファイル「テスト 4 再テスト」）で分かった実際の仕組み: スリープ前にヘルパーが `Md` = 0 で返していても、SMC は復帰直後に**全ファンを `F<n>Md` = 3 / `Tg` = 0**（1 でも 0 でもない過渡状態）で起こし、1〜2 秒後に自分で `Md` = 0 に戻す。この過渡中に書いた `F<n>Tg` は SMC が `Md` = 0 に戻す時点で捨てられる（定着しない）。復帰直後の「手動・目標 0」は SMC 側の過渡状態で、こちらの書込由来ではない。合格基準（復帰後 `manual(0)` が 2 サンプル連続しない）を満たし、プロファイルは約 2 秒で復元、回転数は約 6 秒で追随した（対策前は約 5 秒）。

実装: `PowerObserver`（`Sources/FanControlHelper/PowerObserver.swift`、IOKit の薄い糊）が `IORegisterForSystemPower` を登録する。
ヘルパーは `dispatchMain()` で動き main の CFRunLoop を回さないため、通知ポートは run loop source ではなく `IONotificationPortSetDispatchQueue` で専用キューに載せる。
判断はすべて `FanControlXPC.PowerTransitionPolicy`（純粋関数、`PowerTransitionPolicyTests`）にあり、`SessionRegistry` がロック下で実行する。書込は通常のクライアント書込と同じ検証経路（許可リスト、`HelperWritePolicy.validate`、初回書込前の記録）を通る。

| 通知 | 動作 |
|---|---|
| `kIOMessageCanSystemSleep` | 常に許可（`IOAllowPowerChange`）。スリープを拒否しない |
| `kIOMessageSystemWillSleep` | セッションが開いていれば、セッションが強制中のファン（最後の `F<n>Md` 書込が非 0、またはこのセッションが立てた `FS! ` ビット）を SMC に返す: `F<n>Md` = 0、`FS! ` は該当ビットを落とす。`F<n>Tg` は書かない。セッションとクライアントの意図は保持。書込の成否にかかわらず直後に `IOAllowPowerChange`（30 秒制限に対し数回の SMC 呼出のみ） |
| `kIOMessageSystemHasPoweredOn` | 0 s / 1 s / 3 s（`PowerTransitionPolicy.wakeRetryDelays`。復帰直後の `Md` = 3 過渡中の書込は SMC が 1〜2 秒後に `Md` = 0 へ戻す際に捨てるため、過渡が終わった後の試行で書き直す）に復旧を試みる。各回でファンを読み直すので冪等（揃っていれば何も書かない）。新たなスリープで残りの試行は破棄 |

復帰時の各試行（セッションあり、`PowerTransitionPolicy.wakeRecovery`）:

- `Md` は非 0 なら手動扱い（`Md` = 3 の過渡状態も含む）。そのため 1 回目の試行は `Md` = 3 を手動と見て `F<n>Tg` だけを書き、これは定着しない。SMC が `Md` = 0 に戻した後の 2 回目の試行が `F<n>Md` = 1 → `F<n>Tg` を書き直して定着する（再テストで確認した想定動作。下のログ例）。
- 記憶したファン（強制中で目標値の記録あり）: 手動でなければモードキー（`F<n>Md` = 最後に書かれた値 / `FS! ` ビット）→ `F<n>Tg` = 最後の目標値の順で書く。手動だが `F<n>Tg` が記憶値から 5 RPM を超えてずれていれば `F<n>Tg` だけ書く。
- それ以外で手動モードのファン（目標の記録が無い `F<n>Md` = 1。テスト 4 の Fan 2 のように SMC が手動で起こしたもの、`Md`=1 だけ成功して `Tg` が失敗したもの）: `F<n>Md` = 0（`FS! ` はビットを落とす）で SMC に返す。
- 書込順は `F<n>Md`（ファン番号順）→ `FS! ` 1 回 → `F<n>Tg`。記憶はクライアントの最新の書込なので、復帰後にアプリが目標を変えれば以降の試行はそれに従う。

セッションなしで復帰した場合は 1 回目の試行でファンを読み、手動モードのファンがあれば警告ログだけ出す（別のツールの可能性があるので書かない）。

ログ（すべて notice 以上なので永続化される。`log show --last 10m --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'` で後から確認可能）:

```
Power: registered for system sleep/wake notifications                       (info、起動時)
Power: system will sleep; session of pid 1234 open, handed back to the SMC: F0Md=0; remembered targets: F0 3000
Power: system will sleep; no session open, nothing to hand back
Power: system has powered on; wake recovery at 0.0s, 1.0s, 3.0s
Power: wake recovery 1/3 (session of pid 1234): observed F0 Md=3 Tg=0, F1 Md=3 Tg=0; wrote F1Md=0, F0Tg=3000
Power: wake recovery 2/3 (session of pid 1234): observed F0 Md=0 Tg=0, F1 Md=0 Tg=0; wrote F0Md=1, F0Tg=3000
Power: wake recovery 3/3 (session of pid 1234): fans already match (F0 Md=1 Tg=3000, F1 Md=0 Tg=0)
Power: system has powered on; no session open but fan(s) 0,1 are in manual mode - not writing (another tool may own them)
Power: IORegisterForSystemPower failed; sleep/wake fan handling is disabled   (error。この場合は従来どおりアプリ側の処理だけ)
```

上の 1/3〜3/3 は再テスト（Fan 1 固定 3000 RPM、Fan 2 automatic）で実際に出た並び。1/3 の `F0Tg=3000` は `Md` = 3 の過渡中なので効かず、2/3 で `Md` = 0 を観測して書き直すのが正常（失敗ではない）。
失敗した書込は `F0Tg=3000 FAILED (<理由>)` のように同じ行に出る。アプリ側（`FanControlManager`）も復帰時に即座・2 s・5 s で再適用し、ポーリングで「手動かつ `Tg` < `Mn`」などを検出して書き直す（kit.md「Sleep/wake」「State drift」）。
既知の制約: DarkWake でも `HasPoweredOn` が届くため、セッション中は DarkWake の間も記憶した目標で回る（次の `WillSleep` で再び返す）。ヘルパーの SIGKILL / クラッシュ中のスリープは対象外。

## 6. 手動インストール（個人利用モード）

Apple Developer Program の Team ID が無い個人利用向けに、`SMAppService` を使わずヘルパーを **素の LaunchDaemon として手動で入れる** モード。
アプリとヘルパーはアドホック署名（`CODE_SIGN_IDENTITY = -`）でよい。§1〜§5 の SMAppService 方式（Team ID 付きビルド）はそのまま残っており、
環境変数が無ければヘルパーの動作は従来と同じ。

### 仕組み

| 項目 | SMAppService 方式（§1〜§3） | 手動インストール方式 |
|---|---|---|
| 登録 | アプリが `SMAppService.daemon(plistName:).register()`、ユーザーが設定で承認 | ユーザーが `sudo FanControl/Support/manual-install/install.sh <App.app>` |
| ヘルパーの場所 | `App.app/Contents/MacOS/FanControlHelper`（`BundleProgram`） | `/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi`（root:wheel 0755、`Program`） |
| plist | `App.app/Contents/Library/LaunchDaemons/…fanfi.plist` | `/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist`（root:wheel 0644） |
| ヘルパー → アプリの検証 | `anchor apple generic and identifier "…DynamicNotch" and certificate leaf[subject.OU] = "<TeamID>"` | `identifier "com.example.dynamicnotch.DynamicNotch" and cdhash H"<アプリの cdhash>"`（plist の `EnvironmentVariables` → `FANCONTROL_CLIENT_REQUIREMENT`） |
| アプリ → ヘルパーの検証 | `anchor apple generic and identifier "…fanfi" and certificate leaf[subject.OU] = "<TeamID>"` | `identifier "com.example.dynamicnotch.DynamicNotch.fanfi" and cdhash H"<インストール済みヘルパーの cdhash>"` |
| アプリの状態表示 | `HelperInstallStatus.enabled` など | `.installedManually`（「手動インストール済み（個人利用モード）」） |
| 削除 | アプリから `unregister()` / 設定でオフ | `sudo …/uninstall.sh` |

Label / Mach サービス名は両方式で同じ（`com.example.dynamicnotch.DynamicNotch.fanfi`）。**両方式を同時に入れてはいけない**:
`install.sh` は SMAppService 由来のジョブ（`launchctl print` の `path` が手動 plist 以外）が読み込まれていれば中止する。
アプリ側も手動インストールのファイルがあれば `SMAppService` を呼ばない（kit.md「Helper install status」）。

テンプレート `Support/manual-install/com.example.dynamicnotch.DynamicNotch.fanfi.manual.plist`（`install.sh` が値を埋めて配置する）:

```xml
<key>Label</key>              <string>com.example.dynamicnotch.DynamicNotch.fanfi</string>
<key>Program</key>            <string>/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi</string>
<key>MachServices</key>       <dict><key>com.example.dynamicnotch.DynamicNotch.fanfi</key><true/></dict>
<key>EnvironmentVariables</key>
<dict>
    <key>FANCONTROL_CLIENT_REQUIREMENT</key>
    <string>identifier "com.example.dynamicnotch.DynamicNotch" and cdhash H"<40 桁の 16 進>"</string>
</dict>
<key>RunAtLoad</key>          <false/>      <!-- Mach サービスへの接続時にオンデマンド起動 -->
<key>ProcessType</key>        <string>Adaptive</string>
```

テンプレートのままの値（`__FILLED_IN_BY_INSTALL_SH__`）は検証を通らないため、誤ってそのまま入れてもヘルパーは起動を拒否する。
`AssociatedBundleIdentifiers` は入れていない（SMAppService / ログイン項目表示用。手動方式では不要）。

### ヘルパー側: `FANCONTROL_CLIENT_REQUIREMENT`

起動時に `HelperConfiguration.resolveClientRequirement()`（純粋ロジックは `FanControlHelperConstants.resolveClientRequirement(environment:teamID:)`）が決める:

- 環境変数が **無い** → 従来どおり Team ID 要件（`clientCodeSigningRequirement(teamID:)`）。ログ `Client requirement mode: Team ID (SMAppService)`。
- 環境変数が **あり、形式が正しい** → その要件。ログ `Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to <cdhash>`。
  この場合 Team ID（`FanControlClientTeamID`）は参照しない（プレースホルダ警告も出ない）。
- 環境変数が **あるが不正**（空、bundle ID だけ、cdhash なし、`or` 付きなど）→ `fault` ログ `Refusing to start: invalid FANCONTROL_CLIENT_REQUIREMENT …` を出し、
  **リスナーを開かずに終了**（終了コード 78 = `EX_CONFIG`）。Team ID 要件や弱い要件へのフォールバックはしない。

受け付ける形式は `FanControlHelperConstants.manualModeClientRequirement(cdhash:)` が作る文字列と **完全一致**（前後の空白のみ許容、16 進は大小文字可）:

```
identifier "com.example.dynamicnotch.DynamicNotch" and cdhash H"<40 桁の 16 進>"
```

「`identifier "…"` と `cdhash H"` を含む」という部分一致にしなかったのは、`… and cdhash H"…" or anchor apple` のように `or` で緩めた要件まで通ってしまうため。
さらに `SecRequirementCreateWithString` でコンパイルできることも起動時に確かめる。`install.sh` も同じ書式（`common.sh` の `client_requirement`）で書き、
テスト（`ManualInstallScriptConsistencyTests`）が Swift 側の定数・書式とスクリプト・テンプレートの一致を確認する。

### 脅威モデル（なぜ cdhash 固定なら個人利用で許容できるか）

- **損害の上限を決めるのはヘルパー自身の書込検証**（許可リスト + `HelperWritePolicy.validate` のハードウェア値域検証、§4）。クライアント検証を通ったプロセスが依頼できるのは
  「許可されたファンキーに、そのファンの `Mn`〜`Mx` の範囲で、モードは 0/1 で書く」ことだけで、ヘルパーは切断・終了時に自動制御へ戻す（§5）。最悪でも「アプリ自身ができること」
  （ファンを最大で回し続ける、最低回転数に固定する）に限られ、任意の SMC キーや範囲外の値は書けない。
- **手動インストール方式では、ログイン中ユーザーと同じ uid で動くプロセスは信頼境界の内側**にある。クライアント検証（cdhash 固定）が防ぐのは
  「**別のビルド**（別バイナリ）が接続すること」であり、同じユーザーの悪意あるプロセスがヘルパーを使うことまでは防がない:
  - cdhash 要件が見るのは**メイン実行ファイルのコードディレクトリ**だけ（`NSXPCConnection.setCodeSigningRequirement` は接続相手の動的コードを検査し、バンドル全体の封印は見ない）。
  - アプリが `com.apple.security.get-task-allow` を持つと（Xcode が Debug ビルドに自動注入する）、同じユーザーは `task_for_pid` / `lldb -p` で実行中のアプリにコードを注入でき、
    そのプロセスは固定 cdhash を満たしたままヘルパーに依頼できる。
  - アプリが `com.apple.security.cs.disable-library-validation` を持つと、ユーザーが書き換えられるバンドル内の framework（`Lottie.framework`、`Sparkle.framework` など）を
    差し替えたものがそのまま読み込まれ、やはり cdhash は変わらない。
  - したがって cdhash 固定は「同じユーザーのマルウェア」に対する境界ではない。Team ID 方式（§1〜§3）でもアプリ側の entitlement が同じなら事情は同じ。
- **`install.sh` の警告**: 固定するアプリが上の 2 つの entitlement を持つと警告を出す（ヘルパーの `com.apple.application-identifier` 警告と同様。中止はしない）。
  - **`get-task-allow` を外す**: 固定するビルドは Release でビルドするか、Debug なら `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` を付ける
    （例: `xcodebuild … -configuration Release build CODE_SIGN_IDENTITY=-` または `… -configuration Debug build CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`）。
    `codesign -d --entitlements - --xml <App.app>` に `get-task-allow` が無いことを確認してから `install.sh` する。
  - **`disable-library-validation` は残す**: アドホック署名には Team ID が無く、Hardened Runtime のライブラリ検証は「同じ Team ID か Apple 署名」のライブラリしか読み込まないため、
    外すと埋め込み framework（Lottie / Sparkle）の読込が拒否されアプリが起動しない（Debug dylib で同じ症状を確認済み。下記「注意」）。
    代わりにアプリのバンドルを自分のユーザーだけが書ける場所に置く（`/Applications` に置くなら所有者・権限を確認する）。
- **bundle ID だけの要件（`identifier "com.example.dynamicnotch.DynamicNotch"`）は偽装できる**。アドホック署名は誰でも任意の identifier で作れるため、
  同じユーザー権限で動く任意のプロセスが `codesign -s - -i com.example.dynamicnotch.DynamicNotch` で自分を署名すれば、注入も差し替えも不要で通ってしまう。だから環境変数が cdhash を含まない場合は起動を拒否する。
- **cdhash はコードディレクトリのハッシュ**で、メイン実行ファイルの内容（と、署名時に封印された Info.plist・リソースのハッシュ）に結び付く。別のバイナリが同じ cdhash を持つことはできないので、
  再ビルドしたアプリ・別のアプリ・スモークアプリは接続できない（「固定 cdhash が一致しないとき」）。Team ID 方式の「Apple の証明書チェーン + Team ID」の代わりに「このビルド」を信頼する。
- 要件文字列は root 所有の `/Library/LaunchDaemons/…plist`（0644）にあり、書き換えられるのは root だけ。root を持つ攻撃者はヘルパーを使わずとも SMC に書けるので、ここは新たな攻撃面にならない。
- **アプリ → ヘルパーの検証**: `HelperClient` は接続時に root 所有の `/Library/PrivilegedHelperTools/<label>` から cdhash を読み（ファイルとその親ディレクトリが uid 0 かつ group/other 書込不可で、
  署名が `SecStaticCodeCheckValidity` を通ることを確認）、それを要件に固定する。そこに置けるのは root（＝ `sudo install.sh` したユーザー）だけなので、信頼の起点は「root が入れたもの」で、
  そもそも system ドメインの Mach サービス名を登録できるのも root だけ。これは主に「別のバイナリが同じ Mach 名で応答している」取り違えを防ぐためのもので、SMC 書込の安全性はヘルパー側の検証が担う。
- 弱点・前提: (1) アプリを再ビルド・置換するたびに cdhash が変わり、`install.sh` の再実行が必要（しないとヘルパーが接続を拒否する。アプリ側のエラー文に再実行の案内を付けている）。
  (2) Gatekeeper / 公証は効かない（自分でビルドしたものを自分で入れる前提）。(3) 配布には使わない（他人の Mac では Team ID 方式を使う）。
  (4) 同じユーザーのプロセスは上記のとおりヘルパーを使えるので、個人利用の Mac で、自分のユーザーで動くものを信頼できることが前提。

### アプリ側

- 要件の選択（`FanControlHelperConstants.helperRequirementMode(appTeamID:manualInstallDetected:)`）: 実行中のアプリ自身の署名に Team ID が無い
  （`SecCodeCopySelf` → `SecCodeCopySigningInformation` の `kSecCodeInfoTeamIdentifier` が nil）**または** 手動インストールのファイルがある → cdhash 固定、
  それ以外 → Team ID 要件（従来どおり）。詳細は kit.md。
- `HelperInstaller.status()` は `/Library/LaunchDaemons/<label>.plist` と `/Library/PrivilegedHelperTools/<label>` の **両方** があれば `.installedManually`。
  片方だけなら `.unknown("manual installation incomplete …")`。手動インストール時の `register()` は何もせず `.installedManually` を返し、`unregister()` は
  「`sudo uninstall.sh` で削除する」旨のエラーを投げる。
- 手動インストールされたヘルパーのプロトコル版がアプリと違う場合、`openSMCSession()` は再登録を試みずに「`install.sh` を再実行」のエラーを出す。

### 固定 cdhash が一致しないとき（アプリ側の表示、2026-10-20）

アプリを再ビルド・置換したのに `install.sh` を再実行していない、または別のアプリ（スモークアプリなど）を指定して入れた場合、
plist の `FANCONTROL_CLIENT_REQUIREMENT` は別ビルドの cdhash を固定しているため、ヘルパーはこのアプリの要求をすべて拒否する。
ヘルパー側のログは `Accepted connection N from pid …` の直後に `Connection N from pid … invalidated`（最初のメッセージで要件検査に落ちる）。
アプリ側は次のように振る舞う（kit.md "Helper connection lifecycle"）:

- **接続しない**: `HelperClient` は接続前に root 所有の plist（0644、root 不要で読める）の固定 cdhash と自分の cdhash を比べ、
  違えば接続せずに拒否状態にする。plist を読めないなど判定できない場合は接続し、「返信の無いまま切断」が 2 回続いたら拒否とみなす。
  ヘルパーの署名がアプリの要件に合わない場合（`NSXPCConnectionCodeSigningRequirementFailure`）は 1 回で拒否。
- **自動で再試行しない**: 拒否は「再確認」ボタン、アプリの再起動、または `install.sh` の再実行（plist とヘルパーの更新日時・サイズが変わる）で解除されるまで続き、
  その間の操作（プロファイル選択、自動制御に戻す）は接続せずに即エラーになる。拒否以外の失敗は 2 秒から倍々、最大 5 分の間隔を空ける。
- **表示**: 設定 ▸ Fan Control ▸ 一般 ▸ ヘルパーで、状態が「手動インストール済み（別のビルドに固定）」、接続が「拒否（別のビルドに固定）」
  （実行時に検出した場合は「ヘルパーが拒否」/「拒否（ヘルパーの署名が不一致）」）になり、
  「インストール済みのヘルパーは別のビルドの DynamicNotch に固定されているため、このアプリからの接続を拒否します。このアプリを指定して sudo install.sh を再実行し（FanControl/Support/manual-install/）、「再確認」をクリックしてください。」
  と「再確認」ボタンが出る。エラー欄にも同じ案内。スモークアプリは `HelperInstaller.status()` に `installedManuallyMismatch(...)`、要件の行に
  `plist pins ANOTHER app build …`、拒否中は赤字で `Helper REJECTED this app (no automatic retry): …` を出し、「Check again」で再試行できる。
- **直し方**: `sudo ./install.sh <このアプリ>` を再実行 →「再確認」。`./status.sh <App.app>` でも一致を確認できる。

### 手順

```sh
# 0. アプリ（ヘルパー込み）をアドホック署名でビルドする。Hardened Runtime を付けるなら Debug でも
#    ENABLE_DEBUG_DYLIB = NO にする（下記「注意」）。例: スモークアプリ
cd FanControl/Tools/HelperSmokeApp && xcodegen generate && \
  xcodebuild -project FanControlSmoke.xcodeproj -scheme FanControlSmoke -configuration Debug \
  -derivedDataPath .derivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
APP="$PWD/.derivedData/Build/Products/Debug/FanControlSmoke.app"
cd ../../Support/manual-install

# 1. 予行（root 不要・何も変更しない）: 署名検証、cdhash、生成される plist、実行するコマンドを表示
./install.sh --dry-run "$APP"
# 2. インストール（ユーザーが実行）
sudo ./install.sh "$APP"
# 3. 状態（root 不要・読み取りのみ）。アプリを渡すと固定 cdhash との一致も確認
./status.sh "$APP"
sudo launchctl print system/com.example.dynamicnotch.DynamicNotch.fanfi
log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
# 4. アプリを再ビルド・置換したら（cdhash が変わる）
sudo ./install.sh "$APP"
# 5. 削除（bootout で SIGTERM → ヘルパーはファンを自動制御に戻してから終了）
sudo ./uninstall.sh
```

`install.sh` が行うこと（`set -euo pipefail`、何度実行してもよい）:

1. `<App>/Contents/MacOS/FanControlHelper` の存在、アプリの `CFBundleIdentifier`、両方の `codesign --verify --strict`、署名 identifier（アプリ `…DynamicNotch`、ヘルパー `…fanfi`）を確認。
2. アプリのメイン実行ファイルの cdhash を `codesign -dvvv` の `CDHash=` 行から取得（1 行だけであること・40 桁 16 進であることを確認）。
   ユニバーサルバイナリはホストのアーキテクチャ（`uname -m`、Apple Silicon なら arm64）のスライスを `--arch` で選ぶ。そのスライスが無い・単一アーキテクチャがホストと違う場合は中止。
3. ヘルパーに `com.apple.application-identifier` entitlement（Xcode が自動注入）が付いていれば警告を出す（下記「注意」）。
   アプリに `com.apple.security.get-task-allow` または `com.apple.security.cs.disable-library-validation` が付いていれば警告を出す（「脅威モデル」。中止はしない）。
4. SMAppService 由来の同名ジョブが読み込まれていれば中止。
5. テンプレートから plist を生成（`plutil -replace` で `Program` と `FANCONTROL_CLIENT_REQUIREMENT`、`plutil -lint`）。
6. 読み込み済みなら `launchctl bootout system/<label>`（終了を待つ）→ `install -o root -g wheel -m 0755` でヘルパーを配置し、配置後の署名と cdhash を再確認 →
   `install -o root -g wheel -m 0644` で plist を配置 → `launchctl enable system/<label>` → `launchctl bootstrap system <plist>` → `launchctl print` の要約。

`--dry-run` は root 不要で、検証と plist 生成までは実際に行い、生成した plist を表示し、変更系コマンド（`install`、`launchctl`）は `[dry-run] …` と表示するだけ。

### 注意

- **Debug ビルドのデバッグ dylib**: Xcode 26 の Debug ビルドは既定（`ENABLE_DEBUG_DYLIB`）でアプリを薄いスタブ + `<App>.debug.dylib` に分ける。
  アドホック署名 + Hardened Runtime ではライブラリ検証がこの dylib の読込を拒否し（`mapping process and mapped file (non-platform) have different Team IDs`）、
  **アプリが起動しない**（2026-10-20 にスモークアプリで確認）。`ENABLE_DEBUG_DYLIB = NO` にするか Release でビルドする（`Tools/HelperSmokeApp/project.yml` は NO に設定済み）。
- **`com.apple.application-identifier`**: Xcode は Command Line Tool のヘルパーにこの entitlement を自動注入する（helper-bundle-smoke 検証記録）。
  同じ entitlement・アドホック署名・Hardened Runtime の小さな実行ファイルはユーザープロセスとしては起動できた（2026-10-20）が、launchd から root で起動したときに
  AMFI が拒否しないかは未確認。拒否された場合は `log show --last 5m --predicate 'process == "amfid" OR sender == "AppleMobileFileIntegrity"'` に出る。
- macOS 13 以降、`/Library/LaunchDaemons` に入れたジョブは「ログイン項目と機能拡張 ▸ バックグラウンドでの実行を許可」に現れ、
  追加時に通知が出ることがある。ここでオフにされると起動しない。
- 手動インストール中は Team ID 方式（SMAppService）を登録しない。切り替えるときは先に `sudo uninstall.sh`。
