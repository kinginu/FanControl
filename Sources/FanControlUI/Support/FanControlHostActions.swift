#if os(macOS)
// Host hooks of the settings pane: actions the package cannot implement itself because they
// depend on how the host ships the helper (docs/helper.md §6 "Bundling the scripts in the app").

import Foundation

/// Actions a host app provides to the Fan Control settings pane. Set them once at launch
/// (before the pane is shown); `nil` keeps the package's default UI.
///
/// - `installHelper` / `uninstallHelper`: install or remove the helper for this build of the app
///   in manual (personal-use) mode, e.g. by running `install.sh` / `uninstall.sh` bundled in the
///   app with administrator privileges. When set, Settings ▸ Fan Control ▸ General shows
///   "Install Helper…" while the helper is not installed or is pinned to another build
///   (instead of the `SMAppService` registration), and "Uninstall Helper…" while it is
///   installed manually. After a successful install the pane runs "Check Again"
///   (`FanControlManager.retryHelperConnection()`); after an uninstall it re-reads the status.
///
/// Each closure receives a progress callback for the installer's output so far (the whole text
/// each time, not a delta) and returns the complete output. It throws `CancellationError` when
/// the user cancelled (nothing is shown) or `FanControlHelperInstallerFailure` (its summary is
/// shown as the pane's error, its output in the installer log).
@MainActor
public enum FanControlHostActions {
    public typealias HelperInstallerAction =
        @MainActor (_ progress: @escaping @MainActor (String) -> Void) async throws -> String

    public static var installHelper: HelperInstallerAction?
    public static var uninstallHelper: HelperInstallerAction?

    /// True when the host installs the helper itself (manual mode), so the pane offers
    /// "Install Helper…" for a missing or mismatched installation.
    public static var providesHelperInstaller: Bool { installHelper != nil }
}

/// A failed host installer run: `summary` for the error footer, `output` for the log.
public struct FanControlHelperInstallerFailure: LocalizedError, Sendable {
    public var summary: String
    public var output: String

    public init(summary: String, output: String) {
        self.summary = summary
        self.output = output
    }

    public var errorDescription: String? { summary }
}
#endif
