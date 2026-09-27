import os

/// Internal logger over unified logging. Quiet by default (warnings and errors only);
/// `debug = true` at init enables verbose logging. Never throws, since logging must not be able to
/// break the host app.
struct ObserveLogger: Sendable {
    let debugEnabled: Bool

    private static let log = Logger(subsystem: "com.corbado.observe", category: "CorbadoObserve")

    init(debug: Bool) {
        debugEnabled = debug
    }

    func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let text = message()
        Self.log.debug("\(text, privacy: .public)")
    }

    func warn(_ message: String) {
        Self.log.warning("\(message, privacy: .public)")
    }

    func error(_ message: String, _ error: (any Error)? = nil) {
        if let error {
            Self.log.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            Self.log.error("\(message, privacy: .public)")
        }
    }
}
