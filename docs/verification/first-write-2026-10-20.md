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

## 未確認のまま残ること

- `Md`=1 かつ `Tg`=0（Mn 未満）の挙動（ヘルパーが範囲外として拒否するため通常は起きない）
- 手動モードで SMC が `Mn` を強制するか
- スリープ／復帰で `Md` が戻るか（integration.md §6 Phase 5）
- `kill -9` 時のヘルパーによる復元、ヘルパー SIGTERM 時の復元（§6 Phase 4）
- センサー連動プロファイル、緊急オーバーライド（§6 Phase 4/5）
