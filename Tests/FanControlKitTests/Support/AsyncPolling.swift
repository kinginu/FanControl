import Foundation

/// Polls `condition` every 10 ms until it holds or `timeout` elapses (for state that
/// asynchronous XPC callbacks update). Returns the final value of `condition`.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Carries a non-`Sendable` value (e.g. an `NSXPCListenerEndpoint`) into a `@Sendable` closure.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Weak reference that can cross into a `@Sendable` closure.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
