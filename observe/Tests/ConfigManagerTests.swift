import Foundation
import Testing

@testable import CorbadoObserve

/// A controllable network suspension that deliberately ignores task cancellation, exercising
/// the manager's late-response guard as well as startup without a remote response.
actor GatedConfigTransport: ConfigTransporting {
    nonisolated func shutdown() {}
    private var response: CheckedContinuation<ConfigResponse, Never>?
    private(set) var requests = 0

    func fetch() async -> ConfigResponse {
        requests += 1
        return await withCheckedContinuation { response = $0 }
    }

    func release(_ result: ConfigResponse) {
        response?.resume(returning: result)
        response = nil
    }
}

private actor ManualConfigClock {
    private var now: Int64 = 0
    private var sleepers: [UUID: (Int64, CheckedContinuation<Void, any Error>)] = [:]
    private(set) var delays: [Int64] = []

    func sleep(_ milliseconds: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                delays.append(milliseconds)
                sleepers[id] = (now + milliseconds, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }

    func advance(_ milliseconds: Int64) {
        now += milliseconds
        for (id, sleeper) in sleepers where sleeper.0 <= now {
            sleepers.removeValue(forKey: id)?.1.resume()
        }
    }
}

func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await condition())
}

@Suite struct ConfigManagerTests {
    @Test(arguments: [408, 429, 500, 503])
    func transientFailuresRetryOnFixedScheduleWithoutMovingRefresh(status: Int) async {
        let network = GatedConfigTransport()
        let clock = ManualConfigClock()
        let manager = ConfigManager(
            transport: network, logger: ObserveLogger(debug: false), sleep: { try await clock.sleep($0) })
        let received = Locked<[String]>([])
        await manager.start { config, _ in received.withLock { $0.append(config.version) } }
        await eventually { await network.requests == 1 }
        await network.release(ConfigResponse(statusCode: status))
        await eventually { await clock.delays.contains(1_000) }
        await clock.advance(999)
        #expect(await network.requests == 1)
        await clock.advance(1)
        await eventually { await network.requests == 2 }
        await network.release(ConfigResponse(statusCode: nil))
        await eventually { await clock.delays.contains(3_000) }
        await clock.advance(2_999)
        #expect(await network.requests == 2)
        await clock.advance(1)
        await eventually { await network.requests == 3 }
        await network.release(ConfigResponse(statusCode: 200, body: #"{"version":"fresh"}"#))
        await eventually { received.value == ["fresh"] }
        await clock.advance(595_999)
        #expect(await network.requests == 3)
        await clock.advance(1)
        await eventually { await network.requests == 4 }
        await manager.stop()
        await network.release(ConfigResponse(statusCode: 200, body: #"{"version":"late"}"#))
        await eventually { await !manager.isFetching }
        #expect(received.value == ["fresh"])
    }

    @Test(arguments: [400, 401, 404, 408, 429, 503, 200])
    func permanentResponsesWaitForRegularRefresh(status: Int) async {
        let network = GatedConfigTransport()
        let clock = ManualConfigClock()
        let manager = ConfigManager(
            transport: network, logger: ObserveLogger(debug: false), sleep: { try await clock.sleep($0) })
        let received = Locked(0)
        await manager.start { _, _ in received.withLock { $0 += 1 } }
        await eventually { await network.requests == 1 }
        await network.release(ConfigResponse(statusCode: status, body: "not-json", hasRetryAfter: true))
        // Crossing a complete refresh also proves no immediate retry was scheduled.
        await eventually { await !manager.isFetching }
        await clock.advance(600_000)
        await eventually { await network.requests == 2 }
        #expect(await clock.delays.allSatisfy { $0 == 600_000 })
        #expect(received.value == 0)
        await manager.stop()
        await network.release(ConfigResponse(statusCode: nil))
    }

    @Test(arguments: ["{}", "[]", #"{"version":""}"#, #"{"version":3}"#, "not-json"])
    func invalidPolicyIsNotRetried(body: String) async {
        let network = GatedConfigTransport()
        let clock = ManualConfigClock()
        let manager = ConfigManager(
            transport: network, logger: ObserveLogger(debug: false), sleep: { try await clock.sleep($0) })
        await manager.start { _, _ in Issue.record("Invalid config was accepted") }
        await eventually { await network.requests == 1 }
        await network.release(ConfigResponse(statusCode: 200, body: body))
        await eventually { await !manager.isFetching }
        await clock.advance(600_000)
        await eventually { await network.requests == 2 }
        #expect(await clock.delays.allSatisfy { $0 == 600_000 })
        await manager.stop()
        await network.release(ConfigResponse(statusCode: nil))
    }

    @Test func stoppingDuringBackoffCancelsAllFutureWork() async {
        let network = GatedConfigTransport()
        let clock = ManualConfigClock()
        let manager = ConfigManager(
            transport: network, logger: ObserveLogger(debug: false), sleep: { try await clock.sleep($0) })
        await manager.start { _, _ in Issue.record("Unexpected config") }
        await eventually { await network.requests == 1 }
        await network.release(ConfigResponse(statusCode: nil))
        await eventually { await clock.delays.contains(1_000) }
        await manager.stop()
        await clock.advance(1_000_000)
        await manager.start { _, _ in Issue.record("Restarted after stop") }
        #expect(await network.requests == 1)
    }
}
