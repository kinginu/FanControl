#if os(macOS)
import SwiftUI

/// The selection highlight: a Liquid Glass capsule on macOS 26 (Apple's selection style),
/// else an ultra-thin material capsule. (DynamicNotch: mirrors the host's `nookGlass`,
/// NookWidgetChrome.) `DN_DEBUG_NOGLASS=1` (DEBUG) forces the
/// fallback, because glass is not captured by offscreen `cacheDisplay` snapshots.
public struct FanControlSelectionPill: View {
    #if DEBUG
    private static let forceFallback = ProcessInfo.processInfo.environment["DN_DEBUG_NOGLASS"] == "1"
    #else
    private static let forceFallback = false
    #endif

    public init() {}

    public var body: some View {
        if #available(macOS 26, *), !Self.forceFallback {
            Color.clear
                .glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(.tertiary))
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
    }
}
#endif
