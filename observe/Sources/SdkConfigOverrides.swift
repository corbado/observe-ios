import Foundation

/// Optional native reliability policy. Explicit fields win over cached/fetched policy and defaults.
/// Supplying every field (including version and every retry field) bypasses config fetching and caching.
public struct SdkConfigOverrides: Sendable {
    public var version: String?
    public var flushIntervalMs: Int64?
    public var sessionInactivityMs: Int64?
    public var telemetry: Bool?
    public var flushOnTelemetry: Bool?
    public var flushOnFlowTypeFinished: [String]?
    public var deviceInfoCollectorTimeoutMs: Int64?
    public var flushOnBackground: Bool?
    public var lows: Bool?
    public var retry: RetryConfigOverrides?

    public init(
        version: String? = nil,
        flushIntervalMs: Int64? = nil,
        sessionInactivityMs: Int64? = nil,
        telemetry: Bool? = nil,
        flushOnTelemetry: Bool? = nil,
        flushOnFlowTypeFinished: [String]? = nil,
        deviceInfoCollectorTimeoutMs: Int64? = nil,
        flushOnBackground: Bool? = nil,
        lows: Bool? = nil,
        retry: RetryConfigOverrides? = nil
    ) {
        self.version = version
        self.flushIntervalMs = flushIntervalMs
        self.sessionInactivityMs = sessionInactivityMs
        self.telemetry = telemetry
        self.flushOnTelemetry = flushOnTelemetry
        self.flushOnFlowTypeFinished = flushOnFlowTypeFinished
        self.deviceInfoCollectorTimeoutMs = deviceInfoCollectorTimeoutMs
        self.flushOnBackground = flushOnBackground
        self.lows = lows
        self.retry = retry
    }

    var isComplete: Bool {
        version != nil
            && flushIntervalMs != nil
            && sessionInactivityMs != nil
            && telemetry != nil
            && flushOnTelemetry != nil
            && flushOnFlowTypeFinished != nil
            && deviceInfoCollectorTimeoutMs != nil
            && flushOnBackground != nil
            && lows != nil
            && retry?.maxAttempts != nil && retry?.baseDelayMs != nil && retry?.maxDelayMs != nil
    }

    func resolve(over server: SdkConfig?) -> SdkConfig {
        var result = server ?? .default
        result.version = version ?? result.version
        result.flushIntervalMs = flushIntervalMs ?? result.flushIntervalMs
        result.sessionInactivityMs = sessionInactivityMs ?? result.sessionInactivityMs
        result.telemetry = telemetry ?? result.telemetry
        result.flushOnTelemetry = flushOnTelemetry ?? result.flushOnTelemetry
        result.flushOnFlowTypeFinished = flushOnFlowTypeFinished ?? result.flushOnFlowTypeFinished
        result.deviceInfoCollectorTimeoutMs = deviceInfoCollectorTimeoutMs ?? result.deviceInfoCollectorTimeoutMs
        result.flushOnBackground = flushOnBackground ?? result.flushOnBackground
        result.lows = lows ?? result.lows
        result.retryMaxAttempts = retry?.maxAttempts ?? result.retryMaxAttempts
        result.retryBaseDelayMs = retry?.baseDelayMs ?? result.retryBaseDelayMs
        result.retryMaxDelayMs = retry?.maxDelayMs ?? result.retryMaxDelayMs
        result.flushIntervalMs = min(max(result.flushIntervalMs, 200), 60_000)
        result.sessionInactivityMs = min(max(result.sessionInactivityMs, 60_000), 86_400_000)
        result.deviceInfoCollectorTimeoutMs = min(max(result.deviceInfoCollectorTimeoutMs, 100), 10_000)
        result.flushOnFlowTypeFinished = Array(result.flushOnFlowTypeFinished.prefix(20))
        result.retryMaxAttempts = min(max(result.retryMaxAttempts, 1), 10)
        result.retryBaseDelayMs = min(max(result.retryBaseDelayMs, 0), 60_000)
        result.retryMaxDelayMs = max(result.retryBaseDelayMs, min(max(result.retryMaxDelayMs, 0), 300_000))
        return result
    }
}

/// Overrides individual event-delivery retry settings; config fetching has its own fixed retry policy.
public struct RetryConfigOverrides: Sendable {
    public var maxAttempts: Int?
    public var baseDelayMs: Int64?
    public var maxDelayMs: Int64?

    public init(maxAttempts: Int? = nil, baseDelayMs: Int64? = nil, maxDelayMs: Int64? = nil) {
        self.maxAttempts = maxAttempts
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
    }
}
