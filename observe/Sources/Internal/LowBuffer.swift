/// Buffer for low events: high-volume ambient UI evidence (autofill affordances, bulk fills)
/// that never participates in flow classification directly; the backend translates it into
/// insights. Entries ride along in the `lows` array of the next event batch.
///
/// In-memory only (no outbox write-through): lows are best-effort evidence, and unlike auth
/// events, losing a process worth of them is acceptable. Bounded so a hot signal source cannot grow
/// the batch without limit.
///
/// All access is on the SDK's internal actor.
final class LowBuffer {
    private var entries: [WireLowEvent] = []
    private let enabled: () -> Bool
    private let currentSessionId: () -> String?

    init(enabled: @escaping () -> Bool, currentSessionId: @escaping () -> String?) {
        self.enabled = enabled
        self.currentSessionId = currentSessionId
    }

    func report(_ low: WireLowEvent) {
        guard enabled(), entries.count < Self.maxBuffered else { return }
        entries.append(low)
    }

    var isNotEmpty: Bool { !entries.isEmpty }

    func sessionId() -> String? { currentSessionId() }

    /// Entries to attach to the next batch (capped); removed only after successful delivery.
    func peek() -> [WireLowEvent] { Array(entries.prefix(Self.maxPerBatch)) }

    func removeDelivered(_ delivered: [WireLowEvent]) {
        guard !delivered.isEmpty else { return }
        entries.removeAll { delivered.contains($0) }
    }

    private static let maxBuffered = 200
    private static let maxPerBatch = 100
}
