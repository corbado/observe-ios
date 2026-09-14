import Foundation

/// Server-driven SDK reliability config — the mechanism for changing SDK behavior in the field
/// without app releases (risky behavior ships dark, defaults are conservative).
///
/// Cached policy is available immediately; a separate GET refreshes and applies it live.
///
/// Parsing is defensive: unknown fields are ignored and missing fields keep their defaults,
/// clamped to sane bounds — a malformed config can never disable delivery or produce a hot loop.
struct SdkConfig: Sendable {
    /// Content-derived version assigned by the server and attached to batch metadata.
    var version: String = ""
    /// How often the queue flushes, ms. Native default is battery-frugal (2s vs web's 500ms).
    var flushIntervalMs: Int64 = 2_000
    /// Inactivity window after which the session id rotates, ms.
    var sessionInactivityMs: Int64 = 30 * 60 * 1_000
    /// Master switch for the diagnostic telemetry stream.
    var telemetry: Bool = true
    /// When true, enqueuing a telemetry entry triggers an immediate flush.
    var flushOnTelemetry: Bool = false
    /// Flow types whose `flow_finished`/`flow_auto_finished` triggers an immediate flush.
    var flushOnFlowTypeFinished: [String] = []
    /// Per-field timeout for device info collection, ms. Parsed for config parity; iOS collects
    /// synchronously.
    var deviceInfoCollectorTimeoutMs: Int64 = 1_000
    /// Native flush-trigger switch: flush when the app leaves the foreground. Defaults ON.
    var flushOnBackground: Bool = true
    /// Master switch for the low-event stream (autofill signals etc.). Defaults ON — the real
    /// gate is the integration wiring collectors at all; this is the server-side kill switch for
    /// data volume.
    var lows: Bool = true
    var retryMaxAttempts: Int = 1
    var retryBaseDelayMs: Int64 = 0
    var retryMaxDelayMs: Int64 = 0

    static let `default` = SdkConfig()

    /// Parses a config response body (web- or app-shaped JSON). Returns nil when the body is
    /// not a versioned JSON object — the caller keeps its current config.
    static func parse(_ body: String) -> SdkConfig? {
        guard let data = body.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let root = parsed as? [String: Any],
            let version = root["version"] as? String, !version.isEmpty
        else { return nil }
        let defaults = SdkConfig.default

        var config = SdkConfig()
        config.version = version
        config.flushIntervalMs = clamp(long(root, "flushIntervalMs") ?? defaults.flushIntervalMs, 200, 60_000)
        config.sessionInactivityMs = clamp(
            long(root, "sessionInactivityMs") ?? defaults.sessionInactivityMs, 60_000, 24 * 60 * 60 * 1_000)
        config.telemetry = root["telemetry"] as? Bool ?? defaults.telemetry
        config.flushOnTelemetry = root["flushOnTelemetry"] as? Bool ?? defaults.flushOnTelemetry
        config.flushOnFlowTypeFinished = Array(
            ((root["flushOnFlowTypeFinished"] as? [Any])?.compactMap { $0 as? String } ?? [])
                .prefix(maxFlushFlowTypes))
        config.deviceInfoCollectorTimeoutMs = clamp(
            long(root, "deviceInfoCollectorTimeoutMs") ?? defaults.deviceInfoCollectorTimeoutMs, 100, 10_000)
        config.flushOnBackground = root["flushOnBackground"] as? Bool ?? defaults.flushOnBackground
        config.lows = root["lows"] as? Bool ?? defaults.lows

        let retry = root["retry"] as? [String: Any]
        config.retryMaxAttempts =
            retry.flatMap { long($0, "maxAttempts") }.map { Int(clamp($0, 1, 10)) }
            ?? defaults.retryMaxAttempts
        config.retryBaseDelayMs =
            retry.flatMap { long($0, "baseDelayMs") }.map { clamp($0, 0, 60_000) }
            ?? defaults.retryBaseDelayMs
        config.retryMaxDelayMs =
            retry.flatMap { long($0, "maxDelayMs") }.map { clamp($0, 0, 5 * 60_000) }
            ?? defaults.retryMaxDelayMs
        return config
    }

    private static let maxFlushFlowTypes = 20

    // Primitive coercion mirrors kotlinx-serialization's `jsonPrimitive` reads: numbers accept
    // string form, strings accept numeric form.
    private static func long(_ object: [String: Any], _ key: String) -> Int64? {
        switch object[key] {
        case let value as Int64: return value
        case let value as Int: return Int64(value)
        case let value as Double:
            // JSON numbers can exceed Int64 before field-level clamping gets a chance to run.
            guard value.isFinite else { return nil }
            if value >= Double(Int64.max) { return Int64.max }
            if value <= Double(Int64.min) { return Int64.min }
            return Int64(value)
        case let value as NSNumber: return value.int64Value
        case let value as String: return Int64(value)
        default: return nil
        }
    }

    private static func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        min(max(value, low), high)
    }
}
