# SMC 書込経路の書込前レビュー（2026-10-20）

> **Historical record (2026-10-20, in Japanese).** It describes the code as it was on that date; the implementation has moved on since (file names, line numbers and some behaviour differ). Current behaviour: [kit.md](../kit.md), [helper.md](../helper.md). Summary of all hardware results: [SUMMARY.md](SUMMARY.md).
>
> **Paths:** this record predates the standalone repository. `FanControl/…` is now the repository root; the host glue it mentions (`FanControl/DynamicNotchIntegration/…`, `PATCHES.md`, `Tools/IntegrationTypeCheck`) has since moved to the DynamicNotch app repository (`DynamicNotchApp/Sources/FanControlGlue/`, built directly by the app).

対象: 実機で初めて SMC に書き込む前の、書込経路全体のコードレビュー。
**このレビューでは SMC へは一切書き込んでいない**（ヘルパーも起動していない）。読取専用の `fanfi-probe` のみ実行した。

- 環境: MacBook Pro Mac14,9（M2 Pro）、macOS 26.5.2、Swift 6.3.3（Command Line Tools のみ）
- 基準コミット: `84693ff`（以下「旧」の行番号はこのコミット、「新」は本レビュー後の作業ツリー）
- 対象: `FanControlKit/{FanWriteStrategy, FanControlManager, HelperClient, ApplyGenerationGate}.swift`、
  `FanControlHelper/*.swift`、`FanControlXPC/*`、`FanControlSMC/*`、`FanControlCore/SMCCodec.swift`、`docs/helper.md`、`docs/kit.md`
- 結果: `swift build` 警告 0、`swift test` 113 tests / 19 suites すべて成功（本レビューで追加したテストは 16 件。
  件数には並行作業中の別変更分も含む）

## 実機の前提（2026-10-20 に `fanfi-probe` で再確認）

```
FNum  [ui8 ] attr=80  02
FS!_  <absent>          Ftst  <absent>
F0Mn  [flt ] attr=84  00 d0 10 45  => 2317     F0Mx  [flt ] attr=85  00 80 d4 45  => 6800
F0Ac  [flt ] attr=84  00 00 00 00  => 0        F0Tg  [flt ] attr=d4  00 00 00 00  => 0
F0Md  [ui8 ] attr=d0  00                       （F1* も同じ）
```

アイドル時は `F<n>Tg` = 0 で `F<n>Mn` = 2317 を**下回る**。書込可ビット `0x40` があるのは `F<n>Md`（0xd0）と `F<n>Tg`（0xd4）のみ。

## 所見一覧

| # | 所見 | 重大度 | 対応 |
|---|---|---|---|
| 1 | セッション復元がアイドル時の `Tg`=0 を `Md`=1 のまま書き戻す（範囲検査を通らない経路） | **高** | 修正済み |
| 2 | 書込列の途中失敗（`Md`=1 成功 → `Tg` 失敗）でファンが手動・古い目標値（0 RPM）のまま残り、ポーリングも戻さない | **高** | 修正済み |
| 3 | `Mn` 未満の目標値はヘルパーが `Tg` だけ拒否する（＝所見 2 を確実に誘発する） | 中 | 修正済み |
| 4 | 許可リストに `F<n>Mn` が残っている／書込属性 `0x40` を検査していない | 中 | 修正済み |
| 5 | ヘルパーが SIGKILL・クラッシュした場合は復元されず、「自動制御に戻す」もセッション無しでは何も書かない | 中 | 一部修正（回収処理）、残りは文書化 |
| 6 | 終了時（⌘Q）の close がシリアライザを通らず、世代も進めない | 低 | 修正済み |
| 7 | 同一 pid の新しい接続が、旧接続の解放前に `openSession` すると `notSessionOwner` | 低 | 修正済み |
| 8 | 書込順序（`Md` → `Tg`）、`flt ` / `ui8 ` エンコード、Intel 分岐、キー名検査 | 情報 | 問題なし（テスト追加） |
| 9 | タイムアウト・世代ゲート・「自動制御に戻す」後の古い目標値の書込 | 情報 | 問題なし（修正 2・6 で補強） |
| 10 | 緊急オーバーライドとセッション終了の関係、スリープ復帰 | 情報 | 設計どおり。文書化 |

---

## 1. セッション復元: アイドル時の `Tg`=0 の書き戻し（重大度: 高）

**懸念**: 「ヘルパー自身の範囲検査が `Tg`=0 を拒否し、ファンが手動のまま残るのではないか」。

**調査結果**: 拒否はされない。逆に**書かれてしまう**のが問題だった。

- 旧 `SessionRegistry.restoreOriginalsLocked`（旧 `SessionRegistry.swift:219-245`）は、まず速度系キー（`F<n>Tg`, `F<n>Mn`）を
  記録値に戻し（旧 :220-228）、その**後で**モード系キーを `F<n>Md`=0 にしていた（旧 :229-244）。
- 復元の書込は `client.writeBytes` を直接呼び（旧 :224）、`validateLocked`（旧 :273-317、`Tg` の範囲検査は旧 :304-312）を通らない。
  したがって範囲検査による拒否は起きない。
- 経路: 通常の close（`close(for:)` 旧 :147-159）、クライアント切断（`HelperListenerDelegate` の invalidation/interruption → `release(owner:)` 旧 :171-177）、
  SIGTERM（`main.swift:16-23` → `shutdown()` 旧 :162-168）、死んだ pid の回収（`open` 旧 :66-71）。すべて `endSessionLocked` → 同じ復元処理。
- アイドル時に開始したセッション（記録値 `Md`=0, `Tg`=0）を閉じると、`F<n>Md`=1 のまま `F<n>Tg`=0 を書く＝**手動モードでファン停止を指令**し、
  その後 `Md`=0 を書く。`Md`=0 が 2 回とも失敗すると、ファンは手動・0 RPM のまま残る（負荷が上がっても回らない）。
  `Md`=0 が成功する通常時でも、停止指令が一瞬入る。SMC が `Mn` 未満の手動目標をどう扱うか（拒否／0 RPM で停止／`Mn` に丸め）は未確認で、
  確認のために書くべき値でもない。

**修正**（新 `FanControlXPC/HelperWritePolicy.swift:124` `restore(...)`、`SessionRegistry.swift` は委譲のみ）:

1. `F<n>Mn` を記録値に戻す（許可リストから外したので通常は空）。
2. モード系キーを自動へ（`F<n>Md`=0、`FS! `=記録値から今回立てたビットを落とした値）。各 2 回まで試行。
3. `F<n>Tg` は**このセッションでモード系キーを書いていないファン（target-only）だけ**書き戻し、値は `Mn`〜`Mx` にクランプ。
   `Md`=0 で SMC に返したファンの `Tg` は書かない（自動制御中は SMC が目標値を持つ）。`Md`=0 に失敗したファンの `Tg` も書かず、
   最後に検証済みの目標値（`Mn`〜`Mx` 内）のまま残してログに記録する。

テスト（`Tests/FanControlXPCTests/HelperWritePolicyTests.swift`）: アイドル記録値で `F0Md`,`F1Md`=0 のみ書かれる／
記録値が手動でも `Md`=0／`Md` 失敗時に再試行し `Tg`=0 を書かない／target-only は `Mn` にクランプ／Intel で `FS! ` の自ビットだけ落とし `Tg` を書かない。

## 2. 書込列の途中失敗（重大度: 高）

**調査結果**:

- `FanWriteStrategy.writes(for:)` はモード書込 → 目標書込の順の列を返す（旧 `FanWriteStrategy.swift:118-155`、:154）。
  2 ファンなら `[F0Md←1, F1Md←1, F0Tg, F1Tg]`。
- `FanControlManager.applyTargets`（旧 :624-643）は列を順に送り、途中で例外が出るとそのまま投げる。`appliedTargets`（基準値）は更新しない。
- 例えば `F0Md←1` 成功・`F0Tg` 拒否の場合、ファンは**手動・`Tg` は SMC 最後の値（アイドルなら 0）**。
  ユーザー適用なら `apply` は選択を巻き戻す（旧 :583-587）。巻き戻し先が自動プロファイルだと、次のポーリングの計画は `.automatic`、
  基準値は `nil` なので `changedTargetsOnQueue` の `(.automatic, _)`（旧 :658-659「一度も強制していないファンには触らない」）で**何も書かない**。
  セッションを閉じるまでファンは手動 0 RPM のまま。
- タイムアウト（`HelperClient.call` 旧 :166-176）の場合は接続を invalidate するので、ヘルパー側で復元が走り、この問題は起きない（所見 1 の修正後は安全）。

**修正**（新 `FanControlManager.swift:657` `applyTargets`、:694 `rollBackFailedWrites`、:726）:

- 失敗時、列に含まれていたファンの基準値を消して「unsettled」にする（次のポーリングで閾値に関係なく計画値を書く）。
- セッションがまだ開いていれば、直ちに `FanWriteStrategy.rollbackWrites(afterFailureOf:)`（新 `FanWriteStrategy.swift:186`。強制しようとしていたファンの `F<i>Md←0` / `FS! ` ビット解除）を書く。
  成功すればそのファンの基準値を `.automatic` にし unsettled を外す。元のエラーは従来どおり投げ、`lastError` に入る。
- 補足: ポーリング由来の書込が恒常的に失敗する場合、毎ポーリングで「手動 → 失敗 → 自動へ巻き戻し」を繰り返しうる（`lastError` は表示され続ける）。
  所見 3 の事前検査で既知の拒否理由は無くなったため実害は小さいと判断したが、Phase 4 で `log stream` を見て確認すること。

## 3. `Mn` 未満の目標値（重大度: 中）

- `SafetyPolicy.enforceHardwareMinimum = false` のとき、エンジンは `0...Mx` の目標値を計画する（`FanControlEngine.swift:139-141`）。
  ヘルパーは `Tg` の範囲検査で拒否する（旧 `SessionRegistry.swift:304-312`）が、その時点で `Md`=1 は書込済み → 所見 2 が確定的に起きる。
- **修正**: `FanWriteStrategy` が init 時に各ファンの `F<i>Mn`/`F<i>Mx` を読み（新 `FanWriteStrategy.swift:91`、`FanWriteInfo.rpmLimits`）、
  手動目標が範囲外（±1 RPM）なら列を作る前に `.rpmOutOfRange` を投げる（新 :164）。何も書かれない。
- 値の丸め: `rpm` は `Int`、`flt ` には `Double(rpm)` を Float32 で書く（2^24 以下の整数は正確）。ヘルパーは ±1 RPM を許容（`HelperWritePolicy.rpmTolerance`）。

## 4. 許可リスト・値検査・エンコード（重大度: 中）

- 旧許可リストは `^F[0-9]Tg$`, `^F[0-9]Md$`, `^FS! $`, `^F[0-9]Mn$`（旧 `FanControlHelperConstants.swift:47-52`）。
  アプリは `F<n>Mn` を一度も書かない（`FanWriteStrategy` に `Mn` の書込は無い）が、ヘルパーは受け付けていた。Mac14,9 では `F<n>Mn` は 0x84（書込不可）。
  **修正**: `F<n>Mn` を許可リストから削除。`Ftst` は従来どおり許可外（テストに `Ftst`, `F0Mn`, `F0St`, `F0Dc` を追加）。
- 書込属性: 旧ヘルパーは `SMCKeyInfo.isWritable`（0x40）を見ていなかった。**修正**: `HelperWritePolicy.validate`（新 `HelperWritePolicy.swift:39`、:47）で
  0x40 の無いキーを `7 badRequest`。Intel 機で必要なキーが 0x40 を持たない場合は書込が拒否される（安全側の失敗）。Intel 実機で要確認。
- キー名検査: XPC 入口で 4 文字 ASCII（`SMCKey.init?`）→ 正規表現の完全一致（`isWriteAllowed`）→ 値検査、の順（`HelperService.swift:24-45`）。任意キーは書けない。
- `F<n>Md`: `ui8 ` 1 バイト、0/1 のみ許可。エンコードは `[1]` / `[0]`（`SMCCodec.encode` の ui8 は 1 バイトなのでエンディアン非依存）。
- `F<n>Tg` の `flt `: 読取（`SMCCodec.swift:51-54`）と書込（:99-103）はどちらもリトルエンディアン Float32。
  2317 → `00 d0 10 45`、6800 → `00 80 d4 45` がダンプの `F0Mn`/`F0Mx` とバイト一致することをテストで確認（`testMac14_9FloatEncodingMatchesDump`、`testMac14_9UsesModeKeyAndReadsLimits`）。
  ヘルパーの値検査も同じ `SMCCodec.decode` を使うので解釈は一致する。
- Intel 分岐: スタイル判定は `F<i>Md` の有無が先（`FanWriteStrategy.swift` init）。Mac14,9 は `FS! ` も無いので常に `.modeKey`。Intel 分岐は通らない（テストで確認）。
- 検証ロジックを `FanControlXPC.HelperWritePolicy`（プラットフォーム非依存）へ移し、ヘルパー実行ファイルからは委譲だけにした。これにより単体テスト可能になった
  （`FanControlXPC` が `FanControlCore` に依存するよう `Package.swift` を変更。`FanControlHelperErrorCode` を macOS 限定ブロックの外へ移動。いずれも追加的変更）。

## 5. ヘルパーの異常終了（重大度: 中）

| 事象 | 挙動 | 備考 |
|---|---|---|
| アプリ ⌘Q | `willTerminate` → 全ファン自動 → close（最大 2 秒）。間に合わなくても接続断でヘルパーが復元 | 所見 6 で順序を補強 |
| アプリ `kill -9`／クラッシュ | ヘルパーの invalidation ハンドラ → `release` → 復元（`HelperListenerDelegate.swift:19-26`） | 修正 1 により `Md`=0 のみ |
| ヘルパー SIGTERM（unregister・シャットダウン） | `shutdown()` → 復元 → exit | |
| **ヘルパー SIGKILL／クラッシュ／jetsam** | **復元されない**。ファンは手動・最後の目標値（`Mn`〜`Mx` 内）のまま | ソフトウェアでは防げない |
| クライアント側タイムアウト（8 秒） | 接続を invalidate → ヘルパーが（応答可能になった時点で）復元 | ヘルパーが固まったままなら復元されない |
| スリープ | SMC が自動に戻す可能性。復帰 5 秒後に再適用（既定）または close | 再適用が途中失敗しても修正 2 で巻き戻し |
| 再起動・SMC リセット | SMC が自動制御で起動する（`F<n>Md` は永続化されない想定） | 最終的な逃げ道 |

- ヘルパー異常終了後、アプリ側は interruption で `isSessionOpen=false` になり、ポーリングは SMC から読んだモード（手動）を表示する。
  旧 `restoreDefaultControl`（旧 :468-484）はセッションが無いと何も書かなかった。
  **修正**（新 `FanControlManager.swift:492-` ）: セッションが無くても SMC が手動モードのファンを報告していれば、ユーザー操作としてセッションを開いて自動を書き、閉じる。
  注意: FanFi など他のツールが強制しているファンも自動に戻す（ユーザーが明示的に「自動制御に戻す」を押した場合のみ）。
- launchd plist は `KeepAlive` なし（オンデマンド起動）。ヘルパーがクラッシュしても次の接続で再起動されるが、起動時に過去の状態を戻す処理は無い
  （他ツールの制御を壊さないため意図的に入れていない）。
- **ソフトウェアで直せないもの**（文書化）: ヘルパーの SIGKILL・カーネルパニック・電源断・ヘルパーのハング中のファン状態。
  いずれも「自動制御に戻す」（ヘルパー応答時）または再起動で SMC 制御に戻る。Apple Silicon の SMC リセットは「シャットダウン → 30 秒待って起動」。

## 6. 終了時の close（重大度: 低）

旧 `restoreOnTermination`（旧 :894-905）は自動化の列をシリアライザ経由で書いた後、`closeSession` をシリアライザの**外**で呼び、世代も進めていなかった。
`pollQueue` 上で計画済みのポーリング書込が自動化と close の間に入りうる（最終的にはヘルパーの復元で自動に戻るので実害は小さい）。
**修正**（新 :973-）: 先に `applyGate.advance()`（`pollQueue` はブロックされていない）、close もシリアライザ経由。

## 7. 同一 pid の再接続（重大度: 低）

タイムアウト後にクライアントが新しい接続で `openSession` すると、旧接続の invalidation がヘルパーに届く前なら旧オーナー（同じ pid、生存）と判定され `notSessionOwner` になっていた（旧 `SessionRegistry.swift:62-72`）。
**修正**（新 `SessionRegistry.swift:63`）: 同じ pid の別接続なら旧セッションを終了（復元）してから引き渡す。

## 8. 書込順序（情報）

- 適用時は `F<n>Md←1` → `F<n>Tg←rpm`（全ファンのモード → 全ファンの目標）。自動モード中に `Tg` を書いても SMC が上書き・拒否する可能性があるので、
  この順序なら「自動中の `Tg` 書込が効く／効かない」のどちらでも最終状態は同じ。
- `Md`=1 と `Tg` の間（XPC 2 往復、数 ms）は `Tg` が SMC の最後の値（アイドル 0、負荷時は SMC が決めた値）のまま。正常時は直後に上書きされ、
  失敗時は修正 2 で `Md`=0 に戻す。逆順（`Tg` → `Md`）は自動中の `Tg` 書込を SMC が拒否する機種で適用自体が失敗するため採用しない。
- 未確認（実機でのみ判明）: `Md`=1 で `Tg`=0 のときファンが止まるか、SMC が手動時に `Mn` を強制するか、`Md` がスリープで 0 に戻るか。

## 9. タイムアウト・世代ゲート（情報）

- `restoreDefaultControl`: メインで選択を自動に → `pollQueue` で世代を進める → シリアライザで全自動 → close。メインで旧プロファイルから
  スナップショットしたポーリングは世代を進める処理より先に `pollQueue` に並ぶので古い世代を持ち、シリアライザで捨てられる。
  既にシリアライザで実行中の書込は自動化の前に完了する。close 後に残った書込は `sessionNotOpen` で送られない。→ 「自動制御に戻す」後に古い目標値が書かれる経路は見つからなかった。
- タイムアウト時に XPC の応答だけ遅れて書込自体は成功していた場合も、接続断 → ヘルパーの復元がその書込の後に（ロックで直列化されて）走るので最終状態は自動。

## 10. 緊急オーバーライド・スリープ（情報）

- 緊急オーバーライド（95 °C で全ファン最大）は**セッションが開いている間だけ**書く。緊急中に「自動制御に戻す」を押すと SMC の自動制御に戻り、
  オーバーライドは書かれなくなる（Apple Silicon の SMC 自身の熱制御とスロットリングが働く）。設計どおりだが UI で注意表示を検討（未決）。
- スリープ復帰: 既定では 5 秒後に `force` で再適用（`Md`=1 も書き直す）。`reapplyProfileAfterWake=false` なら close。

---

## 初回書込の手順（人間が実機で行う）

前提: Xcode でアプリ＋ヘルパーを同じ Team ID で署名し、ヘルパー登録・承認まで済んでいること（integration.md §1〜§4）。

1. **監視を用意する**（別ターミナル 2 つ）:
   ```sh
   cd FanControl && swift run fanfi-probe --watch 1          # F0Md / F0Tg / F0Ac を 1 秒ごとに
   log stream --level debug --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'
   ```
   書込前の状態を記録: `F0Md`=0, `F0Tg`=0, `F0Ac`=0（アイドル）。
2. **逃げ道を先に確認する**: 手動で何かを書く前に、「自動制御に戻す」ボタンが押せること、`sudo launchctl kill SIGTERM system/com.example.dynamicnotch.DynamicNotch.fanfi`
   でヘルパーを止められることを確認しておく。最後の手段は **再起動**（または Apple Silicon の SMC リセット = シャットダウンして 30 秒後に起動）。
3. **最初の書込は 1 ファン・控えめな固定値**: 新規プロファイルで Fan 1（`F0`）だけ「固定 3000 RPM」、Fan 2 は自動。適用する。
   - 期待: ログに `F0Md` → `F0Tg` の順の書込、`fanfi-probe` で `F0Md`=1、`F0Tg`=3000、`F0Ac` が数秒で 3000 付近へ。`F1Md`=0 のまま。
   - **中止条件**: `F0Md`=1 なのに `F0Tg` が 0 のまま／`F0Ac` が 10 秒以上 0 のまま／`F0Ac` が 3000 から大きく外れて安定しない／ログに `badRequest` / `smcError`。
     → すぐ「自動制御に戻す」。
4. **自動に戻す**: 「自動制御に戻す」。期待: `F0Md`=0。`F0Tg` はヘルパーが書き戻さず SMC が自分で決める（アイドルなら数十秒以内に `F0Ac` が 0 へ）。
   ログに `Failed to restore` が無いこと。
5. 3〜4 が期待どおりなら、2317（`Mn`）と 6800（`Mx`）、2 ファン同時、プロファイル切替、⌘Q、`kill -9`（アプリ）を integration.md §6 Phase 4 の順に。
6. **アプリから戻らない場合**（ヘルパーが応答しない等）:
   - ヘルパーを SIGTERM（上記 `launchctl kill SIGTERM`）→ ヘルパーが `F<n>Md`=0 を書いて終了する。
   - それでも `F<n>Md`=1 のままなら再起動する。（SMC に直接書くツールで `F<n>Md`=0 を書く方法もあるが、本プロジェクトのヘルパー以外の書込は推奨しない。）
7. 結果（ログ・`fanfi-probe` 出力）を `docs/verification/` に保存し、integration.md §6 Phase 4 のチェックに反映する。
   特に「`Md`=0 だけで `Tg`/`Ac` が SMC 制御に戻るか」「`Md`=1 直後 `Tg` 書込前の挙動」「スリープ後の `F<n>Md`」を記録する。

## 人間の判断・実機確認が必要な事項

- 上記「初回書込の手順」の実施（SMC 書込はユーザーの明示的な確認のもとで 1 ステップずつ）。
- `Md`=0 だけで自動制御に戻るか（`Tg` を書き戻さない設計の前提）。戻らない場合は復元で `Tg` を `Mn` にクランプして書く等の再検討が必要。
- 書込ビット `0x40` 検査が Intel 機で必要なキー（`F<n>Tg`, `FS! `）を誤って拒否しないか（Intel 実機が必要）。
- ヘルパー異常終了時の孤立した手動状態の回収（`restoreDefaultControl`）が他ツール（FanFi）の制御も解除する点の扱い（UI 注意表示など）。
- 緊急オーバーライド中の「自動制御に戻す」に注意表示を出すか。
- `Ftst`: Mac14,9 では不要（キーが無い）。他機種では未決のまま。
