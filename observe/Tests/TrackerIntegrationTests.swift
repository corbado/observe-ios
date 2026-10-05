import Foundation
import Testing

@testable import CorbadoObserve

/// End-to-end tracker tests over a capturing transport: public API in, wire batches out.
final class CapturingTransport: Transporting {
    nonisolated func shutdown() {}

    let batches = Locked<[WireEventBatch]>([])

    func send(_ batch: WireEventBatch, configVersionHeader: String?) async -> TransportResult {
        batches.withLock { $0.append(batch) }
        return TransportResult(statusCode: 200)
    }

    var events: [WireEvent] { batches.value.flatMap(\.events) }
    var lows: [WireLowEvent] { batches.value.flatMap { $0.lows ?? [] } }
    var telemetry: [WireTelemetryEntry] { batches.value.flatMap { $0.telemetry ?? [] } }
}

/// Holds the first HTTP response until the test releases it; all later requests succeed.
private actor GatedTransport: Transporting {
    nonisolated func shutdown() {}

    private var response: CheckedContinuation<TransportResult, Never>?
    private(set) var batches: [WireEventBatch] = []

    func send(_ batch: WireEventBatch, configVersionHeader: String?) async -> TransportResult {
        batches.append(batch)
        if batches.count == 1 {
            return await withCheckedContinuation { response = $0 }
        }
        return TransportResult(statusCode: 200)
    }

    func release(status: Int?) {
        response?.resume(returning: TransportResult(statusCode: status))
        response = nil
    }
}

@Suite(.serialized) struct TrackerIntegrationTests {
    /// The previous test's tracker: drained (destroy + pump termination) before the next test
    /// touches shared state, so a finished test can't write prefs/outbox underneath it.
    private static let lastTracker = Locked<ObserveTracker?>(nil)

    init() async {
        await Self.finishLastTracker()
        UserDefaults(suiteName: "corbado_observe")?.removePersistentDomain(forName: "corbado_observe")
        let outboxDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("corbado_observe", isDirectory: true)
        try? FileManager.default.removeItem(at: outboxDir)
    }

    func makeTracker(
        options: ObserveOptions = ObserveOptions(
            projectId: "pro-test", apiBaseUrl: "https://example.invalid", defaultTags: ["env": "test"])
    ) async -> (ObserveTracker, CapturingTransport) {
        let transport = CapturingTransport()
        let tracker = await makeTracker(options: options, transport: transport)
        return (tracker, transport)
    }

    private func makeTracker(options: ObserveOptions, transport: any Transporting) async -> ObserveTracker {
        await Self.finishLastTracker()
        let tracker = ObserveTracker(options: options, transport: transport)
        tracker.start()
        Self.lastTracker.value = tracker
        return tracker
    }

    private static func finishLastTracker() async {
        if let previous = Self.lastTracker.withLock({ stored -> ObserveTracker? in
            let value = stored
            stored = nil
            return value
        }) {
            previous.destroy()
            await previous.awaitTermination()
        }
    }

    @Test func overlappingBackgroundFlushesFinishAfterDelivery() async {
        let transport = GatedTransport()
        var config = SdkConfig.default
        config.telemetry = true
        let core = TrackerCore(
            options: ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid"),
            logger: ObserveLogger(debug: false), transport: transport,
            configBox: Locked(config), sessionIdBox: Locked("session"), dataPolicyBox: Locked(nil),
            signal: { _ in })
        await core.reportTelemetry(level: "info", message: "background test")
        await core.flush(.manual)
        for _ in 0..<200 {
            if await !transport.batches.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let completions = Locked(0)
        for _ in 0..<2 {
            await core.flush(.background, onFinished: { completions.withLock { $0 += 1 } })
        }
        #expect(completions.value == 0)
        #expect(await transport.batches.count == 1)
        await transport.release(status: 200)
        await core.destroyCore()
        #expect(completions.value == 2)
        #expect(await transport.batches.count == 1)
    }

    @Test(arguments: [200, 400, 503], [false, true])
    func recordsPersistWhileDeliveryStalls(status: Int, paused: Bool) async {
        let transport = GatedTransport()
        let tracker = await makeTracker(
            options: ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid"),
            transport: transport)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("corbado_observe", isDirectory: true)
        let file = directory.appendingPathComponent("cbo_outbox.jsonl")
        tracker.trackCustom("before_send")
        tracker.flush()
        for _ in 0..<200 {
            if await !transport.batches.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await transport.batches.count == 1)

        for index in 0..<10 { tracker.trackCustom("during_send_\(index)") }
        tracker.flush()
        var persisted: [Outbox.Entry] = []
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: file) {
                persisted = data.split(separator: 0x0A).compactMap {
                    try? WireJson.decoder.decode(Outbox.Entry.self, from: Data($0))
                }
            }
            if persisted.count == 11 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Assert before releasing HTTP: this fails when the mailbox awaits delivery.
        #expect(persisted.map(\.event.name) == ["before_send"] + (0..<10).map { "during_send_\($0)" })
        #expect(Set(persisted.map(\.event.id)).count == 11)
        #expect(persisted.map(\.event.seq) == Array(0...10).map(Int64.init))
        #expect(await transport.batches.count == 1)

        // Termination must join the stalled request and drain later events, not clear them
        // when the old batch is acknowledged or rejected.
        if paused { tracker.setTransportEnabled(false) }
        tracker.destroy()
        let terminated = Locked(false)
        let shutdown = Task {
            await tracker.awaitTermination()
            terminated.value = true
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(!terminated.value)
        await transport.release(status: status)
        await shutdown.value
        let delivered = await transport.batches.flatMap(\.events)
        let stopped = paused || status == 503
        #expect(Set(delivered.map(\.id)) == Set((stopped ? Array(persisted.prefix(1)) : persisted).map(\.event.id)))
        #expect(delivered.filter { $0.name.hasPrefix("during_send_") }.count == (stopped ? 0 : 10))
        #expect(terminated.value)

        // Exhausting the default one-attempt budget retains the rejected first batch for
        // recovery; pausing also retains all events recorded during that request.
        let expectedRecovery = persisted.filter {
            status == 503
                || (paused && $0.event.name.hasPrefix("during_send_"))
        }
        let recovery = CapturingTransport()
        let restarted = await makeTracker(
            options: ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid"),
            transport: recovery)
        restarted.destroy()
        await restarted.awaitTermination()
        #expect(recovery.events.map(\.id) == expectedRecovery.map(\.event.id))
        #expect(recovery.events.map(\.meta?.tabId) == expectedRecovery.map(\.event.meta?.tabId))
        let remaining = (try? Data(contentsOf: file)) ?? Data()
        #expect(remaining.isEmpty)
    }

    /// Flush and poll until at least `eventCount` events (and `lowCount` lows) arrived.
    func drain(
        _ tracker: ObserveTracker, _ transport: CapturingTransport, eventCount: Int, lowCount: Int = 0
    ) async -> [WireEvent] {
        for _ in 0..<100 {
            tracker.flush()
            try? await Task.sleep(nanoseconds: 50_000_000)
            if transport.events.count >= eventCount, transport.lows.count >= lowCount {
                break
            }
        }
        return transport.events
    }

    @Test func flowEventsCarryVocabularyTagsAndMeta() async {
        let (tracker, transport) = await makeTracker(
            options: ObserveOptions(
                projectId: "pro-test", apiBaseUrl: "https://example.invalid",
                defaultTags: ["env": "test"], applicationId: "MyApp"))

        tracker.setScreen("LoginScreen")
        tracker.flowStarted("login", touchpoint: "app-start")
        tracker.flowFinished("login", options: StepOptions(userReference: UserReference(userId: "usr-1")))

        let events = await drain(tracker, transport, eventCount: 2)
        #expect(events.map(\.name) == ["flow_started", "flow_finished"])

        let started = events[0]
        #expect(started.type == "predefined")
        #expect(started.data.objectValue?["flowName"]?.stringValue == "login")
        #expect(started.data.objectValue?["touchpoint"]?.stringValue == "app-start")
        #expect(started.tags?["applicationId"] == "myapp")
        #expect(started.tags?["env"] == "test")
        #expect(started.meta?.tabId?.isEmpty == false)
        #expect(started.meta?.trackingSourcePath == "LoginScreen")

        let finished = events[1]
        #expect(finished.data.objectValue?["userId"]?.stringValue == "usr-1")
        #expect(finished.user?.userId == "usr-1")
        #expect(finished.seq > started.seq)
        #expect(transport.batches.value.allSatisfy { $0.sdk.name == "observe-ios" })
    }

    @Test func customEventsAndExplicitTimestamps() async {
        let (tracker, transport) = await makeTracker()

        tracker.trackCustom("my_custom", data: ["key": .string("value")])
        tracker.flowStarted("login", options: StepOptions(explicitTimestamp: 1_755_000_000_000))

        let events = await drain(tracker, transport, eventCount: 2)
        #expect(events[0].type == "custom")
        #expect(events[0].name == "my_custom")
        #expect(events[1].timestamp == 1_755_000_000_000)
    }

    @Test func passwordLoginOperationVocabulary() async {
        let (tracker, transport) = await makeTracker()

        let op = tracker.passwordLoginOperation()
        op.start(specType: .withIdentifier)
        op.postResponse.start()
        op.postResponse.errorTyped(.invalidPassword)

        let events = await drain(tracker, transport, eventCount: 3)
        #expect(events.map(\.name) == ["subflow_started", "subflow_step_started", "subflow_step_error"])
        let startedData = events[0].data.objectValue
        #expect(startedData?["subflowType"]?.stringValue == "password-login")
        #expect(startedData?["actor"]?.stringValue == "user")
        #expect(startedData?["explicitSpecType"]?.stringValue == "password-with-identifier")
        #expect(events[1].data.objectValue?["stepName"]?.stringValue == "post-response")
        let errorData = events[2].data.objectValue
        #expect(errorData?["stepData"]?.objectValue?["code"]?.stringValue == "invalid_password")
    }

    @Test func passkeyLoginSanitizesAssertionAtChokePoint() async throws {
        let (tracker, transport) = await makeTracker()

        let attempt = tracker.passkeyLoginOperation().begin(specType: .knownIdentifier)
        attempt.ceremonyFinished(
            assertionResponse: #"{"id":"cred","response":{"signature":"SECRET","clientDataJSON":"CDJ"}}"#)

        let events = await drain(tracker, transport, eventCount: 3)
        let finished = try #require(events.first { $0.name == "subflow_step_finished" })
        let assertion = try #require(
            finished.data.objectValue?["stepData"]?.objectValue?["assertionResponse"]?.stringValue)
        #expect(!assertion.contains("SECRET"))
        #expect(assertion.contains("CDJ"))
    }

    @Test func systemCredentialProbeFlagsTheCeremonyStartAsNoInteraction() async throws {
        let (tracker, transport) = await makeTracker()

        _ = tracker.systemCredentialOperation().begin(
            requested: [.passkey, .password], preferImmediatelyAvailable: true)

        let events = await drain(tracker, transport, eventCount: 2)
        let ceremony = try #require(events.first { $0.name == "subflow_step_started" })
        #expect(ceremony.data.objectValue?["ignoreAsInteraction"] == .bool(true))
        let stepData = ceremony.data.objectValue?["stepData"]?.objectValue
        #expect(stepData?["preferImmediatelyAvailableCredentials"] == .bool(true))
    }

    @Test func systemCredentialStartCarriesSpecTypeAndNarrowing() async throws {
        let (tracker, transport) = await makeTracker()

        let attempt = tracker.systemCredentialOperation().begin(
            requested: [.passkey, .password], autoTriggered: true)
        attempt.resolved(.passkey)

        let events = await drain(tracker, transport, eventCount: 3)
        #expect(events.map(\.name) == ["subflow_started", "subflow_step_started", "subflow_step_finished"])
        let started = events[0]
        #expect(started.data.objectValue?["explicitSpecType"]?.stringValue == "passkey-password-auto")
        #expect(started.data.objectValue?["ignoreAsInteraction"] == .bool(true))
        let resolvedData = events[2].data.objectValue?["stepData"]?.objectValue
        #expect(resolvedData?["narrowedSpecType"]?.stringValue == "passkey")
    }

    @Test func systemCredentialSilentFailureIsEmittedAfterStart() async throws {
        let (tracker, transport) = await makeTracker()
        let attempt = tracker.systemCredentialOperation().begin(
            requested: [.passkey], preferImmediatelyAvailable: true)
        let starts = await drain(tracker, transport, eventCount: 2)
        #expect(starts.map(\.name) == ["subflow_started", "subflow_step_started"])
        #expect(starts[0].data.objectValue?["explicitSpecType"] == .string("passkey-auto"))

        attempt.failed(NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001))
        let events = await drain(tracker, transport, eventCount: 1)
        let error = try #require(events.first { $0.name == "subflow_step_error" })
        let payload = error.data.objectValue?["stepData"]?.objectValue?["error"]?.objectValue
        #expect(payload?["code"] == .string("com.apple.AuthenticationServices.AuthorizationError:1001"))
    }

    @Test func systemCredentialAutomaticStartIsIgnoredWithoutImmediatePreference() async throws {
        let (tracker, transport) = await makeTracker()
        _ = tracker.systemCredentialOperation().begin(requested: [.passkey], preferImmediatelyAvailable: false)
        let events = await drain(tracker, transport, eventCount: 2)
        let start = try #require(events.first { $0.name == "subflow_step_started" })
        #expect(start.data.objectValue?["ignoreAsInteraction"] == .bool(true))
        #expect(
            start.data.objectValue?["stepData"]?.objectValue?["preferImmediatelyAvailableCredentials"] == .bool(false))
    }

    @Test func systemCredentialButtonStartRemainsInteractionWithImmediatePreference() async throws {
        let (tracker, transport) = await makeTracker()
        let attempt = tracker.systemCredentialOperation().begin(
            requested: [.passkey], preferImmediatelyAvailable: true, autoTriggered: false)
        attempt.failed(NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001))
        let events = await drain(tracker, transport, eventCount: 3)
        #expect(events[0].data.objectValue?["explicitSpecType"] == .string("passkey"))
        #expect(events[0].data.objectValue?["ignoreAsInteraction"] == nil)
        #expect(events[1].data.objectValue?["ignoreAsInteraction"] == .bool(true))
        #expect(events[2].name == "subflow_step_error")
    }

    @Test func fieldObserverLowsBatchAndAttribute() async throws {
        let (tracker, transport) = await makeTracker()

        let op = tracker.passwordLoginOperation()
        op.start()
        // Typing stretch: single-character growth batches into one `input` low.
        for length in 1...5 {
            op.passwordField.changed(newLength: length)
        }
        // Announced fill on the identifier: bulk insert becomes `af-fill` with the actor.
        op.identifierField.applicationFill(actor: "password-manager")
        op.identifierField.changed(newLength: 20)
        // Step start flushes the typing batch.
        op.postResponse.start()

        _ = await drain(tracker, transport, eventCount: 2, lowCount: 2)
        let lows = transport.lows
        let input = try #require(lows.first { $0.lowType == "input" })
        #expect(input.fieldType == "password-login")
        let fill = try #require(lows.first { $0.lowType == "af-fill" })
        #expect(fill.fieldType == "provide-identifier")
        #expect(fill.actor == "password-manager")
    }

    @Test func collectionKillSwitchDropsAtSource() async {
        let (tracker, transport) = await makeTracker()

        tracker.setCollectionEnabled(false)
        tracker.flowStarted("dropped")
        tracker.setCollectionEnabled(true)
        tracker.flowStarted("kept")

        let events = await drain(tracker, transport, eventCount: 1)
        #expect(events.map(\.name) == ["flow_started"])
        #expect(events[0].data.objectValue?["flowName"]?.stringValue == "kept")
    }

    @Test func dataPolicyRidesEveryBatchOnceSet() async {
        let (tracker, transport) = await makeTracker()
        tracker.trackCustom("unset")
        _ = await drain(tracker, transport, eventCount: 1)
        #expect(transport.batches.value.allSatisfy { $0.meta?.dataPolicy == nil })

        tracker.setDataPolicy(0)
        tracker.setDataPolicy(256)
        tracker.setDataPolicy(-1)
        #expect(tracker.getDataPolicy() == 0)
        tracker.trackCustom("set")
        _ = await drain(tracker, transport, eventCount: 2)
        let batch = transport.batches.value.first { $0.events.contains { $0.name == "set" } }
        #expect(batch?.meta?.dataPolicy == 0)
    }

    @Test func dataPolicyPersistsPerProjectAcrossRelaunch() async {
        /// Relaunches (makeTracker terminates the previous tracker first) and returns the code
        /// stamped on the batch carrying a fresh event.
        func relaunch(_ projectId: String, dataPolicy: Int?) async -> (ObserveTracker, Int??) {
            let (tracker, transport) = await makeTracker(
                options: ObserveOptions(
                    projectId: projectId, apiBaseUrl: "https://example.invalid", dataPolicy: dataPolicy))
            tracker.trackCustom("probe")
            _ = await drain(tracker, transport, eventCount: 1)
            let batch = transport.batches.value.first { $0.events.contains { $0.name == "probe" } }
            return (tracker, batch.map(\.meta?.dataPolicy))
        }

        _ = await relaunch("pro-test", dataPolicy: 2)
        let (restored, restoredCode) = await relaunch("pro-test", dataPolicy: nil)
        #expect(restoredCode == .some(2))
        #expect(restored.getDataPolicy() == 2)

        _ = await relaunch("pro-test", dataPolicy: 3)
        #expect(await relaunch("pro-test", dataPolicy: nil).1 == .some(3))

        let (other, otherCode) = await relaunch("pro-other", dataPolicy: nil)
        #expect(otherCode == .some(nil))
        #expect(other.getDataPolicy() == nil)
    }

    @Test func eventsShareOneSessionAndOrderBySeq() async {
        let (tracker, transport) = await makeTracker()

        for index in 0..<5 {
            tracker.trackCustom("event_\(index)")
        }
        let events = await drain(tracker, transport, eventCount: 5)
        #expect(events.map(\.name) == (0..<5).map { "event_\($0)" })
        #expect(events.map(\.seq) == events.map(\.seq).sorted())
        #expect(Set(transport.batches.value.map(\.sessionID)).count == 1)
    }
}
