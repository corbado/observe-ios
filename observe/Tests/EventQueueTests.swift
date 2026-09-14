import Foundation
import Testing

@testable import CorbadoObserve

private final class RejectingTransport: Transporting {
    nonisolated func shutdown() {}

    let batches = Locked<[WireEventBatch]>([])

    func send(_ batch: WireEventBatch) async -> TransportResult {
        batches.withLock { $0.append(batch) }
        return TransportResult(statusCode: 400)
    }
}

@Suite @MainActor struct EventQueueTests {
    @Test func permanentRejectionDropsBufferedEvidence() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RejectingTransport()
        let telemetry = TelemetryBuffer(enabled: { true }, currentSessionId: { "session" })
        let lows = LowBuffer(enabled: { true }, currentSessionId: { "session" })
        let outbox = Outbox(directory: { directory }, logger: ObserveLogger(debug: false))
        let queue = EventQueue(
            transport: transport, outbox: outbox, config: { .default },
            sdkInfo: WireSdkInfo(name: "observe-ios", version: "test"),
            telemetryBuffer: telemetry, lowBuffer: lows, logger: ObserveLogger(debug: false),
            signal: { _ in })
        lows.report(WireLowEvent(lowType: "input", ts: 1))
        telemetry.report("info", "original evidence")
        await queue.flush(.manual)
        await queue.flush(.timer)
        await queue.flush(.timer)

        let sentLows = transport.batches.value.flatMap { $0.lows ?? [] }
        let sentTelemetry = transport.batches.value.flatMap { $0.telemetry ?? [] }
        #expect(sentLows.count == 1)
        #expect(sentTelemetry.filter { $0.message == "original evidence" }.count == 1)
        #expect(!lows.isNotEmpty)
        #expect(!telemetry.isNotEmpty)
    }
}
