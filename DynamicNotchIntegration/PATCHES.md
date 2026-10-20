# DynamicNotch 本体ソースへの手作業パッチ

このディレクトリの `*.swift` はそのまま DynamicNotch ターゲットに追加できる「ドロップイン」ファイルだが、
以下は既存ファイルの switch / enum / 起動処理に手を入れる必要があり、ドロップインでは提供できない
（ホストアプリごとに行・シグネチャが異なるため）。
各項目のコードは「追加する断片」であり、周辺の既存コードは実ソースに合わせて読み替えること。

前提: 変更する各ファイルの先頭に必要に応じて次を追加する。

```swift
import FanControlCore
import FanControlKit
```

設定の保存はドロップイン `FanControlSettingsStorage.swift`（`SettingsStore`、2026-10-20 に sindresorhus/Defaults から置換。
保存形式は Defaults と同一でキー名も不変）を使う。import は不要（同じアプリモジュール）。対応:
`Defaults[.x]` → `SettingsStore[.x]`、`@Default(.x)` → `@StoredSetting(.x)`、`Defaults.updates(.x)` → `SettingsStore.updates(.x)`、
`extension Defaults.Keys { static let x = Key<T>("x", …) }` → `extension StoredKeys { static let x = Key<T>(SettingKey.x, …) }`、
`Defaults.Serializable`（Codable 構造体）→ `CodableStoredValue`。

---

## (a) `NookWidget.swift` — ウィジェット種別 `fanControl` を追加（tag 8）

```swift
enum NookWidget: … {
    // 既存 case …
    case timer
    case fanControl            // tag 8（新規・末尾に追加して既存の永続化値を壊さない）

    var icon: String {
        switch self {
        // …
        case .fanControl: return "fan"
        }
    }

    var name: String {
        switch self {
        // …
        case .fanControl: return "Fan Control"     // Localizable.strings にキーあり
        }
    }

    var gridSizeType: NookGridSizeType {
        switch self {
        // …
        case .fanControl:
            // 2x1 = .medium (100 pt) / 2w×1h = .doubleWide (250 pt)
            return SettingsStore[.fanControlWidgetSettings].gridSize == .doubleWide ? .doubleWide : .medium
        }
    }

    var prefs: WidgetPrefs {
        switch self {
        // …
        case .fanControl: return SettingsStore[.fanControlWidgetSettings]
        }
    }

    // rawValue / init?(rawValue:) を手書きしている場合:
    //   case .fanControl: return "fanControl"
    //   case "fanControl": self = .fanControl
}
```

`prefs` が `WidgetPrefs` を返すため、設定型に準拠を追加する（`WidgetPrefs` / `Preferences` の実際の要件に合わせること。
`NookSettings.widgetsWidthInPoints` は `prefs.gridSizeType.rawValue * 50` を使っている）:

```swift
extension FanControlWidgetSettings: Preferences, WidgetPrefs {
    var gridSizeType: NookWidget.NookGridSizeType {
        gridSize == .doubleWide ? .doubleWide : .medium
    }
}
```

`FanControlWidgetSettings.GridSizeChoice` の rawValue（medium = 2, doubleWide = 5）は `NookGridSizeType` と一致させてある。

`Preferences` が `init()` を要求する場合（`DynamicNotchApp/` の `Preferences` はそう）、`FanControlWidgetSettings` の
全引数既定値付き `init(gridSize:…)` ではその要件を満たさないので、同じ拡張に `init() { self.init(gridSize: .medium) }` を足す
（2026-10-20、`DynamicNotchApp/Sources/NookWidget.swift` で実施）。

## (b) Nook グリッドのウィジェット → View 振り分け

参照ソースでは振り分け箇所を特定できていない（`TimerWidgetView()` / `MediaPlayerWidgetView()` を返している
switch を検索すること）。`DynamicNotchApp/` では振り分けが無かったので
`Sources/Support/NookWidgetGrid.swift` の `NookWidgetContentView` として新設し、そこに追加した。1 行追加する:

```swift
switch widget {
// …
case .timer:      TimerWidgetView()
case .fanControl: FanControlWidgetView()
}
```

`RootView` が各ウィジェット設定を `.environment(\.xxxWidgetSettings, …)` で配っているが、Fan Control の View は
`@StoredSetting(.fanControlWidgetSettings)` を直接読むので environment キーの追加は不要。

### (b-2) Nook の表示／非表示 → 監視の一時停止（「Nook 非表示中は一時停止」、2026-10-20 追加）

一時停止はホストの Nook の開閉で駆動する。ウィジェットの `onAppear` / `onDisappear` だけに頼ると、ウィジェットをグリッドから外した・
Nook を閉じたまま設定を開いた場合に一時停止が解けなくなる（逆に、ウィジェットを置いていないと一時停止がかからない）。
Nook が開いた／閉じたことが分かる箇所（NotchViewModel の状態が `.nook` に入る／出る箇所、または `RootView` の
`.onChange(of: notchState)`）で次の 1 行を呼ぶ。メインスレッドから呼ぶこと（`FanControlNookVisibility` は `@MainActor`）:

```swift
// Nook が開いた: isVisible = true / 閉じた（ノッチに戻った・非表示）: isVisible = false
FanControlNookVisibility.nookVisibilityChanged(isVisible: notchState == .nook)
```

`FanControlNookVisibility`（`FanControlSettingsView.swift`）は機能が有効かつ `pauseWhenNookHidden` のときだけ
`FanControlManager.shared.setMonitoringPaused(!isVisible)` を呼び、それ以外は一時停止を解除する。補足:

- ウィジェット自身の `onAppear`（解除）/ `onDisappear`（一時停止）はホストのフックが無い場合の代替として残している。フックがあれば
  Nook を開くたびに確実に解除される。`onDisappear` の一時停止は、表示中の Fan Control ウィジェットが 0 個になったときだけ
  （`FanControlWidgetPresence.visibleCount`。複数画面で片方の Nook を閉じても、もう片方が開いていれば止めない。Nook の中身は
  フェードで消えるので `onDisappear` はフックより後に走る）、かつ `FanControlWidgetPresence.hostReportsVisibility` が false のとき
  だけ行う（2026-10-20 レビュー指摘）。ホストのフックを入れたら `nookVisibilityChanged` の先頭で
  `FanControlWidgetPresence.hostReportsVisibility = true` を立てること（未実施: `FanControlSettingsView.swift` の担当）。
  プレビュー描画（`previewProfile` / `previewGridSize` 指定時）は数に入れない。
- 設定ペイン（`FanControlSettingsView`）は表示中 `FanControlManager.setLiveDataHold(true, for:)` で一時停止を保留し（Nook が閉じていても
  通常間隔でポーリング）、閉じると保留を外す。ホストの要求（`isMonitoringPaused`）は書き換えないので、元の状態を覚えて戻す必要は無い。
- 一般設定で「Nook 非表示中は一時停止」をオフにする（または機能を無効にする）と、`FanControlAlertCoordinator.syncManagerSettings()` が
  一時停止を解除する。

## (c) `WidgetsSettingsTabView.swift` — ウィジェット別設定画面

```swift
settings: { widget in
    switch widget {
    // …
    case .timer:
        TimerWidgetSettingsView()
    case .fanControl:
        FanControlWidgetSettingsView()
    default:
        BlankView()
    }
}
```

## (d) 設定ウィンドウに「Fan Control」タブを追加

ホストの設定ウィンドウは SwiftUI 標準の `Settings` シーン（`App` の `body` に `Settings { … }`）で、中身はペインごとに
1 タブの `TabView`（`.tabItem { Label(タイトル, systemImage: SF Symbol) }`。macOS がツールバー型のタブとして表示する）である前提。
そこへ Fan Control のタブを 1 つ足す。ドロップインファイル側はどれも sindresorhus/Settings に依存しない（2026-10-20 に撤去。
各タブは標準の `Form` + `.formStyle(.grouped)`）。

```swift
// ペイン ID（AppKit 側から特定のタブを開くため。ホストが別の選択型を使うならそれに合わせる）
extension AppSettings.PaneIdentifier {
    static let fanControl = Self("fanControl")
}

// ホストの設定 TabView に追加（About の直前）:
TabView(selection: $navigation.pane) {
    // … 既存のタブ …
    FanControlSettingsView()
        .frame(width: 760, height: 640, alignment: .top)   // ホストが全タブに付けている固定サイズ
        .tabItem { Label("Fan Control", systemImage: "fan") }
        .tag(AppSettings.PaneIdentifier.fanControl)
    // … About …
}
```

`FanControlSettingsView` は全サブタブ共通の固定サイズ（`FanControlSettingsView.contentSize` = 740×600 pt。サブタブ切替でウィンドウが伸縮しない。
一般タブ・プロファイル編集・センサー表は内部でスクロール）を持つ。ホスト側で各タブを固定フレームで包む場合はそれ以上にする
（`Settings` シーンのウィンドウはタブの内容サイズに合わせて伸縮するので、全タブに同じ固定フレームを付けると切替で大きさが変わらない）。

`DynamicNotchApp/` では、`App/DynamicNotchApp.swift` が `Settings { SettingsRootView() }` を宣言し、
`Sources/SettingsRootView.swift` が `AppSettings.PaneIdentifier`（旧 sindresorhus/Settings の API と同じ綴り）、選択中のタブ
（`SettingsNavigation.shared.pane`、UserDefaults に保存）、各タブの 760×640 固定フレームを持つ。Fan Control タブは
`#if canImport(FanControlKit)` で About の直前に入り、`.fanControl` は `Sources/Support/FanControl-Patches.swift` で定義している。
AppKit 側からは `WindowsManager.shared.showSettings(pane: .fanControl)` で開く（選択を設定してから標準の設定ウィンドウを開く）。

**履歴（sindresorhus/Settings 時代、2026-10-20 まで）:** 以前は `Settings.Pane` / `Settings.PaneHostingController` を
`SettingsWindowController(panes:)` に登録していた。sindresorhus/Settings の `enum Settings` は SwiftUI の `Settings` シーン型と
名前が衝突するため、`import enum Settings.Settings` か `typealias AppSettings` が必要だった（Swift 6 モードでは
`@preconcurrency import Settings` も）。標準の `Settings` シーンに移行したのでこの回避策は不要になった。

## (e) `AppDelegate.applicationDidFinishLaunching` — 監視の自動開始と警告コーディネータ

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    setupMenu()
    _ = VolumeAndBrightnessListener.shared

    // Fan Control
    // コーディネータを先に生成する。生成時に一般設定の pollingInterval / reapplyProfileAfterWake を
    // FanControlManager に同期し、以後も設定変更のたびに同期する。
    FanControlAlertCoordinator.shared.onAlertChange = { alert in
        // ActiveLiveActivitiesManager のアプリ内インスタンス（実ソースでの保持場所に合わせる）
        if alert != nil {
            activeLiveActivitiesManager.insertSync(.fanAlert)
        } else {
            activeLiveActivitiesManager.removeSync(.fanAlert)
        }
    }
    // FanControlHelperConstants.teamIdentifierPlaceholder を実 Team ID に置換していない場合のみ必要
    // （アプリがヘルパーの署名に要求する Team ID。docs/integration.md §4。アドホック署名の手動インストール
    // （個人利用）モードでは使われず、インストール済みヘルパーの cdhash が要件になる。docs/helper.md §6）:
    // FanControlManager.shared.clientTeamID = "<TeamID>"
    let fanSettings = SettingsStore[.fanControlGeneralSettings]
    if fanSettings.isEnabled && fanSettings.autoStartMonitoring {
        FanControlManager.shared.startMonitoring()
    }
}
```

`isEnabled` の既定値は `false`。ユーザーが設定で明示的に有効化するまでファン制御は一切動かない（設計書 §5.5）。

## (f) `LiveActivity` enum と `LiveActivityView`

```swift
enum LiveActivity: … {
    // 既存 case …
    case fanAlert

    var icon: String { switch self { /* … */ case .fanAlert: return "fan" } }
    var id: String   { switch self { /* … */ case .fanAlert: return "fanAlert" } }
    var name: String { switch self { /* … */ case .fanAlert: return "Fan Alert" } }

    init?(rawValue: String) {
        switch rawValue {
        // …
        case "fanAlert": self = .fanAlert
        default: return nil
        }
    }
}
```

`LiveActivityView`（ノッチ左右に表示するコンテンツの分岐）:

```swift
case .fanAlert:
    // 左側
    FanControlAlertView(part: .leading)
    // 右側
    FanControlAlertView(part: .trailing)
    // 片側だけの場所では FanControlAlertView()
```

`DynamicNotchApp/` では `LiveActivityView` を生成する箇所自体が未実装のため、(f) は適用済みだが表示は未確認（2026-10-20）。

一時的な展開（バッテリー低下と同じ演出）を使う場合は、`"DynamicNotchBatteryLowTransient"` を購読している箇所に
`FanControlAlertCoordinator.transientNotificationName`（= `"DynamicNotchFanAlertTransient"`）の購読を並べる。

Live Activity 設定（`LiveActivitiesSettings` の有効/無効リスト）で個別に切り替えられるようにする場合は、
既存 case と同様に `fanAlert` を一覧に追加する。

## (g) 終了処理 — パッチ不要

`applicationWillTerminate` への追加は不要。`FanControlManager` 自身が `NSApplication.willTerminateNotification`
（最初の `startMonitoring()` または `openSMCSession()` で購読）で全ファンを自動制御に戻してセッションを閉じる（最大 2 秒待機、docs/kit.md「Termination」）。
間に合わなくてもヘルパーが XPC 切断時にセッションを解放し書込前の値を復元する（docs/helper.md §4）。
同様に、スリープ復帰時の再適用も `FanControlManager` が行う（復帰 5 秒後、セッション中のみ。セッションを新たに開くことはない。
設定 OFF の場合は再適用せずセッションを閉じる）。アプリ側は
「スリープ解除後にプロファイルを再適用」設定を `FanControlManager.reapplyProfileAfterWake` に同期するだけでよく、
これは (e) で生成する `FanControlAlertCoordinator` が起動時と設定変更時（`SettingsStore.updates`）に自動で行う
（同時に「いずれかの警告が ON」を `FanControlManager.keepAlertsWhilePaused` に同期し、Nook 非表示中も警告用の低頻度ポーリングを続ける）。
