import Foundation
import Testing

@testable import CorbadoObserve

@Suite struct OutboxTests {
    private func makeOutbox() -> (Outbox, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-test-\(UUID().uuidString)", isDirectory: true)
        return (Outbox(directory: { dir }, logger: ObserveLogger(debug: false)), dir)
    }

    private func entry(_ id: String) -> Outbox.Entry {
        Outbox.Entry(
            sessionId: "session",
            event: WireEvent(id: id, timestamp: 1, seq: 0, name: "flow_started", data: .object([:])))
    }

    @Test func appendReadRemoveRoundTrip() {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        outbox.append(entry("a"))
        outbox.append(entry("b"))
        #expect(outbox.readAll().map(\.event.id) == ["a", "b"])

        outbox.remove(["a"])
        #expect(outbox.readAll().map(\.event.id) == ["b"])

        outbox.clear()
        #expect(outbox.readAll().isEmpty)
    }

    @Test func tornLastLineIsSkippedOnRecovery() throws {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        outbox.append(entry("a"))
        let file = dir.appendingPathComponent("cbo_outbox.jsonl")
        var data = try Data(contentsOf: file)
        data.append(Data(#"{"sessionId":"s","ev"#.utf8))  // torn write, no newline
        try data.write(to: file)

        #expect(outbox.readAll().map(\.event.id) == ["a"])
    }

    @Test func fileStaysExcludedFromBackupAcrossRewrites() throws {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cbo_outbox.jsonl")

        outbox.append(entry("a"))
        var values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        // remove() rewrites atomically (rename), so the exclusion must be re-applied.
        outbox.append(entry("b"))
        outbox.remove(["a"])
        values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func capDropsOldestViaCompaction() {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<505 {
            outbox.append(entry("id-\(index)"))
        }
        let ids = outbox.readAll().map(\.event.id)
        #expect(ids.count == 500)
        #expect(ids.first == "id-5")
        #expect(ids.last == "id-504")
    }
    @Test(arguments: [Data("{torn".utf8), Data([0x7B, 0xFF])])
    func recoveryAndAppendPreserveEventsAroundTornTail(tail: Data) throws {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        outbox.append(entry("before"))
        let file = dir.appendingPathComponent("cbo_outbox.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()

        #expect(outbox.readAll().map(\.event.id) == ["before"])
        outbox.append(entry("after"))
        #expect(outbox.readAll().map(\.event.id) == ["before", "after"])
    }

    @Test func failedReadDoesNotRewriteAndTruncateOutbox() throws {
        let (outbox, dir) = makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        outbox.append(entry("preserve"))
        let file = dir.appendingPathComponent("cbo_outbox.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect((try? Data(contentsOf: file)) == nil)
        outbox.remove(["unrelated"])
        outbox.append(entry("unwritable"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(outbox.readAll().map(\.event.id) == ["preserve"])
    }

}
