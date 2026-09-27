import Foundation
import Testing

@testable import CorbadoObserve

/// Runs against a dedicated UserDefaults suite (cleared per test) so the tracker integration
/// suite (which owns the real `corbado_observe` suite and runs in parallel) cannot bleed in.
@Suite(.serialized) struct SessionManagerTests {
    private static let suite = "corbado_observe_test_session"

    init() {
        UserDefaults(suiteName: Self.suite)?.removePersistentDomain(forName: Self.suite)
    }

    private func manager(now: Locked<Int64>, windowMs: Int64 = 1_000) -> SessionManager {
        SessionManager(
            prefs: ObservePrefs(suiteName: Self.suite),
            inactivityWindowMs: { windowMs },
            now: { now.value })
    }

    @Test func continuesRecentSessionAcrossRestart() {
        let now = Locked<Int64>(10_000)
        let first = manager(now: now)
        first.start()
        let sessionId = first.sessionId
        #expect(!sessionId.isEmpty)

        now.value = 10_500  // within the window
        let second = manager(now: now)
        second.start()
        #expect(second.sessionId == sessionId)
    }

    @Test func rotatesAfterInactivityWindow() {
        let now = Locked<Int64>(10_000)
        let first = manager(now: now)
        first.start()
        let sessionId = first.sessionId

        now.value = 20_000  // way past the window
        let second = manager(now: now)
        second.start()
        #expect(second.sessionId != sessionId)
    }

    @Test func checkRotationRotatesOnlyWhenElapsed() {
        let now = Locked<Int64>(10_000)
        let manager = manager(now: now)
        manager.start()
        let sessionId = manager.sessionId

        now.value = 10_800
        manager.checkRotation()
        #expect(manager.sessionId == sessionId)

        now.value = 12_000
        manager.checkRotation()
        #expect(manager.sessionId != sessionId)
    }

    @Test func seqOrdersWithinProcessAndResetsOnRotation() {
        let now = Locked<Int64>(10_000)
        let manager = manager(now: now)
        manager.start()
        #expect(manager.nextSeq() == 0)
        #expect(manager.nextSeq() == 1)
        #expect(manager.nextSeq() == 2)

        _ = manager.reset()
        #expect(manager.nextSeq() == 0)
    }

    @Test func processIdIsStablePerInstance() {
        let now = Locked<Int64>(10_000)
        let manager = manager(now: now)
        #expect(manager.processId == manager.processId)
        #expect(!manager.processId.isEmpty)
    }
}
