# 初回 SMC 書込の記録（2026-10-20、Mac14,9 / macOS 26.5.2）

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

## 未確認のまま残ること

- `Md`=1 かつ `Tg`=0（Mn 未満）の挙動（ヘルパーが範囲外として拒否するため通常は起きない）
- 手動モードで SMC が `Mn` を強制するか
- スリープ／復帰で `Md` が戻るか（integration.md §6 Phase 5）
