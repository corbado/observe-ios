import Foundation

/// Abstraction over event delivery so tests can stub the network.
protocol Transporting: Sendable {
    /// Release transport resources after the final delivery/retry chain has finished.
    func shutdown()
    func send(_ batch: WireEventBatch) async -> TransportResult
}

struct TransportResult: Sendable {
    /// HTTP status, or nil when the request never produced a response (network error).
    var statusCode: Int?
}

/// Event delivery over a private ephemeral `URLSession` — no cookies, no cache, no third-party
/// networking: the SDK is embedded in other companies' apps, and every dependency is a potential
/// conflict.
///
/// Never throws (failures return a result with `statusCode == nil`, treated as retryable network
/// errors by the queue).
final class HttpTransport: Transporting {
    private let url: URL
    private let logger: ObserveLogger
    private let session: URLSession

    init(url: URL, logger: ObserveLogger) {
        self.url = url
        self.logger = logger
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.connectTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ batch: WireEventBatch) async -> TransportResult {
        guard let body = try? WireJson.encoder.encode(batch) else {
            return TransportResult(statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return TransportResult(statusCode: nil)
            }
            return TransportResult(statusCode: status)
        } catch {
            logger.debug("send failed: \(error.localizedDescription)")
            return TransportResult(statusCode: nil)
        }
    }

    func shutdown() {
        // Graceful invalidation releases session resources without cancelling requests.
        session.finishTasksAndInvalidate()
    }

    private static let connectTimeout: TimeInterval = 10
    private static let resourceTimeout: TimeInterval = 30
}
