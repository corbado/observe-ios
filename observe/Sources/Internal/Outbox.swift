import Foundation

/// Durable event outbox: a JSONL (one JSON object per line) append-only file in app-private
/// storage. Events are written through at enqueue time so they survive process death; this is the
/// last reliable delivery mechanism when iOS suspends or kills the app.
///
/// Design notes:
/// - Appending is O(1); UserDefaults would rewrite its whole plist per event.
/// - A torn write from process death corrupts at most the last line; recovery parses line by line
///   and skips anything unparsable.
/// - Capped at 500 entries; when full, the oldest entries are
///   dropped (compaction rewrites the file).
/// - The file is excluded from iCloud backup (telemetry must not restore onto a new device) and
///   protected `completeUntilFirstUserAuthentication` (writable while backgrounded, still
///   encrypted at rest). Both attributes are re-applied after every path that creates or
///   atomically replaces the file, because a rename drops them.
///
/// All access is on the SDK's internal actor.
final class Outbox {
    struct Entry: Codable {
        var sessionId: String
        var event: WireEvent
    }

    private let directory: () -> URL
    private let logger: ObserveLogger

    // Resolved lazily on first use (SDK actor): construction happens on the caller's thread
    // during init, which must stay free of disk I/O (main-safety).
    private lazy var file: URL = {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path)
        return dir.appendingPathComponent("cbo_outbox.jsonl")
    }()

    // Counted lazily on first append, for the same reason.
    private var count: Int = -1

    init(directory: @escaping () -> URL, logger: ObserveLogger) {
        self.directory = directory
        self.logger = logger
    }

    func append(_ entry: Entry) {
        do {
            if count < 0 { count = countLines() }
            if count >= Self.maxEntries {
                compact(dropOldest: count - Self.maxEntries + 1)
            }
            let line = try WireJson.encoder.encode(entry) + Data("\n".utf8)
            if let handle = try? FileHandle(forUpdating: file) {
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    // A killed append may leave a partial final record. Separate the next entry
                    // so recovery can discard the torn record without losing this valid one.
                    if try handle.read(upToCount: 1)?.first != 0x0A {
                        try handle.write(contentsOf: Data("\n".utf8))
                    }
                }
                try handle.write(contentsOf: line)
            } else if !FileManager.default.fileExists(atPath: file.path) {
                try line.write(to: file, options: .atomic)
                applyFileAttributes()
            } else {
                // The file exists but could not be opened (transient). Dropping this one entry
                // is the only safe outcome; a full-file write here would truncate the outbox.
                logger.warn("outbox append failed: could not open existing file")
                return
            }
            count += 1
        } catch {
            logger.warn("outbox append failed: \(error.localizedDescription)")
        }
    }

    /// Reads all recoverable entries (used for the recovery flush at init).
    func readAll() -> [Entry] { readEntries() ?? [] }

    /// Preserve the distinction between an empty file and a failed read: a failed read must
    /// never become an empty rewrite that destroys events waiting for storage to recover.
    private func readEntries() -> [Entry]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file) else {
            logger.warn("outbox read failed")
            return nil
        }
        // Decode individual byte lines: a torn UTF-8 character must not poison earlier records.
        return data.split(separator: 0x0A).compactMap { line in
            try? WireJson.decoder.decode(Entry.self, from: Data(line))
        }
    }

    /// Removes delivered events by id. Rewrites the file (delivery batches are small).
    func remove(_ eventIds: Set<String>) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let entries = readEntries() else { return }
        writeAll(entries.filter { !eventIds.contains($0.event.id) })
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            count = 0
        } catch {
            logger.warn("outbox clear failed: \(error.localizedDescription)")
        }
    }

    private func compact(dropOldest: Int) {
        guard let entries = readEntries() else { return }
        writeAll(Array(entries.dropFirst(dropOldest)))
    }

    private func writeAll(_ entries: [Entry]) {
        var data = Data()
        for entry in entries {
            guard let line = try? WireJson.encoder.encode(entry) else { continue }
            data.append(line)
            data.append(Data("\n".utf8))
        }
        do {
            try data.write(to: file, options: .atomic)
            applyFileAttributes()
            count = entries.count
        } catch {
            logger.warn("outbox rewrite failed: \(error.localizedDescription)")
        }
    }

    /// Backup exclusion + protection class. An atomic write renames a temp file into place, so
    /// this must run after every creation/replacement of the file, not once.
    private func applyFileAttributes() {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    /// Counts non-blank lines (including unparsable ones) so the cap accounts for the bytes
    /// actually in the file.
    private func countLines() -> Int {
        guard FileManager.default.fileExists(atPath: file.path),
            let data = try? Data(contentsOf: file)
        else { return 0 }
        return data.split(separator: 0x0A).count
    }

    private static let maxEntries = 500
}
