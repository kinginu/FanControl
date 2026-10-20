# DynamicNotch 本体ソースへの手作業パッチ

このディレクトリの `*.swift` は DynamicNotch ターゲットに追加する「ドロップイン」ファイルで、DynamicNotch 固有の
グルーだけを含む（2026-10-20 以降。ホスト非依存の UI は SwiftPM ライブラリ **`FanControlUI`** に移した）:

| ファイル | 内容 |
|---|---|
| `FanControlWidgetView.swift` | Nook の Fan Control ウィジェット（(b)） |
| `FanControlWidgetSettingsView.swift` | 設定 ▸ ウィジェットの Fan Control 用オプション（(c)） |
| `FanControlTemperatureWidgetView.swift` | Nook の温度ウィジェット（(a-2)。グラフ本体は `FanControlUI.FanControlTemperatureChart`） |
| `FanControlTemperatureWidgetSettingsView.swift` | 設定 ▸ ウィジェットの温度ウィジェット用オプション（(c)） |
| `FanControlLiveActivity.swift` | Live Activity の表示 `FanControlAlertView`（(f)。状態は `FanControlUI.FanControlAlertCoordinator`） |
| `FanControlNookHooks.swift` | Nook の開閉フック `FanControlNookVisibility` とウィジェット表示数 `FanControlWidgetPresence`（(b-2)） |

`FanControlUI`（`FanControl/Sources/FanControlUI/`、docs/kit.md「UI layer」）が提供するもの: 設定ペイン
`FanControlSettingsView`（一般／プロファイル／センサーの各タブも単体で公開）、カーブ表示 `FanCurveView`・編集
`FanCurveEditorView`、温度グラフ `FanControlTemperatureChart`、主要温度 `FanControlKeyTemperaturesView`、
`FanControlSelectionPill`、警告コーディネータ `FanControlAlertCoordinator`、整形 `FanControlFormatting` /
`FanControlSensorNames` / `FanControlProfiles`、設定モデル（`FanControlWidgetSettings` ほか）と保存
（`FanControlSettingKey` / `@FanControlSetting`）。アプリターゲットに `FanControlCore` / `FanControlKit` に加えて
**`FanControlUI` をリンク**する（DynamicNotchApp は `DynamicNotchApp/project.yml`）。

以下は既存ファイルの switch / enum / 起動処理に手を入れる必要があり、ドロップインでは提供できない
（ホストアプリごとに行・シグネチャが異なるため）。
各項目のコードは「追加する断片」であり、周辺の既存コードは実ソースに合わせて読み替えること。

前提: 変更する各ファイルの先頭に必要に応じて次を追加する。

```swift
import FanControlCore
import FanControlKit
import FanControlUI
```

`DynamicNotchApp/` では、`import FanControlUI` の無い既存ファイル（`SettingsRootView`、`NookWidget`、`DebugHooks` 等）の
ために `Sources/Support/FanControl-Patches.swift` がモジュール内 typealias（`FanControlSettingsView`、`FanControlProfilesTabView`、
`FanControlProfiles`、`FanControlWidgetSettings`、`FanControlTemperatureWidgetSettings`）を宣言している。

**設定の保存**: Fan Control の設定は `FanControlUI` が `UserDefaults.standard` に保存する（`SettingsStore`、2026-10-20 に
sindresorhus/Defaults から置換。保存形式は Defaults と同一でキー名も不変）。ストア本体は `FanControlUI` の internal で、
ホストは公開 API を使う:

```swift
@FanControlSetting(.widget) private var settings            // SwiftUI（変更で再描画、$settings は Binding）
FanControlSettingKey.general.value.isEnabled                 // どこからでも読み書き
for await general in FanControlSettingKey.general.updates() { … }
// キー: .widget / .general / .thresholds / .temperatureWidget（.name が UserDefaults のキー名）
```

ホストが自前の `SettingsStore` を持つ場合（`DynamicNotchApp/` はアプリ全体の設定に同じ実装を使う。
`Sources/Support/SettingsStorage.swift` は `FanControlUI/Storage/SettingsStore.swift` へのシンボリックリンクで、各モジュールに
internal なコピーができる）、ホスト側でも Fan Control の設定を読むなら、同じキー名で型付きキーを宣言する（同じ
`UserDefaults` を KVO で監視するので、どちらのストアからの書込も互いに届く）:

```swift
extension StoredKeys {   // ホストのストア
    static let fanControlWidgetSettings = Key<FanControlWidgetSettings>(FanControlSettingKey.widget.name, default: .init())
}
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
            return FanControlSettingKey.widget.value.gridSize == .doubleWide ? .doubleWide : .medium
        }
    }

    var prefs: WidgetPrefs {
        switch self {
        // …
        case .fanControl: return FanControlSettingKey.widget.value
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
`WidgetPrefs` / `Preferences` がホストのストアの `CodableStoredValue` を要求する場合、`FanControlWidgetSettings`（`Codable`）は
その既定実装で準拠する。DynamicNotchApp  `NookWidget.swift` は上記の `FanControlSettingKey.widget.value` ではなく、ホストのストアに
宣言した同名キー（`SettingsStore[.fanControlWidgetSettings]`、前提の節）で読んでいる。どちらも同じ値を返す。

### (a-2) ウィジェット種別 `temperature` を追加（tag 11、2026-10-20）

CPU / GPU / SSD の温度は Fan Control ウィジェットから独立した「温度」ウィジェットに移した（`FanControlTemperatureWidgetView.swift`）。
`fanControl` と同様に末尾へ追加する（DynamicNotchApp では `#if canImport(FanControlKit)` で囲んでいる）:

```swift
    case temperature           // tag 11

    // icon:         case .temperature: return "thermometer.medium"
    // name:         case .temperature: return "Temperature"     // Localizable.strings にキーあり
    // gridSizeType: case .temperature: return .doubleWide        // 常に 5 セル = 250 pt
    // prefs:        case .temperature: return FanControlSettingKey.temperatureWidget.value
    // rawValue:     case .temperature: return "temperature"   /  init?(rawValue:): case "temperature": self = .temperature
```

```swift
extension FanControlTemperatureWidgetSettings: Preferences, WidgetPrefs {
    init() { self.init(historyWindow: .fiveMinutes) }
    var gridSizeType: NookWidget.NookGridSizeType { .doubleWide }
}
```

設定キーは `FanControlSettingKey.temperatureWidget`（UserDefaults のキー名 `"fanControlTemperatureWidgetSettings"`、`FanControlUI`）。°C/°F は
Fan Control ウィジェットの `temperatureUnit` を共用する。ウィジェットの表示は Fan Control ウィジェットと同じく `FanControlWidgetPresence`
（監視の開始・一時停止解除）に数えられる。

`Preferences` が `init()` を要求する場合（`DynamicNotchApp/` の `Preferences` はそう）、`FanControlWidgetSettings` の
全引数既定値付き `init(gridSize:…)` ではその要件を満たさないので、同じ拡張に `init() { self.init(gridSize: .medium) }` を足す
（2026-10-20、`DynamicNotchApp/Sources/NookWidget.swift` で実施。`FanControlUI` の型への拡張なので、指定イニシャライザへの委譲が必須）。

## (b) Nook グリッドのウィジェット → View 振り分け

参照ソースでは振り分け箇所を特定できていない（`TimerWidgetView()` / `MediaPlayerWidgetView()` を返している
switch を検索すること）。`DynamicNotchApp/` では振り分けが無かったので
`Sources/Support/NookWidgetGrid.swift` の `NookWidgetContentView` として新設し、そこに追加した。1 行追加する:

```swift
switch widget {
// …
case .timer:       TimerWidgetView()
case .fanControl:  FanControlWidgetView()
case .temperature: FanControlTemperatureWidgetView()   // (a-2)
}
```

グリッドの幅を自前で決めている場合（DynamicNotchApp  `NookWidgetLayout.cells(of:)`）は `case .temperature: return 5`（250 pt）。
どちらのウィジェットも 202 pt のセル（DynamicNotchApp  `NookWidgetLayout.cellHeight`）に収まる高さで作ってある（2026-10-20 計測: Fan Control 2x1 194 pt /
ダブルワイド 175 pt、温度 93 pt + 伸縮するグラフ）。

`RootView` が各ウィジェット設定を `.environment(\.xxxWidgetSettings, …)` で配っているが、Fan Control の View は
`@FanControlSetting(.widget)` を直接読むので environment キーの追加は不要。

### (b-2) Nook の表示／非表示 → 監視の一時停止（「Nook 非表示中は一時停止」、2026-10-20 追加）

一時停止はホストの Nook の開閉で駆動する。ウィジェットの `onAppear` / `onDisappear` だけに頼ると、ウィジェットをグリッドから外した・
Nook を閉じたまま設定を開いた場合に一時停止が解けなくなる（逆に、ウィジェットを置いていないと一時停止がかからない）。
Nook が開いた／閉じたことが分かる箇所（NotchViewModel の状態が `.nook` に入る／出る箇所、または `RootView` の
`.onChange(of: notchState)`）で次の 1 行を呼ぶ。メインスレッドから呼ぶこと（`FanControlNookVisibility` は `@MainActor`）:

```swift
// Nook が開いた: isVisible = true / 閉じた（ノッチに戻った・非表示）: isVisible = false
FanControlNookVisibility.nookVisibilityChanged(isVisible: notchState == .nook)
```

`FanControlNookVisibility`（ドロップイン `FanControlNookHooks.swift`）は機能が有効かつ `pauseWhenNookHidden` のときだけ
`FanControlManager.shared.setMonitoringPaused(!isVisible)` を呼び、それ以外は一時停止を解除する。補足:

- ウィジェット自身の `onAppear`（解除）/ `onDisappear`（一時停止）はホストのフックが無い場合の代替として残している。フックがあれば
  Nook を開くたびに確実に解除される。`onDisappear` の一時停止は、表示中の Fan Control ウィジェットが 0 個になったときだけ
  （`FanControlWidgetPresence.visibleCount`。複数画面で片方の Nook を閉じても、もう片方が開いていれば止めない。Nook の中身は
  フェードで消えるので `onDisappear` はフックより後に走る）、かつ `FanControlWidgetPresence.hostReportsVisibility` が false のとき
  だけ行う（2026-10-20 レビュー指摘）。`hostReportsVisibility` は `nookVisibilityChanged` の初回呼出しで立つ
  （`FanControlNookHooks.swift`）。
  プレビュー描画（`previewProfile` / `previewGridSize` 指定時）は数に入れない。
- 設定ペイン（`FanControlUI.FanControlSettingsView`）は表示中 `FanControlManager.setLiveDataHold(true, for:)` で一時停止を保留し（Nook が閉じていても
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
    case .temperature:
        FanControlTemperatureWidgetSettingsView()   // (a-2)
    default:
        BlankView()
    }
}
```

## (d) 設定ウィンドウに「Fan Control」タブを追加

ホストの設定ウィンドウは SwiftUI 標準の `Settings` シーン（`App` の `body` に `Settings { … }`）で、中身はペインごとに
1 タブの `TabView`（`.tabItem { Label(タイトル, systemImage: SF Symbol) }`。macOS がツールバー型のタブとして表示する）である前提。
そこへ Fan Control のタブを 1 つ足す。ペインは `FanControlUI` の `FanControlSettingsView`（sindresorhus/Settings には依存しない。
2026-10-20 に撤去。各タブは標準の `Form` + `.formStyle(.grouped)`）。

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
    let fanSettings = FanControlSettingKey.general.value
    if fanSettings.isEnabled && fanSettings.autoStartMonitoring {
        FanControlManager.shared.startMonitoring()
    }
}
```

`isEnabled` の既定値は `false`。ユーザーが設定で明示的に有効化するまでファン制御は一切動かない（設計書 §5.5）。

## (f) `LiveActivity` enum と `LiveActivityView`

`DynamicNotchApp/`（2026-10-21、`Sources/LiveActivities/`）では Live Activity の性質を
`LiveActivityDescriptor` に集約したため、追加するのは case 1 つと descriptor 1 件、表示の 2 分岐だけ:

```swift
// LiveActivity.swift
#if canImport(FanControlKit)
case fanAlert
#endif

// LiveActivityDescriptor.swift（LiveActivity.descriptor の switch）
#if canImport(FanControlKit)
case .fanAlert:
    return .init(id: "fanAlert", icon: "fan", name: "Fan Alert", priority: 100,
                 sideWidth: .fixed(132), isConfigurable: false, gate: .always)
#endif

// LiveActivityView.swift（ノッチ左右の分岐）
case (.fanAlert, .leading):  FanControlAlertView(part: .leading)
case (.fanAlert, .trailing): FanControlAlertView(part: .trailing)
```

`gate: .always` は安全警告なので Live Activities 設定のオン／オフに関係なく表示する意味。`priority: 100` は
他の Activity（タイマー終了 90 など）より優先して閉じたノッチを占有する。既存の `icon` / `id` / `name` /
`init?(rawValue:)` を個別の switch で持つ構成なら、上の値をそれぞれの switch に書く。

一時的な展開（バッテリー低下と同じ演出）を使う場合は、`"DynamicNotchBatteryLowTransient"` を購読している箇所に
`FanControlAlertCoordinator.transientNotificationName`（= `"DynamicNotchFanAlertTransient"`）の購読を並べる。

Live Activity 設定（`LiveActivitiesSettings` の有効/無効リスト）で個別に切り替えられるようにする場合は、
`isConfigurable: true` / `gate: .liveActivitiesSettings` にする（安全警告を消せるようになるためDynamicNotchApp では採らない）。

## (g) 終了処理 — パッチ不要

`applicationWillTerminate` への追加は不要。`FanControlManager` 自身が `NSApplication.willTerminateNotification`
（最初の `startMonitoring()` または `openSMCSession()` で購読）で全ファンを自動制御に戻してセッションを閉じる（最大 2 秒待機、docs/kit.md「Termination」）。
間に合わなくてもヘルパーが XPC 切断時にセッションを解放し書込前の値を復元する（docs/helper.md §4）。
同様に、スリープ復帰時の再適用も `FanControlManager` が行う（復帰 5 秒後、セッション中のみ。セッションを新たに開くことはない。
設定 OFF の場合は再適用せずセッションを閉じる）。アプリ側は
「スリープ解除後にプロファイルを再適用」設定を `FanControlManager.reapplyProfileAfterWake` に同期するだけでよく、
これは (e) で生成する `FanControlAlertCoordinator`（`FanControlUI`）が起動時と設定変更時（設定の変更ストリーム）に自動で行う
（同時に「いずれかの警告が ON」を `FanControlManager.keepAlertsWhilePaused` に同期し、Nook 非表示中も警告用の低頻度ポーリングを続ける）。

## (h) Power Profiles（F2、2026-10-21）

設定ペイン `FanControlPowerProfilesSettingsView`、ウィジェット用の状態行 `FanControlPowerProfileStatusLine`、
起動フック `FanControlPowerProfiles.start()` は **`FanControlUI`**（`Sources/FanControlUI/PowerProfiles/`）にある。
アプリ側は既存ソースへ 4 か所（いずれも `// F2:` 付き）。仕様は `DynamicNotchApp/docs/power-profiles.md`。

1. 設定タブの識別子と型エイリアス（`Support/FanControl-Patches.swift`。(d) の extension 内と、FanControlUI 名のエイリアス群）:

```swift
static let powerProfiles = Self("powerProfiles")
typealias FanControlPowerProfilesSettingsView = FanControlUI.FanControlPowerProfilesSettingsView
```

2. 設定ウィンドウのタブ（`Sources/SettingsRootView.swift`、Fan Control の直後）:

```swift
tab(.powerProfiles, "Power Profiles", "bolt.badge.automatic") { FanControlPowerProfilesSettingsView() } // F2
```

3. 起動処理（`Support/FanControl-Patches.swift` の `FanControlStartup.applicationDidFinishLaunching()` の末尾）:

```swift
FanControlPowerProfiles.start()
```

`PowerProfileEngine.shared.start()` と、Fan Control 無効時（`FanControlSettingKey.general`）はファンを切り替えない
`FanProfileArbiter.shared.isApplyAllowed` を設定する。Power Profiles の既定は OFF でルールも空なので、ユーザーが有効にするまで何も切り替えない。

4. ウィジェット（このディレクトリの `FanControlWidgetView.swift`）: ヘッダー直下に `FanControlPowerProfileStatusLine(isCompact:)`。

文字列: ペインの文字列は `Localizable/en.strings` の「F2: Power Profiles」節、タブ名 "Power Profiles" は
`DynamicNotchApp/Support/strings/power-profiles.json`。

## (i) 負荷連動プロファイル（F3、2026-10-20）— 起動 1 行とホスト側コーディネータ

「Automation」サブタブ（`FanControlAutomationTabView`、`FanControlSettingsView` の tag 3）とウィジェット見出しの 1 行表示
（`FanControlAutomationIndicator`、「Auto: Boost (Xcode)」）は FanControlUI にある。設定は `FanControlSettingKey.automation`、
表示する実行時の状態は `FanControlAutomationState.shared`。これを書き込むのはホストのコーディネータで、DynamicNotchApp では
`DynamicNotchApp/Sources/Support/WorkloadProfileCoordinator.swift`（FanControlKit の `WorkloadProfileEngine` を `NSWorkspace` の通知と
2 秒周期の CPU/GPU 負荷サンプリング `SystemLoadSampler` で駆動する）。ドロップインの `FanControlWidgetView` は見出しに
`FanControlAutomationIndicator()` を 1 行置くだけ（`// F3:`）。

(e) の `FanControlStartup.applicationDidFinishLaunching()` の末尾に次を追加する。

```swift
WorkloadProfileCoordinator.shared.start()
```

優先順位（手動 > 緊急 > 負荷連動 > 電源連動 > 既定）は F2 の `FanProfileArbiter` が一元管理する（docs/kit.md
「Profile precedence and automation」）。コーディネータは `.workload` 層を claim / release するだけで、自分では
`applyProfile` しない。手動選択はアービタの `manualSelectionNotification` で受け取る。(h) の `FanControlPowerProfiles.start()`
の後に呼ぶ。
