import Foundation

protocol ConfigTransporting: Sendable {
    func fetch(ifNoneMatch: String?) async -> ConfigResponse
    func shutdown()
}

struct ConfigResponse: Sendable {
    var statusCode: Int?
    var body: String?
    var hasRetryAfter = false
    var cacheControl: String?
    var age: String?

    var retryable: Bool {
        guard let statusCode else { return true }
        return !hasRetryAfter && (statusCode == 408 || statusCode == 429 || statusCode >= 500)
    }
}

/// Dedicated URLSession so configuration cannot queue behind ingestion or hold its resources.
final class HttpConfigTransport: ConfigTransporting {
    private let url: URL
    private let session: URLSession
    private struct State {
        var stopped = false
        var task: URLSessionDataTask?
    }
    private let state = Locked(State())

    init(url: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.url = url
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func fetch(ifNoneMatch: String?) async -> ConfigResponse {
        // The SDK's persisted copy is the only cache; the platform HTTP cache stays bypassed.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        let requestToSend = request
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // URLSession's async convenience API creates its task after an executor hop.
                // Serialize task creation with invalidation to avoid a post-shutdown exception.
                state.withLock { state in
                    guard !state.stopped, !Task.isCancelled else {
                        continuation.resume(returning: ConfigResponse(statusCode: nil))
                        return
                    }
                    let task = session.dataTask(with: requestToSend) { data, response, error in
                        guard error == nil, let response = response as? HTTPURLResponse else {
                            continuation.resume(returning: ConfigResponse(statusCode: nil))
                            return
                        }
                        continuation.resume(
                            returning: ConfigResponse(
                                statusCode: response.statusCode,
                                body: data.flatMap { String(data: $0, encoding: .utf8) },
                                hasRetryAfter: response.value(forHTTPHeaderField: "Retry-After") != nil,
                                cacheControl: response.value(forHTTPHeaderField: "Cache-Control"),
                                age: response.value(forHTTPHeaderField: "Age")))
                    }
                    state.task = task
                    task.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.task?.cancel() }
        }
    }

    func shutdown() {
        state.withLock { state in
            state.stopped = true
            session.invalidateAndCancel()
        }
    }

}

/// Wall-clock epoch ms of the last successful fetch (200 or 304) and of its expiry.
struct ConfigFreshness: Sendable, Equatable {
    var fetchedAt: Int64
    var expiresAt: Int64
}

/// Owns remote policy work independently of the SDK mailbox and event delivery.
/// Init and app foreground trigger a fetch once the cached policy has expired.
actor ConfigManager {
    typealias Sleep = @Sendable (Int64) async throws -> Void
    /// Receives a fetched policy with its body, or nil when a 304 confirmed the cached one.
    typealias OnConfig = @Sendable ((config: SdkConfig, body: String)?, ConfigFreshness) async -> Void

    static let minAttemptGapMs: Int64 = 60_000
    static let defaultTtlMs: Int64 = 3_600_000
    static let minTtlSeconds: Int64 = 300
    static let maxTtlSeconds: Int64 = 86_400

    private let transport: any ConfigTransporting
    private let sleep: Sleep
    private let now: @Sendable () -> Int64
    private let logger: ObserveLogger
    private var onConfig: OnConfig?
    private var cachedVersion: String?
    private var freshness: ConfigFreshness?
    /// In memory only: bounds attempts during foreground storms while offline.
    private var lastAttemptAt: Int64?
    private var requestTask: Task<Void, Never>?
    private var stopped = false

    var isFetching: Bool { requestTask != nil }

    init(
        transport: any ConfigTransporting,
        logger: ObserveLogger,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.transport = transport
        self.logger = logger
        self.sleep = sleep
        self.now = now
    }

    /// `cachedVersion` belongs to the persisted policy; nil when there is none.
    func start(cachedVersion: String?, freshness: ConfigFreshness?, onConfig: @escaping OnConfig) {
        guard !stopped, self.onConfig == nil else { return }
        self.cachedVersion = cachedVersion
        self.freshness = freshness
        self.onConfig = onConfig
        refresh()
    }

    /// Freshness check: fetches only a stale policy, one request at a time, at most once per gap.
    func refresh() {
        guard !stopped, let onConfig, requestTask == nil else { return }
        let now = self.now()
        // A clock moved backwards makes both windows elapse instead of pinning them.
        if let lastAttemptAt, now >= lastAttemptAt, now - lastAttemptAt < Self.minAttemptGapMs { return }
        if cachedVersion != nil, let freshness, isFresh(freshness, now: now) { return }
        lastAttemptAt = now
        requestTask = Task { [weak self] in await self?.fetch(onConfig: onConfig) }
    }

    private func fetch(onConfig: OnConfig) async {
        defer { requestTask = nil }
        // The backend's policy version is its entity tag.
        let entityTag = cachedVersion.map { "\"\($0)\"" }
        for attempt in 0..<3 {
            guard !stopped, !Task.isCancelled else { return }
            let response = await transport.fetch(ifNoneMatch: entityTag)
            guard !stopped, !Task.isCancelled else { return }
            if response.statusCode == 304, cachedVersion != nil {
                await onConfig(nil, renewFreshness(response))
                return
            }
            if let status = response.statusCode, (200..<300).contains(status) {
                // Invalid policy and malformed JSON are permanent failures for this attempt.
                guard let body = response.body, let config = SdkConfig.parse(body) else {
                    logger.debug("invalid SDK config response")
                    return
                }
                cachedVersion = config.version
                await onConfig((config, body), renewFreshness(response))
                return
            }
            logger.debug("SDK config fetch failed (status=\(response.statusCode ?? -1))")
            guard response.retryable, attempt < 2 else { return }
            do { try await sleep(attempt == 0 ? 1_000 : 3_000) } catch { return }
        }
    }

    /// Times outside the TTL bounds are corrupt and count as expired.
    private func isFresh(_ freshness: ConfigFreshness, now: Int64) -> Bool {
        // Ordered so the span subtraction only sees positive values.
        freshness.fetchedAt > 0 && now >= freshness.fetchedAt && now < freshness.expiresAt
            && freshness.expiresAt - freshness.fetchedAt <= Self.maxTtlSeconds * 1000
    }

    private func renewFreshness(_ response: ConfigResponse) -> ConfigFreshness {
        let fetchedAt = now()
        let renewed = ConfigFreshness(
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt + Self.ttlMs(cacheControl: response.cacheControl, age: response.age))
        freshness = renewed
        return renewed
    }

    /// `max-age` minus `Age`, clamped to [5 min, 24 h]; 1 h without `max-age` (e.g. `no-store`).
    static func ttlMs(cacheControl: String?, age: String?) -> Int64 {
        let maxAge = (cacheControl ?? "").split(separator: ",").lazy.compactMap { directive -> Int64? in
            let parts = directive.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "max-age"
            else { return nil }
            return deltaSeconds(parts[1])
        }.first
        guard let maxAge else { return defaultTtlMs }
        // Both non-negative, so the difference cannot overflow.
        let remaining = maxAge - (age.flatMap(deltaSeconds) ?? 0)
        return min(max(remaining, minTtlSeconds), maxTtlSeconds) * 1000
    }

    /// Non-negative seconds; integers beyond Int64 saturate.
    private static func deltaSeconds(_ text: some StringProtocol) -> Int64? {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let value = Int64(digits) { return max(value, 0) }
        let unsigned = digits.hasPrefix("-") ? digits.dropFirst() : Substring(digits)
        guard !unsigned.isEmpty, unsigned.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return digits.hasPrefix("-") ? 0 : .max
    }

    func stop() {
        stopped = true
        requestTask?.cancel()
        transport.shutdown()
    }
}
