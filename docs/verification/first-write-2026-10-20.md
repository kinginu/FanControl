# 初回 SMC 書込の記録（2026-10-20、Mac14,9 / macOS 26.5.2）

> **Historical record (2026-10-20, in Japanese).** It describes the code as it was on that date; the implementation has moved on since (file names, line numbers and some behaviour differ). Current behaviour: [kit.md](../kit.md), [helper.md](../helper.md). Summary of all hardware results: [SUMMARY.md](SUMMARY.md).
>
> **Paths:** this record predates the standalone repository. `FanControl/…` is now the repository root; the host glue it mentions (`FanControl/DynamicNotchIntegration/…`, `PATCHES.md`, `Tools/IntegrationTypeCheck`) has since moved to the DynamicNotch app repository (`DynamicNotchApp/Sources/FanControlGlue/`, built directly by the app).

構成: HelperSmokeApp（ad-hoc 署名、Debug）+ 手動インストールモードのヘルパー（`Support/manual-install/install.sh`）。
監視: `fanfi-probe --watch 1`（読み取り専用）と `/usr/bin/log stream`（`category == "fancontrol-helper"`）。
各ステップはユーザーがボタンを押し、Claude がログと probe で確認した。

## 前提状態

ビルド直後で筐体が温かく、アイドル 0 RPM ではなく自動制御で回っていた:
Fan 1 current ≈ 2500 / target ≈ 2495、Fan 2 current ≈ 2690 / target ≈ 2695、両方 automatic。

## ステップ 1: Restore automatic（セッション無し）

ヘルパーへの接続もログも発生せず、ファンは変化なし。`F<n>Md` = 0 のときは何もしない（`restoreDefaultControl` の孤児回復は手動モードのファンがある場合のみ）という設計どおり。

## ステップ 2: Fan 1 → 3000 RPM（固定）

- helper: `Accepted connection 3 from pid 71765` → `Session opened by pid 71765 (connection 3)`（09:34:31）
- probe: 最初のサンプルで `Fan 1 current 2800 / target 3000 / manual(3000)`（上昇中）、以後 2996〜3021 で安定。26 サンプル（約 28 秒）継続。
- Fan 2 は automatic のまま（target 2683）。
- 結論: Apple Silicon の書込順序 `F0Md`=1 → `F0Tg`=3000 が効く。`F0Ac` が目標に追随する。

## ステップ 3: Restore automatic（セッション中）

- helper: `Session of pid 71765 closed after 28s`（09:34:59）
- probe（遷移前後、1 秒間隔）:

```
Fan 1  3021  3000  manual(3000)
Fan 1  2996  2468  automatic      ← Md=0 直後。target は SMC 自身の値（2468）に即座に戻る
Fan 1  2996  2468  automatic
Fan 1  2582  2466  automatic
Fan 1  2468  2464  automatic      ← 約 3 秒で current が SMC の target に収束
…
Fan 1  2317  2317  automatic      （約 2 分後、冷えて最小回転へ）
```

- 結論: **`F<n>Md` = 0 を書くだけで SMC に制御が戻り、`F<n>Tg` は SMC が自分で更新する**。
  復元時に `Tg` を書き戻す必要はない（pre-write-review の HIGH 1 の修正方針が実機で裏付けられた）。
  `Tg` を書き戻さないので、アイドル時のスナップショット `Tg`=0 < `Mn` の問題も生じない。

## テスト 1a: アプリを `kill -9`（セッション中）

- 09:42:14 Fan 1 を固定 3000 RPM（`Session opened by pid 71765 (connection 3)`）
- 09:43:04 `kill -9 71765` → helper: `Connection 3 invalidated` → `Owner pid 71765 went away; releasing session` → `Session closed after 50s`
- probe: 09:43:06 に `Fan 1 target 3000 → 2317 / automatic`（約 2 秒で復元）、09:43:08 current 2327、以後 2317 で安定
- 結論: クライアント消失時のヘルパー側復元は動作する（helper.md §5）

## テスト 1b: ヘルパーに SIGTERM（セッション中）

新ビルドのスモークアプリ（cdhash `fd6b97f4…`、`install.sh` 再実行で pin 更新、ヘルパーは bootout → オンデマンド再起動 pid 82776）。

- 09:45:28 Fan 1 を固定 3000 RPM（`Session opened by pid 82208 (connection 1)`）
- 09:46:02 `sudo launchctl kill SIGTERM system/…fanfi` → helper: `SIGTERM received` → `Helper shutting down; ending session and restoring fans` → `Session of pid 82208 closed after 34s` → 終了コード 0
- probe: 直後に `Fan 1 automatic / target ≈ 2370`（SMC の値）
- launchd: `runs = 1`、`last exit code = 0`、`state = not running`
- 結論: SIGTERM 時の復元は動作する。
- 備考: セッション中に 1 サンプルだけ `Fan 1 current 3964 (target 3000)`、`Fan 2 current 4020 (target 2606)` と両ファンが同時に跳ねた読取があり、次のサンプルで戻った。P コア最大は 89.7 °C（警告閾値 90 °C 直前）。読取の揺れか SMC の一時的な介入かは未確認。

## テスト 2: センサー連動プロファイル（`agg:cpu` 45→75 °C、全ファン）

スモークアプリ（cdhash `22821e9c…`、「All fans → 6000 RPM」ボタン追加版）。別エージェントの `xcodebuild` が走っており CPU 最大 92.9 °C の状態で開始。

- 09:47:54 `Session opened by pid 84347 (connection 1)` → 数秒で両ファン `manual(6800)`、current 6826 / 6832（75 °C 以上は max）
- CPU 最大の推移: 92.9 → 86.6（+10 s）→ 83.4（09:49:21）→ 76.7（09:49:37）→ 74.4 °C（09:49:49）
- 74.35 °C で target が 6800 → **6702** に低下（線形補間の計算値 2317 + (74.35−45)/30 × 4483 ≈ 6703 と一致）。以後ポーリングごとに温度に追随。
- 結論: 集約センサー `agg:cpu` に紐づくセンサー連動モードが実機で動作し、エンジンの線形カーブどおりに target が更新される。

## テスト 3: 緊急オーバーライド（閾値を一時的に 55 °C に下げて発火）

スモークアプリの「Emergency test」ボタンで `safetyPolicy.emergencyTemperature` = 55、`highTemperatureAlert` = 50（メモリ上のみ）。CPU 最大は 75〜85 °C 程度。

| 時刻 (JST) | 操作 | probe |
|---|---|---|
| 09:52:50 | Fan 1 → 3000（セッション開始） | F1 3000 manual / F2 2502 automatic |
| 09:53:12 | 閾値を 55 °C に | **F1 6800 manual / F2 6800 manual**（automatic だった Fan 2 も強制最大） |
| 09:56:11 | 既定閾値（95 / 90 / 5）に戻す | F1 3000 manual / F2 automatic（ヒステリシス 90 °C 以下を満たし即解除、プロファイル目標に復帰） |
| 09:56:25 | Restore automatic | 両方 automatic、セッション終了（`closed after 213s`） |

- 結論: 書込セッション中の緊急オーバーライドは全ファン（自動制御のファンを含む）を最大に強制し、解除後は元の目標に戻る（`FanControlEngine.plan` の emergency 分岐と `AlertEvaluator` のラッチ）。
- 備考: 09:56:11 の時点で SMC の自動目標は 0（筐体が冷えてアイドル）だった。

## テスト 4: スリープ／復帰（書込セッション中）

1 回目（10:00:40）は `caffeinate -is`（ユーザーの昨日のシェル由来、`-s` = AC 時のシステムスリープ禁止）のため DarkWake 3 秒で復帰し、スリープ不成立。
2 回目は蓋を閉じて実施（`Clamshell Sleep`、バッテリー駆動）: 10:06:42 に一度 DarkWake（45 秒）、10:07:27 → 10:08:30 の 63 秒間が本当のスリープ（probe にも 61 秒の空白）。

probe（UTC、1 秒間隔。ヘルパーの書込ログは debug レベルで永続化されないため、誰が書いたかはログからは判別できない）:

```
01:06:37  F1 3000 manual(3000) | F2 0 automatic     ← Fan 1 → 3000（ユーザー操作）
01:06:42  F1 6800 manual(6800) | F2 6800 manual(6800)  ← DarkWake の瞬間。アプリの復帰処理が有効プロファイル（センサー連動）を再適用したとみられる
01:07:03  F1 3000 manual(3000) | F2 0 automatic     ← Fan 1 → 3000（ユーザー操作）
（01:07:28 〜 01:08:29 スリープ、サンプル無し）
01:08:29  F1 0 manual(0)       | F2 0 manual(0)     ← 復帰直後: Md=1 のまま Tg=0（両ファン停止・手動モード）
01:08:32  F1 0 automatic       | F2 0 automatic     ← 約 3 秒後に Md=0
01:08:35  F1 6800 manual(6800) | F2 6800 manual(6800)  ← 復帰 5 秒後にプロファイル再適用（reapplyProfileAfterWake 既定 ON）
```

所見:

- **スリープをまたぐと SMC は `F<n>Tg` を 0 にリセットするが `F<n>Md` = 1 は保持する。** 復帰直後の数秒間、ファンは「手動モードで目標 0」= 停止状態になる。
  今回は約 3 秒で `Md`=0、約 5 秒で再適用されたが、この間の書き手（アプリの復帰処理か SMC か）はログに残っていない。
- 復帰 5 秒後の再適用は動作した（`FanControlManager.reapplyProfileAfterWake`）。
- Fan 2 は復帰直後 `manual(0)` になっており、スリープ前に automatic だったファンまで Md=1 で起きている（直前の 6800 強制の名残か、SMC が全ファンの Md を揃えるのかは未確認）。
- **要対応（安全性）**: 復帰直後の「Md=1 / Tg=0」を数秒放置するのは避けたい。候補: (1) ヘルパー自身が `NSWorkspace.didWakeNotification`／IOKit の電源通知を監視し、復帰時に即座にセッション中のファンへ最後の目標値を再書込するか `Md`=0 に戻す、(2) アプリ側の 5 秒待ちを撤廃し、復帰通知で即座に再適用する、(3) ポーリングで「Md=1 かつ Tg < Mn」を異常として即再書込する（現状の unsettled 機構の拡張）。
- **対策（2026-10-20 実装、同日の再テストで合格。下記「テスト 4 再テスト」）**: 候補 (1)〜(3) をすべて実装した。ヘルパー: `Sources/FanControlHelper/PowerObserver.swift`（IOKit 電源通知）＋ `SessionRegistry.prepareForSleep` / `recoverAfterWake`、判断は `Sources/FanControlXPC/PowerTransitionPolicy.swift`（スリープ前に `Md`=0 で返却、復帰時 0/1/3 秒で再適用、記録の無い手動ファンは `Md`=0）。アプリ: `FanControlManager.handleWake`（即座・2 秒・5 秒で再適用）と `Sources/FanControlKit/UnsettledFanDetector.swift`（ポーリングで「手動かつ Tg < Mn」等を検出）。手順と期待パターンは `docs/integration.md` §6 Phase 5、ログは `docs/helper.md` §5「スリープ／復帰」。

## テスト 4 再テスト: スリープ／復帰の安全策（2026-10-20 11:22–11:26）

ヘルパー（`PowerObserver` + `PowerTransitionPolicy`）とアプリ（復帰即再適用 + `UnsettledFanDetector`）の対策入りビルド（アプリ cdhash `f199ad2c…`）。Fan 1 を固定 3000 RPM にしてから蓋を閉じ、211 秒スリープ（11:22:44 → 11:26:15、probe の空白 209 秒）。

| 時刻 | 事象 |
|---|---|
| 11:22:24 | app: `System will sleep; poll writes suspended` |
| 02:22:26Z | probe: Fan 1 が manual(3000) → **automatic**（ヘルパーがスリープ前に `Md`=0 で SMC に返した） |
| 11:26:15.175 | app: `Woke with a session open: re-applying the active profile at 0.0s, 2.0s, 5.0s` |
| 11:26:15.205 | helper: `Power: system has powered on; wake recovery at 0.0s, 1.0s, 3.0s` |
| 02:26:14Z | probe（復帰後最初の 1 サンプル）: **両ファン manual(0)**。helper の観測は `F0 Md=3 Tg=0, F1 Md=3 Tg=0` |
| 11:26:15.772 | app: `Unsettled fan(s) detected, rewriting: F0 manual=true Tg=0 applied=manual(rpm: 3000), F1 manual=true Tg=0 applied=automatic` |
| 11:26:16.009 | helper: `wake recovery 1/3: … wrote F1Md=0, F0Tg=3000` |
| 11:26:17.027 | helper: `wake recovery 2/3: observed F0 Md=0 Tg=0, F1 Md=0 Tg=0; wrote F0Md=1, F0Tg=3000` |
| 02:26:16Z | probe: F1 manual(3000) / F2 automatic。current は 1697（+3 s）→ 2873 → 3003（+6 s） |
| 11:26:19.462 | helper: `wake recovery 3/3: fans already match (F0 Md=1 Tg=3000, F1 Md=0 Tg=0)` |

所見:

- 復帰後に `manual(0)` が出たのは **1 サンプルのみ**（合格基準は 2 連続で不合格）。約 2 秒でプロファイルが復元され、約 6 秒で回転数が追随した。
- **新事実**: 復帰直後の SMC は、スリープ前に `Md`=0 で返していたにもかかわらず両ファンを `F<n>Md` = **3**（1 でも 0 でもない）/ `Tg`=0 で起こし、1〜2 秒後に自ら `Md`=0 に戻す。つまり復帰直後の「手動・目標 0」は SMC 側の過渡状態で、こちらの書込由来ではない。`PowerTransitionPolicy` は非 0 の `Md` を手動扱いするため、1/3 で `Md`=3 のまま `Tg` を書き（効かなかった）、2/3 で `Md`=0 を観測して `Md`=1 → `Tg` を書き直している。想定どおりリトライで吸収できた。
- 対策前（テスト 4）は再適用まで約 5 秒だったものが約 2 秒に短縮され、ヘルパー単独でも（アプリが応答しなくても）復元される。

## 未確認のまま残ること

- `Md`=1 かつ `Tg`=0（Mn 未満）の挙動（ヘルパーが範囲外として拒否するため通常は起きない）
- 手動モードで SMC が `Mn` を強制するか
