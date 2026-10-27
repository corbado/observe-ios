import Foundation
import Testing

@testable import CorbadoObserve

extension TrackerIntegrationTests {
    @Test(arguments: [false, true]) @MainActor
    func rawErrorPolicyGatesTraversalAndOnlyEnrichesErrorSteps(enabled: Bool) async throws {
        UserDefaults(suiteName: "corbado_observe")?.set(
            "{\"version\":\"raw-test\",\"rawErrors\":\(enabled)}", forKey: "cbo_sdk_config")
        let (tracker, transport) = await makeTracker()
        let diagnostic = ObservedDiagnosticError(domain: "provider", code: 42)
        let options = StepOptions(
            userReference: UserReference(userId: "user"), explicitTimestamp: 1234,
            rawError: .error(diagnostic))
        let step = tracker.passwordLoginOperation().customStep("test")
        step.start(options: options)
        step.finished(options: options)
        tracker.trackCustom("subflow_step_error", options: options)
        step.errorTyped(["error": ["code": "normalized"]], options: options)
        tracker.destroy()
        await tracker.awaitTermination()
        let events = transport.events
        #expect(events.count == 4)
        for event in events.prefix(3) {
            #expect(event.data.objectValue?["stepData"]?.objectValue?["rawError"] == nil)
        }
        let event = try #require(events.last)
        let data = try #require(event.data.objectValue?["stepData"]?.objectValue)
        #expect(data["error"] == ["code": "normalized"])
        #expect((data["rawError"] != nil) == enabled)
        #expect(diagnostic.reads.value == (enabled ? 1 : 0))
        #expect(!diagnostic.readOnMain.value)
        #expect(event.timestamp == 1234)
        #expect(event.user?.userId == "user")
        #expect(events.map(\.seq) == [0, 1, 2, 3])
        if enabled {
            #expect(data["rawError"]?.objectValue?["value"]?.objectValue?["code"] == 42)
        }
    }

    @Test func rawErrorDefaultAndCollectionSwitchNeverTraverseDiagnostics() async {
        let (tracker, transport) = await makeTracker()
        let diagnostic = ObservedDiagnosticError(domain: "provider", code: 42)
        let options = StepOptions(rawError: .error(diagnostic))
        let step = tracker.passwordLoginOperation().customStep("test")
        step.errorTyped(["error": ["code": "kept"]], options: options)
        tracker.setCollectionEnabled(false)
        step.errorTyped(["error": ["code": "dropped"]], options: options)
        tracker.destroy()
        await tracker.awaitTermination()
        #expect(diagnostic.reads.value == 0)
        #expect(transport.events.count == 1)
        #expect(transport.events.first?.data.objectValue?["stepData"]?.objectValue?["rawError"] == nil)
    }

    @Test func remoteRawErrorPolicyAppliesLive() async throws {
        await Self.finishLastTracker()
        let transport = CapturingTransport()
        let options = ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid")
        let diagnostic = ObservedDiagnosticError(domain: "provider", code: 42)
        let stepOptions = StepOptions(rawError: .error(diagnostic))

        let enabling = GatedConfigTransport()
        let first = ObserveTracker(options: options, transport: transport, configTransport: enabling)
        Self.lastTracker.value = first
        first.start()
        await eventually { await enabling.requests == 1 }
        first.passwordLoginOperation().customStep("before_enable").errorTyped([:], options: stepOptions)
        first.flush()
        await eventually { transport.events.count == 1 }
        let enabled = #"{"version":"enabled","rawErrors":true}"#
        await enabling.release(ConfigResponse(statusCode: 200, body: enabled))
        await eventually { ObservePrefs().sdkConfigCache?.body == enabled }
        first.passwordLoginOperation().customStep("after_enable").errorTyped([:], options: stepOptions)
        first.destroy()
        await first.awaitTermination()
        #expect(diagnostic.reads.value == 1)

        // Expired: the next start applies the cached policy and refreshes it.
        ObservePrefs().sdkConfigCache?.freshness = ConfigFreshness(fetchedAt: 1, expiresAt: 2)
        let disabling = GatedConfigTransport()
        let second = ObserveTracker(options: options, transport: transport, configTransport: disabling)
        Self.lastTracker.value = second
        second.start()
        await eventually { await disabling.requests == 1 }
        second.passwordLoginOperation().customStep("cached_enable").errorTyped([:], options: stepOptions)
        second.flush()
        await eventually { transport.events.count == 3 }
        let disabled = #"{"version":"disabled","rawErrors":false}"#
        await disabling.release(ConfigResponse(statusCode: 200, body: disabled))
        await eventually { ObservePrefs().sdkConfigCache?.body == disabled }
        second.passwordLoginOperation().customStep("after_disable").errorTyped([:], options: stepOptions)
        second.destroy()
        await second.awaitTermination()
        #expect(diagnostic.reads.value == 2)
        let rawValues = transport.events.map { $0.data.objectValue?["stepData"]?.objectValue?["rawError"] != nil }
        #expect(rawValues == [false, true, true, false])
    }

    @Test func rawErrorsOverrideWinsOverCachedAndLivePolicy() async {
        await Self.finishLastTracker()
        let cached = #"{"version":"cached","rawErrors":true}"#
        UserDefaults(suiteName: "corbado_observe")?.set(cached, forKey: "cbo_sdk_config")
        let transport = CapturingTransport()
        let network = GatedConfigTransport()
        let options = ObserveOptions(
            projectId: "pro-test", apiBaseUrl: "https://example.invalid",
            sdkConfig: SdkConfigOverrides(rawErrors: false))
        let diagnostic = ObservedDiagnosticError(domain: "provider", code: 42)
        let stepOptions = StepOptions(rawError: .error(diagnostic))
        let tracker = ObserveTracker(options: options, transport: transport, configTransport: network)
        Self.lastTracker.value = tracker
        tracker.start()
        await eventually { await network.requests == 1 }
        tracker.passwordLoginOperation().customStep("cached_policy").errorTyped([:], options: stepOptions)
        tracker.flush()
        await eventually { transport.events.count == 1 }
        let live = #"{"version":"live","rawErrors":true}"#
        await network.release(ConfigResponse(statusCode: 200, body: live))
        await eventually { ObservePrefs().sdkConfigCache?.body == live }
        tracker.passwordLoginOperation().customStep("live_policy").errorTyped([:], options: stepOptions)
        tracker.destroy()
        await tracker.awaitTermination()
        #expect(transport.events.count == 2)
        #expect(transport.events.allSatisfy { $0.data.objectValue?["stepData"]?.objectValue?["rawError"] == nil })
        #expect(diagnostic.reads.value == 0)
    }

    @Test func rawErrorsReachAllCeremonyHelpers() async {
        UserDefaults(suiteName: "corbado_observe")?.set(
            "{\"version\":\"raw-test\",\"rawErrors\":true}", forKey: "cbo_sdk_config")
        let (tracker, transport) = await makeTracker()
        let error = NSError(domain: "provider", code: 42)
        let options = StepOptions(rawError: .error(error))
        tracker.systemCredentialOperation().begin(requested: [.passkey]).failed(error, options: options)
        tracker.passkeyLoginOperation().begin(specType: .noIdentifier).ceremonyFailed(error, options: options)
        tracker.passkeyEnrollmentOperation().begin().ceremonyFailed(error, options: options)
        tracker.passwordLoginOperation().cui.ceremonyFailed(error, options: options)
        tracker.passwordLoginOperation().customStep("backend").error(error, options: options)
        tracker.destroy()
        await tracker.awaitTermination()
        let errors = transport.events.filter { $0.name == "subflow_step_error" }
        #expect(errors.count == 5)
        for event in errors {
            let data = event.data.objectValue?["stepData"]?.objectValue
            #expect(data?["error"]?.objectValue?["code"] == "provider:42")
            #expect(data?["rawError"]?.objectValue?["value"]?.objectValue?["code"] == 42)
        }
    }
}

private final class ObservedDiagnosticError: NSError, @unchecked Sendable {
    let reads = Locked(0)
    let readOnMain = Locked(false)

    override var userInfo: [String: Any] {
        reads.withLock { $0 += 1 }
        if Thread.isMainThread { readOnMain.value = true }
        return [NSLocalizedDescriptionKey: "Diagnostic"]
    }
}
