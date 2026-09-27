import Foundation

/// Two-tier session identity:
///
/// - **sessionId** (long horizon): persisted with a last-activity timestamp; rotated when
///   inactivity exceeds the configured window. Rotation is checked at process start and on
///   foreground transitions. Survives app launches until inactivity rotates it.
/// - **processId** (short-lived): a uuidv7 minted at process start, memory-only, sent in the
///   `tabId` wire field so the backend can split interleaved streams of one session by process
///   incarnation.
///
/// The **seq** counter exists solely to order events sharing the same millisecond timestamp; it
/// is deliberately in-memory only, starting at 0 per process. Two process incarnations cannot
/// emit events within the same millisecond, so `(timestamp, seq)` stays a correct sort key across
/// restarts without persisting anything. A continuing session may therefore reuse seq values
/// after a restart (distinguishable by `tabId`), which the backend must not read as parallel
/// streams for app traffic.
///
/// All methods run on the SDK's internal actor.
final class SessionManager {
    let processId: String = Uuid.v7()

    private(set) var sessionId: String = ""

    private let prefs: ObservePrefs
    private let inactivityWindowMs: () -> Int64
    private let now: () -> Int64

    private var seq: Int64 = 0
    private var lastActivityWriteAt: Int64 = 0

    init(
        prefs: ObservePrefs,
        inactivityWindowMs: @escaping () -> Int64,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.prefs = prefs
        self.inactivityWindowMs = inactivityWindowMs
        self.now = now
    }

    func start() {
        let stored = prefs.sessionId
        let lastActivity = prefs.sessionLastActivityAt
        let currentTime = now()

        if let stored, currentTime - lastActivity <= inactivityWindowMs() {
            sessionId = stored
        } else {
            rotate()
        }
        persistActivity(force: true)
    }

    /// Rotation check for foreground transitions; rotates when the inactivity window elapsed.
    func checkRotation() {
        let currentTime = now()
        if currentTime - prefs.sessionLastActivityAt > inactivityWindowMs() {
            rotate()
        }
        persistActivity(force: true)
    }

    /// Force a new session (public `resetSession`). Returns the new id.
    func reset() -> String {
        rotate()
        persistActivity(force: true)
        return sessionId
    }

    /// Allocates the next sequence number and refreshes the activity timestamp (throttled write).
    func nextSeq() -> Int64 {
        let current = seq
        seq = current + 1
        persistActivity(force: false)
        return current
    }

    private func rotate() {
        sessionId = Uuid.v7()
        seq = 0
        prefs.updateSession(id: sessionId, lastActivityAt: now())
    }

    private func persistActivity(force: Bool) {
        let currentTime = now()
        if !force, currentTime - lastActivityWriteAt < Self.activityWriteIntervalMs { return }
        lastActivityWriteAt = currentTime
        prefs.updateSession(id: sessionId, lastActivityAt: currentTime)
    }

    /// Throttle for last-activity persistence; every event would otherwise write defaults.
    private static let activityWriteIntervalMs: Int64 = 30_000
}
