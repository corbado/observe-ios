import Foundation

/// Entry point of the Corbado Observe SDK.
///
/// Design commitments:
/// - **Library, not framework**: nothing runs before the host app explicitly calls
///   `initialize`; there is no auto-initialization. Not calling it means the SDK is fully inert.
/// - **Never breaks the host app**: `initialize` is cheap and main-safe (all real work happens
///   asynchronously on the SDK's own actor); no public method ever throws.
/// - **App only**: in an app extension (where `UIApplication` does not even exist) the SDK
///   refuses to initialize and returns nil — the iOS analog of the Android main-process guard.
public enum CorbadoObserve {
    private struct State {
        var tracker: ObserveTracker?
        var shutdown: Task<Void, Never>?
    }

    private static let stateBox = Locked(State())

    /// Initialize the SDK and return the tracker, or nil when initialization is refused (app
    /// extension, invalid options). Call once, e.g. from your `App`/app delegate startup —
    /// guarded however you like; skipping the call disables the SDK entirely.
    @discardableResult
    public static func initialize(options: ObserveOptions) -> ObserveTracker? {
        let logger = ObserveLogger(debug: options.debug)
        // Idempotent once initialized — even a later call with (invalid or different) options
        // returns the existing tracker rather than re-validating.
        if let existing = stateBox.value.tracker {
            logger.warn("already initialized; returning the existing tracker")
            return existing
        }
        if options.apiBaseUrl.hasSuffix("/") {
            logger.error("apiBaseUrl must not end with '/'; SDK stays disabled")
            return nil
        }
        if options.projectId.trimmingCharacters(in: .whitespaces).isEmpty || options.eventsURL == nil
            || options.configURL == nil
        {
            logger.error("invalid options: projectId and an http(s) apiBaseUrl are required; SDK stays disabled")
            return nil
        }
        if Bundle.main.bundleURL.pathExtension == "appex" {
            logger.warn("running in an app extension; SDK stays disabled in this process")
            return nil
        }

        return stateBox.withLock { state in
            if let existing = state.tracker { return existing }
            let tracker = ObserveTracker(options: options)
            tracker.start(after: state.shutdown)
            state.tracker = tracker
            return tracker
        }
    }

    /// The tracker created by `initialize`, or nil when not initialized.
    public static func getTracker() -> ObserveTracker? { stateBox.value.tracker }

    /// Terminally deactivate the SDK: drains pending events with the configured retry policy
    /// and unregisters lifecycle observers. A later `initialize` accepts calls immediately,
    /// but waits for this shutdown before opening shared storage.
    public static func destroy() {
        stateBox.withLock { state in
            guard let current = state.tracker else { return }
            current.destroy()
            state.shutdown = Task { await current.awaitTermination() }
            state.tracker = nil
        }
    }
}
