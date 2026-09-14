import Foundation

/// Why a delivery attempt happened. Native vocabulary — free-form string on the wire, deliberately
/// disjoint from the web values where the trigger differs (`background` instead of `pagehide`).
enum FlushReason: String {
    case timer
    case backoff
    case recovery
    case background
    case flowFinished = "flow-finished"
    case telemetry
    case destroy
    case manual
}

/// Timer and event-triggered wake-ups carry no queue state: they only ask the owning actor
/// to schedule delivery. The delivery task itself owns retries and their backoff delays.
enum QueueSignal: Sendable {
    case timerTick
    case recoveryFlush
    case flowFinishedFlush
}

/// Timer-driven event queue with a durable outbox mirror.
///
/// - `enqueue` appends to the in-memory pending list AND writes through to the `Outbox`, so events
///   survive process death; successful delivery removes them from both.
/// - A timer flushes every `flushIntervalMs`; additional triggers: app backgrounding, configured
///   flow-type completion, telemetry escalation, manual flush, destroy.
/// - Failed sends retry with exponential backoff on 5xx/408/429/network errors (per config, off by
///   default); other 4xx are permanent rejections and drop the batch. Retry state belongs to the
///   delivery attempt, not to the events in it, so events, telemetry and lows share one budget and
///   one backoff chain, reset by any delivery. Events whose budget is exhausted stay in the outbox
///   for the next process start's recovery flush.
/// - Batches carry at most 50 events of one session per request.
///
/// All state is confined to the owning `TrackerCore` actor; the entry points must only be called
/// from it.
final class EventQueue {
    private let transport: any Transporting
    private let outbox: Outbox
    /// Live policy, read on the owning SDK actor.
    private let config: () -> SdkConfig
    private let sdkInfo: WireSdkInfo
    private let telemetryBuffer: TelemetryBuffer
    private let lowBuffer: LowBuffer
    private let logger: ObserveLogger
    /// Routes a wake-up back into the owning actor, which schedules delivery.
    private let signal: @Sendable (QueueSignal) -> Void

    private var pending: [Outbox.Entry] = []
    private var timerTask: Task<Void, Never>?
    private var inFlight = false

    /// Consecutive retryable delivery failures. Counting the attempt rather than the events in it
    /// is what makes a telemetry-/lows-only batch obey the same budget and backoff as any other.
    private var consecutiveFailures = 0
    var transportEnabled = true

    init(
        transport: any Transporting,
        outbox: Outbox,
        config: @escaping () -> SdkConfig,
        sdkInfo: WireSdkInfo,
        telemetryBuffer: TelemetryBuffer,
        lowBuffer: LowBuffer,
        logger: ObserveLogger,
        signal: @escaping @Sendable (QueueSignal) -> Void
    ) {
        self.transport = transport
        self.outbox = outbox
        self.config = config
        self.sdkInfo = sdkInfo
        self.telemetryBuffer = telemetryBuffer
        self.lowBuffer = lowBuffer
        self.logger = logger
        self.signal = signal
    }

    func start() {
        // Recover events a previous process never delivered.
        let recovered = outbox.readAll()
        pending.append(contentsOf: recovered)

        updateConfig()
        if !recovered.isEmpty { signal(.recoveryFlush) }
    }

    /// Restart only the periodic timer; pending events and the delivery task's backoff stay intact.
    func updateConfig() {
        timerTask?.cancel()
        let signal = signal
        let intervalMs = config().flushIntervalMs
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(intervalMs, 1)) * 1_000_000)
                guard !Task.isCancelled else { return }
                signal(.timerTick)
            }
        }
    }

    func enqueue(sessionId: String, event: WireEvent, finishedFlowName: String? = nil) {
        let entry = Outbox.Entry(sessionId: sessionId, event: event)
        pending.append(entry)
        outbox.append(entry)

        if let finishedFlowName, config().flushOnFlowTypeFinished.contains(finishedFlowName) {
            signal(.flowFinishedFlush)
        }
    }

    func flush(_ reason: FlushReason, isolation: isolated (any Actor)? = #isolation) async {
        guard transportEnabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        await drain(reason, isolation: isolation)
    }

    func stopTimer() {
        timerTask?.cancel()
    }

    private func drain(_ reason: FlushReason, isolation: isolated (any Actor)?) async {
        var flushReason = reason
        while transportEnabled {
            let cfg = config()
            let telemetry = telemetryBuffer.peek()
            let lows = lowBuffer.peek()
            if pending.isEmpty, telemetry.isEmpty, lows.isEmpty { return }

            guard let (sessionId, batchEntries) = nextSessionBatch() else { return }

            let batch = WireEventBatch(
                sessionID: sessionId,
                events: batchEntries.map(\.event),
                sdk: sdkInfo,
                lows: lows.isEmpty ? nil : lows,
                telemetry: telemetry.isEmpty ? nil : telemetry,
                meta: WireBatchMeta(
                    sent: Int64(Date().timeIntervalSince1970 * 1000),
                    transport: "native",
                    flushReason: flushReason.rawValue,
                    retryCount: consecutiveFailures > 0 ? consecutiveFailures : nil,
                    configVersion: cfg.version.isEmpty ? nil : cfg.version
                )
            )

            let result = await transport.send(batch)

            let status = result.statusCode
            switch status {
            case .some(200...299):
                consecutiveFailures = 0
                removePending(batchEntries)
                outbox.remove(Set(batchEntries.map(\.event.id)))
                telemetryBuffer.removeDelivered(telemetry)
                lowBuffer.removeDelivered(lows)
                if batchEntries.isEmpty { return }  // telemetry-/lows-only batch delivered

            case _ where isRetryable(status):
                guard let backoff = handleRetryableFailure(batchEntries, status) else { return }
                // Backoff belongs to this delivery task. Every flush trigger, including
                // destroy, joins the same retry chain instead of bypassing its delay/budget.
                try? await Task.sleep(nanoseconds: UInt64(max(backoff, 0)) * 1_000_000)
                flushReason = .backoff

            default:
                // Permanent rejection — the server understood and refused. Drop the batch.
                telemetryBuffer.removeDelivered(telemetry)
                lowBuffer.removeDelivered(lows)
                logger.warn("batch rejected with status \(status ?? -1); dropping \(batchEntries.count) events")
                telemetryBuffer.report(
                    "error", "batch rejected status=\(status ?? -1) size=\(batchEntries.count)")
                removePending(batchEntries)
                outbox.remove(Set(batchEntries.map(\.event.id)))
                if batchEntries.isEmpty { return }
            }
        }
    }

    /// One request carries at most batchSize auth events from the oldest pending session.
    /// A batch containing only in-memory evidence uses that buffer's session instead.
    private func nextSessionBatch() -> (String, [Outbox.Entry])? {
        if let first = pending.first {
            return (first.sessionId, Array(pending.filter { $0.sessionId == first.sessionId }.prefix(Self.batchSize)))
        }
        guard let sessionId = telemetryBuffer.sessionId() else { return nil }
        return (sessionId, [])
    }

    /// Retryable: network error (nil), 5xx, 408 (request timeout), 429 (rate limited).
    private func isRetryable(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status >= 500 || status == 408 || status == 429
    }

    private func handleRetryableFailure(_ batchEntries: [Outbox.Entry], _ status: Int?) -> Int64? {
        let cfg = config()
        consecutiveFailures += 1

        if consecutiveFailures >= cfg.retryMaxAttempts {
            // Budget exhausted: stop the backoff chain. Events keep their outbox copy for the
            // next process start; telemetry and lows keep theirs for the next timer flush.
            logger.debug("delivery failed (status=\(status ?? -1)), retry budget exhausted; deferring to recovery")
            removePending(batchEntries)
            return nil
        }

        let backoff = backoffFor(attempt: consecutiveFailures, cfg: cfg)
        logger.debug("delivery failed (status=\(status ?? -1)), retrying in \(backoff)ms")

        return backoff
    }

    private func removePending(_ entries: [Outbox.Entry]) {
        let ids = Set(entries.map(\.event.id))
        pending.removeAll { ids.contains($0.event.id) }
    }

    private static let batchSize = 50
}

/// Highest exponent applied to the base delay; past it the shift overflows the base.
private let maxBackoffExponent = 16

/// Delay before retry `attempt`, 1-based. The exponent is clamped at both ends so a garbage
/// attempt count can neither wrap the shift nor overflow the base.
func backoffFor(attempt: Int, cfg: SdkConfig) -> Int64 {
    let exponent = min(max(attempt - 1, 0), maxBackoffExponent)
    return min(cfg.retryBaseDelayMs << exponent, cfg.retryMaxDelayMs)
}
