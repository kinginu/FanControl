/// FanControlKit: the app-side layer DynamicNotch talks to.
///
/// - `FanControlManager`: `@Observable` singleton (`FanControlManager.shared`)
///   that polls the SMC (read-only, in-process via `FanControlSMC.SMCClient`),
///   evaluates alerts and drives fans through the privileged helper.
/// - `HelperInstaller`: `SMAppService` registration of FanControlHelper.
/// - `HelperClient`: async `NSXPCConnection` client (`SMCWriter`) for the helper.
/// - `FanWriteStrategy`: pure computation of the per-platform SMC write
///   sequence (Apple Silicon `F<i>Md` vs Intel `FS! `).
///
/// Everything except `FanWriteStrategy`, `FanTarget` and the two status enums is
/// macOS-only; on other platforms the module is (almost) empty.
public enum FanControlKitInfo {
    public static let version = "0.1.0"
}
