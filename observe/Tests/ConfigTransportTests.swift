import Foundation
import Testing

@testable import CorbadoObserve

private class ConfigURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Locked<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["rEtRy-AfTeR": ""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"version":"test"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct ConfigTransportTests {
    @Test func configGetUsesNoCacheBoundedTimeoutAndRecognizesRetryAfter() async throws {
        let url = try #require(URL(string: "https://proxy.example/config/pro-test?sdkName=observe-ios"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigURLProtocol.self]
        let transport = HttpConfigTransport(url: url, configuration: configuration)
        let response = await transport.fetch()
        transport.shutdown()
        let request = try #require(ConfigURLProtocol.requests.value.last)
        #expect(request.url == url)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "X-Corbado-Observe-Config") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
        #expect(response.statusCode == 503)
        #expect(response.hasRetryAfter)
        #expect(!response.retryable)
    }
}

/// Stalls the actual URLSession task until its timeout or cancellation calls stopLoading.
class GatedConfigURLProtocol: URLProtocol, @unchecked Sendable {
    static let started = Locked<Set<URL>>([])
    static let stopped = Locked<Set<URL>>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.started.withLock { _ = $0.insert(url) } }
    }

    override func stopLoading() {
        if let url = request.url { Self.stopped.withLock { _ = $0.insert(url) } }
    }
}

extension ConfigTransportTests {
    @Test(.timeLimit(.minutes(1))) func stalledURLSessionHonorsTenSecondResourceTimeout() async throws {
        let url = try #require(URL(string: "https://timeout.example/config/pro-test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedConfigURLProtocol.self]
        let transport = HttpConfigTransport(url: url, configuration: configuration)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let response = await transport.fetch()
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        #expect(elapsed >= 9_000_000_000)
        #expect(elapsed < 20_000_000_000)
        #expect(response.statusCode == nil)
        #expect(response.retryable)
        await eventually { GatedConfigURLProtocol.stopped.value.contains(url) }
        transport.shutdown()
    }
    @Test(.timeLimit(.minutes(1))) func shutdownRacingRequestCreationNeverUsesInvalidatedSession() async throws {
        let url = try #require(URL(string: "https://shutdown-race.example/config/pro-test"))
        for _ in 0..<50 {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GatedConfigURLProtocol.self]
            let transport = HttpConfigTransport(url: url, configuration: configuration)
            let request = Task { await transport.fetch() }
            transport.shutdown()
            #expect(await request.value.statusCode == nil)
            // A request admitted after shutdown must return locally, without asking URLSession
            // to create a task (which raises an Objective-C exception on an invalidated session).
            #expect(await transport.fetch().statusCode == nil)
        }
    }

}
