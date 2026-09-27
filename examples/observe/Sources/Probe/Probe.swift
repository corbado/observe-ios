import Foundation
import os

/// Experiment observation channel: structured JSONL, written to unified logging AND appended
/// to `Documents/probe.jsonl`; nothing on screen. `tools/capture.sh` pulls both (the SDK's own
/// debug event log rides the same unified-logging stream). Every line is one JSON object:
/// `{"ts":<unix ms>,"screen":"...","event":"...", ...fields}`.
///
/// The probe is exactly the observation layer we intend to promote into the SDK later, so keep
/// its vocabulary tidy. Never log field values.
@MainActor
enum Probe {
    static let subsystem = "com.corbado.observe-example"
    private static let logger = Logger(subsystem: subsystem, category: "probe")

    /// Set by the screen host so every probe line carries the situation context.
    static var currentScreen = ""

    /// Last lines, newest last (devbar display).
    private(set) static var recent: [String] = []
    private static let recentLimit = 200

    static let fileURL = URL.documentsDirectory.appending(path: "probe.jsonl")
    private static var handle: FileHandle?

    static func log(_ event: String, _ fields: [String: Any?] = [:]) {
        var json: [String: Any] = [
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
            "screen": currentScreen,
            "event": event,
        ]
        for (key, value) in fields {
            if let value { json[key] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        logger.info("\(line, privacy: .public)")
        recent.append(line)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        append(line)
    }

    /// Tester-placed segment marker (devbar), so a capture can be cut into experiments.
    static func marker(_ label: String) {
        log("marker", ["label": label])
    }

    static func clearFile() {
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
        recent.removeAll()
        log("probe_cleared")
    }

    private static func append(_ line: String) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }
}
