import Foundation

/// Shared per-tracker engine behind the operations' `FieldObserver` handles. Owns everything that
/// is screen- rather than field-scoped: typing batches and announced-fill windows per fieldType,
/// the shown-duration bookkeeping for the manual affordance signals (iOS cannot observe the
/// AutoFill bar, so these are the only affordance source), and the arming state of the window
/// lows.
///
/// Batches auto-flush on any subflow step start (submission = typing stretch over), flow finish
/// or reset, and app background.
///
/// Ambient lows: field `focus`/`blur` (forwarded by the integration) and `window-blur`/
/// `window-focus` from the app's active-state churn. The Face ID gate of a system fill and every
/// system sheet show up as that pair. Window lows are armed while a ceremony is running (the
/// operations' typed ceremony helpers) or a field is focused. A blur that was emitted always gets
/// its focus.
///
/// Thread-safe (handles are called synchronously from UI code); never throws into the host app.
final class AutofillEngine: @unchecked Sendable {
    private struct AnnouncedFill {
        var at: Int64
        var actor: String
    }

    private struct InputBatch {
        var firstAt: Int64
        var lastAt: Int64
    }

    private let lock = NSLock()
    private var announcedFills: [String: AnnouncedFill] = [:]
    private var inputBatches: [String: InputBatch] = [:]
    private var shownAt: [String: Int64] = [:]
    /// Window-low arming: handles currently focused, ceremonies currently running.
    private var focusedFields: Set<ObjectIdentifier> = []
    private var runningCeremonies = 0
    /// A `window-blur` went out and its `window-focus` is still due.
    private var blurEmitted = false

    /// Set once right after tracker construction (the tracker owns the engine).
    private weak var tracker: ObserveTracker?

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func attach(_ tracker: ObserveTracker) {
        self.tracker = tracker
    }

    // MARK: - Field-handle entry points

    func fieldChanged(fieldType: String, previousLength: Int, newLength: Int, paste: Bool) {
        let delta = newLength - previousLength
        if delta == 0 { return }
        let now = now()

        if delta >= Self.minBulkDelta {
            // Consumed on match: one announcement covers one bulk change, so a later paste on the
            // same field must not inherit the announced actor.
            let announcedActor: String? = lock.withLocked {
                guard let fill = announcedFills.removeValue(forKey: fieldType),
                    now - fill.at <= Self.appFillWindowMs
                else { return nil }
                return fill.actor
            }
            flushInputBatch(fieldType)
            if let announcedActor {
                tracker?.low("af-fill", fieldType: fieldType, actor: announcedActor, explicitTimestamp: now)
            } else {
                tracker?.low(
                    "big-input-add", fieldType: fieldType, actor: paste ? Self.actorUser : nil, explicitTimestamp: now)
            }
            return
        }

        if delta <= -Self.minBulkDelta {
            flushInputBatch(fieldType)
            tracker?.low("big-input-rem", fieldType: fieldType, explicitTimestamp: now)
            return
        }

        lock.withLocked {
            if var batch = inputBatches[fieldType] {
                batch.lastAt = now
                inputBatches[fieldType] = batch
            } else {
                inputBatches[fieldType] = InputBatch(firstAt: now, lastAt: now)
            }
        }
    }

    func applicationFill(fieldType: String, actor: String) {
        lock.withLocked { announcedFills[fieldType] = AnnouncedFill(at: now(), actor: actor) }
    }

    /// First-responder change of a field; a system fill moves it across the filled fields.
    func fieldFocus(handle: ObjectIdentifier, fieldType: String, focused: Bool) {
        lock.withLocked {
            if focused { focusedFields.insert(handle) } else { focusedFields.remove(handle) }
        }
        tracker?.low(focused ? "focus" : "blur", fieldType: fieldType, explicitTimestamp: now())
    }

    // MARK: - Ceremony hooks (typed ceremony helpers of the operations)

    func ceremonyArmed() {
        lock.withLocked { runningCeremonies += 1 }
    }

    func ceremonySettled() {
        lock.withLocked { runningCeremonies -= 1 }
    }

    func shown(fieldType: String) {
        lock.withLocked { shownAt[fieldType] = now() }
        tracker?.low("af-shown", fieldType: fieldType)
    }

    func hidden(fieldType: String) {
        let now = now()
        let duration = lock.withLocked { shownAt.removeValue(forKey: fieldType).map { now - $0 } }
        tracker?.low("af-hidden", fieldType: fieldType, durationMs: duration)
    }

    func unavailable(fieldType: String) {
        tracker?.low("af-unavailable", fieldType: fieldType)
    }

    // MARK: - Tracker hooks

    /// `willResignActive`: a system sheet, Face ID or an app switch took the screen.
    func windowBlur() {
        let armed = lock.withLocked { () -> Bool in
            guard runningCeremonies > 0 || !focusedFields.isEmpty else { return false }
            blurEmitted = true
            return true
        }
        if armed { tracker?.low("window-blur", explicitTimestamp: now()) }
    }

    /// `didBecomeActive`: closes an emitted blur.
    func windowFocus() {
        let due = lock.withLocked { () -> Bool in
            defer { blurEmitted = false }
            return blurEmitted
        }
        if due { tracker?.low("window-focus", explicitTimestamp: now()) }
    }

    /// Any subflow step started (submission implies the typing stretch ended), flow finish or
    /// reset, app background.
    func flushBatches() {
        let fieldTypes = lock.withLocked { Array(inputBatches.keys) }
        fieldTypes.forEach(flushInputBatch)
    }

    private func flushInputBatch(_ fieldType: String) {
        guard let batch = lock.withLocked({ inputBatches.removeValue(forKey: fieldType) }) else { return }
        tracker?.low(
            "input",
            fieldType: fieldType,
            durationMs: batch.lastAt - batch.firstAt,
            explicitTimestamp: batch.firstAt
        )
    }

    private static let actorUser = "user"

    /// Minimum single-change length growth that counts as a bulk insertion, not typing.
    private static let minBulkDelta = 3

    /// Bulk change within this window after an announced fill carries the announced actor.
    private static let appFillWindowMs: Int64 = 1_000
}

extension NSLock {
    func withLocked<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
