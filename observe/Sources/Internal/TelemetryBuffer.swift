import Foundation

/// Buffer for the diagnostic telemetry stream (SDK/integration-side messages, never classified as
/// auth-flow events). Entries ride along in the `telemetry` array of the next event batch.
///
/// Bounded and deduplicated per process: a persistent fault (blocked storage, downed endpoint)
/// cannot flood the stream. Device-info collection failures also land here; this SDK does not
/// use the wire `collectionErrors` field.
///
/// All access is on the SDK's internal actor.
final class TelemetryBuffer {
    private var entries: [WireTelemetryEntry] = []
    private var seenMessages: Set<String> = []
    private let enabled: () -> Bool
    private let currentSessionId: () -> String?

    init(enabled: @escaping () -> Bool, currentSessionId: @escaping () -> String?) {
        self.enabled = enabled
        self.currentSessionId = currentSessionId
    }

    func report(_ level: String, _ message: String) {
        guard enabled(), entries.count < Self.maxBuffered else { return }
        let trimmed = String(message.prefix(Self.maxMessageLength))
        guard seenMessages.insert("\(level):\(trimmed)").inserted else { return }

        entries.append(
            WireTelemetryEntry(
                id: Uuid.v7(),
                level: level,
                message: trimmed,
                ts: Int64(Date().timeIntervalSince1970 * 1000)
            ))
    }

    var isNotEmpty: Bool { !entries.isEmpty }

    func sessionId() -> String? { currentSessionId() }

    /// Entries to attach to the next batch (capped); removed only after successful delivery.
    func peek() -> [WireTelemetryEntry] { Array(entries.prefix(Self.maxPerBatch)) }

    func removeDelivered(_ delivered: [WireTelemetryEntry]) {
        let ids = Set(delivered.map(\.id))
        entries.removeAll { ids.contains($0.id) }
    }

    private static let maxBuffered = 100
    private static let maxPerBatch = 50
    private static let maxMessageLength = 512
}
