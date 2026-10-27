import Foundation
import Testing

@testable import CorbadoObserve

/// A controllable network suspension that deliberately ignores task cancellation, exercising
/// the manager's late-response guard as well as startup without a remote response.
actor GatedConfigTransport: ConfigTransporting {
    nonisolated func shutdown() {}
    private var response: CheckedContinuation<ConfigResponse, Never>?
    private(set) var entityTags: [String?] = []
    var requests: Int { entityTags.count }

    func fetch(ifNoneMatch: String?) async -> ConfigResponse {
        entityTags.append(ifNoneMatch)
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

/// Polls until `condition` holds. Gives up only once both 200 polls and 10s have passed: a frozen
/// CI process burns wall-clock time without polling, slow progress burns polls without time.
func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    var polls = 0
    while polls < 200 || DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return }
        polls += 1
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await condition())
}

private let hour: Int64 = 3_600_000

/// A manager on a manual wall clock (`now`) and manual retry clock, recording delivered updates.
private struct Harness {
    let network = GatedConfigTransport()
    let clock = ManualConfigClock()
    let now = Locked<Int64>(1_000_000_000)
    let updates = Locked<[(version: String?, freshness: ConfigFreshness)]>([])
    let manager: ConfigManager

    init() {
        let clock = clock
        let now = now
        manager = ConfigManager(
            transport: network, logger: ObserveLogger(debug: false), sleep: { try await clock.sleep($0) },
            now: { now.value })
    }

    func start(cachedVersion: String? = nil, freshness: ConfigFreshness? = nil) async {
        let updates = updates
        await manager.start(cachedVersion: cachedVersion, freshness: freshness) { fetched, freshness in
            updates.withLock { $0.append((fetched?.config.version, freshness)) }
        }
    }

    func advance(_ milliseconds: Int64) { now.withLock { $0 += milliseconds } }

    /// Releases the pending request and waits until the manager has finished handling it.
    func respond(_ response: ConfigResponse) async {
        await network.release(response)
        await eventually { await !manager.isFetching }
    }
}

@Suite struct ConfigManagerTests {
    @Test func freshCacheSkipsInitAndForegroundUntilExpiry() async {
        let harness = Harness()
        let now = harness.now.value
        await harness.start(
            cachedVersion: "cached", freshness: ConfigFreshness(fetchedAt: now - 1_000, expiresAt: now + hour))
        await harness.manager.refresh()
        #expect(await !harness.manager.isFetching)
        harness.advance(hour - 1)
        await harness.manager.refresh()
        #expect(await !harness.manager.isFetching)
        harness.advance(1)
        await harness.manager.refresh()
        await eventually { await harness.network.entityTags == [#""cached""#] }
        await harness.manager.stop()
        await harness.network.release(ConfigResponse(statusCode: nil))
    }

    @Test(
        arguments: [
            (nil, ConfigFreshness(fetchedAt: 0, expiresAt: .max)),  // freshness without a policy
            ("legacy", nil),  // policy cached by an SDK without freshness
            ("cached", ConfigFreshness(fetchedAt: 900_000_000, expiresAt: 999_999_999)),  // expired
            ("cached", ConfigFreshness(fetchedAt: 1_000_000_001, expiresAt: 2_000_000_000)),  // clock went back
            ("cached", ConfigFreshness(fetchedAt: 0, expiresAt: 2_000_000_000)),  // invalid fetch time
            ("cached", ConfigFreshness(fetchedAt: 999_999_999, expiresAt: 1_090_000_000)),  // span beyond 24 h
        ] as [(String?, ConfigFreshness?)])
    func staleCacheFetchesAtInit(cachedVersion: String?, freshness: ConfigFreshness?) async {
        let harness = Harness()
        await harness.start(cachedVersion: cachedVersion, freshness: freshness)
        await eventually { await harness.network.requests == 1 }
        #expect(await harness.network.entityTags == [cachedVersion.map { "\"\($0)\"" }])
        await harness.respond(
            ConfigResponse(statusCode: 200, body: #"{"version":"fresh"}"#, cacheControl: "max-age=600"))
        let now = harness.now.value
        #expect(harness.updates.value.map(\.version) == ["fresh"])
        #expect(harness.updates.value.last?.freshness == ConfigFreshness(fetchedAt: now, expiresAt: now + 600_000))
        harness.advance(600_000 - 1)
        await harness.manager.refresh()
        #expect(await !harness.manager.isFetching)
        harness.advance(1)
        await harness.manager.refresh()
        // The fetched version is the next entity tag.
        await eventually { await harness.network.entityTags.last == #""fresh""# }
        await harness.manager.stop()
        await harness.network.release(ConfigResponse(statusCode: nil))
    }

    @Test func notModifiedRenewsFreshnessAndKeepsPolicy() async {
        let harness = Harness()
        await harness.start(cachedVersion: "cached")
        await eventually { await harness.network.requests == 1 }
        await harness.respond(ConfigResponse(statusCode: 304, cacheControl: "public, max-age=900", age: "300"))
        let now = harness.now.value
        #expect(harness.updates.value.count == 1)
        #expect(harness.updates.value.first?.version == nil)
        #expect(harness.updates.value.first?.freshness == ConfigFreshness(fetchedAt: now, expiresAt: now + 600_000))
        harness.advance(599_999)
        await harness.manager.refresh()
        #expect(await !harness.manager.isFetching)
        await harness.manager.stop()
    }

    @Test func notModifiedWithoutCachedPolicyIsFailure() async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.respond(ConfigResponse(statusCode: 304))
        #expect(harness.updates.value.isEmpty)
        #expect(await harness.clock.delays.isEmpty)
        await harness.manager.stop()
    }

    @Test func failedAttemptKeepsStateAndRetriesOnLaterTriggerAfterGap() async {
        let harness = Harness()
        let expired = ConfigFreshness(fetchedAt: 0, expiresAt: 1)
        await harness.start(cachedVersion: "cached", freshness: expired)
        await eventually { await harness.network.requests == 1 }
        await harness.network.release(ConfigResponse(statusCode: 400))
        await eventually { await !harness.manager.isFetching }
        #expect(harness.updates.value.isEmpty)
        // Foreground storm while offline: one attempt per gap.
        for _ in 0..<5 {
            harness.advance(10_000)
            await harness.manager.refresh()
            #expect(await !harness.manager.isFetching)
        }
        harness.advance(ConfigManager.minAttemptGapMs - 50_000)
        await harness.manager.refresh()
        await eventually { await harness.network.requests == 2 }
        #expect(await harness.network.entityTags == [#""cached""#, #""cached""#])
        await harness.manager.stop()
        await harness.network.release(ConfigResponse(statusCode: nil))
    }

    @Test func singleRequestInFlight() async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        harness.advance(ConfigManager.minAttemptGapMs)
        await harness.manager.refresh()
        #expect(await harness.network.requests == 1)
        await harness.manager.stop()
        await harness.network.release(ConfigResponse(statusCode: nil))
    }

    @Test(
        arguments: [
            (nil, nil, 3_600_000),
            ("no-store", nil, 3_600_000),
            ("s-maxage=7200", nil, 3_600_000),
            ("max-age=600", nil, 600_000),
            ("public, MAX-AGE=\"1200\", s-maxage=60", "200", 1_000_000),
            ("max-age=600", "500", 300_000),
            ("max-age=0", nil, 300_000),
            ("max-age=172800", nil, 86_400_000),
            ("max-age=172800", "86400", 86_400_000),
            ("max-age=99999999999999999999", nil, 86_400_000),
            ("max-age=600", "99999999999999999999", 300_000),
            ("max-age=-9223372036854775808", "9223372036854775807", 300_000),
        ] as [(String?, String?, Int64)])  // swiftlint:disable:this large_tuple
    func ttlFromMaxAgeMinusAgeClampedOrDefault(cacheControl: String?, age: String?, ttl: Int64) {
        #expect(ConfigManager.ttlMs(cacheControl: cacheControl, age: age) == ttl)
    }

    @Test(arguments: [408, 429, 500, 503])
    func transientFailuresRetryOnFixedSchedule(status: Int) async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.network.release(ConfigResponse(statusCode: status))
        await eventually { await harness.clock.delays.contains(1_000) }
        await harness.clock.advance(999)
        #expect(await harness.network.requests == 1)
        await harness.clock.advance(1)
        await eventually { await harness.network.requests == 2 }
        await harness.network.release(ConfigResponse(statusCode: nil))
        await eventually { await harness.clock.delays.contains(3_000) }
        await harness.clock.advance(2_999)
        #expect(await harness.network.requests == 2)
        await harness.clock.advance(1)
        await eventually { await harness.network.requests == 3 }
        await harness.respond(ConfigResponse(statusCode: 200, body: #"{"version":"fresh"}"#))
        #expect(harness.updates.value.map(\.version) == ["fresh"])
        #expect(await harness.clock.delays == [1_000, 3_000])
        await harness.manager.stop()
    }

    @Test(arguments: [400, 401, 404, 408, 429, 503, 200])
    func permanentResponsesWaitForNextTrigger(status: Int) async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.respond(ConfigResponse(statusCode: status, body: "not-json", hasRetryAfter: true))
        #expect(await harness.clock.delays.isEmpty)
        #expect(harness.updates.value.isEmpty)
        await harness.manager.stop()
    }

    @Test(arguments: ["{}", "[]", #"{"version":""}"#, #"{"version":3}"#, "not-json"])
    func invalidPolicyIsNotRetried(body: String) async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.respond(ConfigResponse(statusCode: 200, body: body))
        #expect(await harness.clock.delays.isEmpty)
        #expect(harness.updates.value.isEmpty)
        await harness.manager.stop()
    }

    @Test func stoppingDuringBackoffCancelsAllFutureWork() async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.network.release(ConfigResponse(statusCode: nil))
        await eventually { await harness.clock.delays.contains(1_000) }
        await harness.manager.stop()
        await harness.clock.advance(1_000_000)
        harness.advance(hour)
        await harness.manager.refresh()
        await harness.start()
        #expect(await harness.network.requests == 1)
        #expect(harness.updates.value.isEmpty)
    }

    @Test func lateResponseAfterStopIsDropped() async {
        let harness = Harness()
        await harness.start()
        await eventually { await harness.network.requests == 1 }
        await harness.manager.stop()
        await harness.respond(ConfigResponse(statusCode: 200, body: #"{"version":"late"}"#))
        #expect(harness.updates.value.isEmpty)
    }
}
