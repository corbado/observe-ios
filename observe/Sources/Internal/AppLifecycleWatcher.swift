import UIKit

/// Foreground/background detection via app-level `UIApplication` notifications. Works for every
/// app architecture (scenes or classic app delegate), with no delegate swizzling or auto-init.
/// Registered during explicit `init()` and unregistered on `destroy()`. Also relays active-state
/// churn (resign/become active) to the autofill engine for the `window-blur`/`window-focus` lows.
///
/// `didEnterBackground` is the last reliable delivery moment on iOS; the tracker wraps its
/// background flush in a `beginBackgroundTask` grace window because the process is suspended
/// seconds later. Anything still undelivered ships via the outbox recovery flush on next launch.
final class AppLifecycleWatcher: Sendable {
    private let observers = Locked<[any NSObjectProtocol]>([])
    private let onForeground: @MainActor @Sendable () -> Void
    private let onBackground: @MainActor @Sendable () -> Void
    private let onResignActive: @MainActor @Sendable () -> Void
    private let onBecomeActive: @MainActor @Sendable () -> Void

    init(
        onForeground: @escaping @MainActor @Sendable () -> Void,
        onBackground: @escaping @MainActor @Sendable () -> Void,
        onResignActive: @escaping @MainActor @Sendable () -> Void,
        onBecomeActive: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onForeground = onForeground
        self.onBackground = onBackground
        self.onResignActive = onResignActive
        self.onBecomeActive = onBecomeActive
    }

    func register() {
        let center = NotificationCenter.default
        let onForeground = onForeground
        let onBackground = onBackground
        let onResignActive = onResignActive
        let onBecomeActive = onBecomeActive
        // queue: .main delivers on the main thread, which is what assumeIsolated asserts.
        observers.value = [
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onForeground() } },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onBackground() } },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onResignActive() } },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onBecomeActive() } },
        ]
    }

    func unregister() {
        let current = observers.withLock { stored -> [any NSObjectProtocol] in
            let value = stored
            stored = []
            return value
        }
        current.forEach(NotificationCenter.default.removeObserver(_:))
    }
}

/// Begins a UIKit background-task grace window so a background flush is not cut off by
/// suspension; returns a completion that ends it. Never throws; the returned completion is safe
/// to call from any thread.
@MainActor
func beginBackgroundGrace() -> @Sendable () -> Void {
    let application = UIApplication.shared
    let taskId = Locked(UIBackgroundTaskIdentifier.invalid)
    taskId.value = application.beginBackgroundTask(withName: "corbado-observe-flush") {
        let id = taskId.withLock { stored -> UIBackgroundTaskIdentifier in
            let value = stored
            stored = .invalid
            return value
        }
        if id != .invalid { application.endBackgroundTask(id) }
    }
    return {
        Task { @MainActor in
            let id = taskId.withLock { stored -> UIBackgroundTaskIdentifier in
                let value = stored
                stored = .invalid
                return value
            }
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}
