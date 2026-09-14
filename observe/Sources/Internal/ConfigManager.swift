import Foundation

protocol ConfigTransporting: Sendable {
    func fetch() async -> ConfigResponse
    func shutdown()
}

struct ConfigResponse: Sendable {
    var statusCode: Int?
    var body: String?
    var hasRetryAfter = false

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

    func fetch() async -> ConfigResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
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
                                hasRetryAfter: response.value(forHTTPHeaderField: "Retry-After") != nil))
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

/// Owns remote policy work independently of the SDK mailbox and event delivery. Timers belong to
/// the refresh cycle, so retries never postpone the next regular refresh.
actor ConfigManager {
    typealias Sleep = @Sendable (Int64) async throws -> Void
    private let transport: any ConfigTransporting
    private let sleep: Sleep
    private let logger: ObserveLogger
    private var refreshTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var stopped = false

    var isFetching: Bool { requestTask != nil }

    init(
        transport: any ConfigTransporting,
        logger: ObserveLogger,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.transport = transport
        self.logger = logger
        self.sleep = sleep
    }

    func start(onConfig: @escaping @Sendable (SdkConfig, String) async -> Void) {
        guard !stopped, refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                // The 10s transport timeout bounds a cycle to well below the 10min refresh.
                if requestTask == nil {
                    requestTask = Task {
                        await fetch(onConfig: onConfig)
                        requestTask = nil
                    }
                }
                do { try await sleep(600_000) } catch { return }
            }
        }
    }

    private func fetch(onConfig: @escaping @Sendable (SdkConfig, String) async -> Void) async {
        for attempt in 0..<3 {
            guard !stopped, !Task.isCancelled else { return }
            let response = await transport.fetch()
            guard !stopped, !Task.isCancelled else { return }
            if let status = response.statusCode, (200..<300).contains(status) {
                // Invalid policy and malformed JSON are permanent failures for this refresh.
                guard let body = response.body, let config = SdkConfig.parse(body) else {
                    logger.debug("invalid SDK config response")
                    return
                }
                await onConfig(config, body)
                return
            }
            logger.debug("SDK config fetch failed (status=\(response.statusCode ?? -1))")
            guard response.retryable, attempt < 2 else { return }
            do { try await sleep(attempt == 0 ? 1_000 : 3_000) } catch { return }
        }
    }

    func stop() {
        stopped = true
        refreshTask?.cancel()
        requestTask?.cancel()
        transport.shutdown()
    }
}
