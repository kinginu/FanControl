# DynamicNotch 本体ソースへの手作業パッチ

このディレクトリの `*.swift` はそのまま DynamicNotch ターゲットに追加できる「ドロップイン」ファイルだが、
以下は既存ファイルの switch / enum / 起動処理に手を入れる必要があり、ドロップインでは提供できない
（ホストアプリごとに行・シグネチャが異なるため）。
各項目のコードは「追加する断片」であり、周辺の既存コードは実ソースに合わせて読み替えること。

前提: 変更する各ファイルの先頭に必要に応じて次を追加する。

```swift
import Defaults
import FanControlCore
import FanControlKit
```

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
            return Defaults[.fanControlWidgetSettings].gridSize == .doubleWide ? .doubleWide : .medium
        }
    }

    var prefs: WidgetPrefs {
        switch self {
        // …
        case .fanControl: return Defaults[.fanControlWidgetSettings]
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

## (b) Nook グリッドのウィジェット → View 振り分け

参照ソースでは振り分け箇所を特定できていない（`TimerWidgetView()` / `MediaPlayerWidgetView()` を返している
switch を検索すること）。そこに 1 行追加する:

```swift
switch widget {
// …
case .timer:      TimerWidgetView()
case .fanControl: FanControlWidgetView()
}
```

`RootView` が各ウィジェット設定を `.environment(\.xxxWidgetSettings, …)` で配っているが、Fan Control の View は
`@Default(.fanControlWidgetSettings)` を直接読むので environment キーの追加は不要。

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

## (d) 設定ウィンドウに「Fan Control」ペインを登録

**`Settings` の名前衝突に注意:** sindresorhus/Settings の `Settings` モジュールは、SwiftUI と一緒に import すると SwiftUI の
`Settings` シーン型と衝突し、`Settings.PaneIdentifier` / `Settings.Pane` / `Settings.Container` / `Settings.Section` が曖昧・誤解決に
なることがある。DynamicNotch の既存設定ビューと設定ペイン登録箇所が使っている修飾（モジュール修飾や typealias など）を確認し、
下の断片と `FanControlGeneralTabView.swift` にも同じ書き方を使うこと。

`Settings.PaneIdentifier` の定義と、`SettingsWindowController(panes:)`（または `Settings { … }` シーン）に渡している配列に追加する:

```swift
extension Settings.PaneIdentifier {
    static let fanControl = Self("fanControl")
}

let FanControlSettingsPaneController: () -> SettingsPane = {
    let pane = Settings.Pane(
        identifier: .fanControl,
        title: String(localized: "Fan Control"),
        toolbarIcon: NSImage(systemSymbolName: "fan", accessibilityDescription: String(localized: "Fan Control"))!
    ) {
        FanControlSettingsView()
    }
    return Settings.PaneHostingController(pane: pane)
}

// 既存の panes 配列に追加:
// SettingsWindowController(panes: [ …, FanControlSettingsPaneController() ], …)
```

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
    // （アプリがヘルパーの署名に要求する Team ID。docs/integration.md §4）:
    // FanControlManager.shared.clientTeamID = "<TeamID>"
    let fanSettings = Defaults[.fanControlGeneralSettings]
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
これは (e) で生成する `FanControlAlertCoordinator` が起動時と設定変更時（`Defaults.updates`）に自動で行う
（同時に「いずれかの警告が ON」を `FanControlManager.keepAlertsWhilePaused` に同期し、Nook 非表示中も警告用の低頻度ポーリングを続ける）。
