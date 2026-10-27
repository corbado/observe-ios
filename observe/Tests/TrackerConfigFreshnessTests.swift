import Foundation
import Testing

@testable import CorbadoObserve

extension TrackerIntegrationTests {
    private func makeConfigCore(
        _ network: GatedConfigTransport, configBox: Locked<SdkConfig> = Locked(.default)
    ) -> TrackerCore {
        TrackerCore(
            options: ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid"),
            logger: ObserveLogger(debug: false), transport: CapturingTransport(), configTransport: network,
            configBox: configBox, sessionIdBox: Locked(nil), dataPolicyBox: Locked(nil), signal: { _ in })
    }

    @Test func legacyCacheRevalidatesOnceAndStaysFreshAcrossStarts() async throws {
        let cached = #"{"version":"cached","telemetry":false}"#
        UserDefaults(suiteName: "corbado_observe")?.set(cached, forKey: "cbo_sdk_config")
        let network = GatedConfigTransport()
        let first = makeConfigCore(network)
        await first.start()
        await eventually { await network.requests == 1 }
        #expect(await network.entityTags == [#""cached""#])
        await network.release(ConfigResponse(statusCode: 304, cacheControl: "max-age=600"))
        await eventually { ObservePrefs().sdkConfigCache != nil }
        let record = try #require(ObservePrefs().sdkConfigCache)
        #expect(record.endpoint == "https://example.invalid/v1/observe/config/pro-test?sdkName=observe-ios")
        #expect(record.body == cached)
        #expect(record.freshness.expiresAt - record.freshness.fetchedAt == 600_000)
        #expect(ObservePrefs().legacySdkConfigJson == nil)
        await first.destroyCore()

        let idle = GatedConfigTransport()
        let configBox = Locked(SdkConfig.default)
        let second = makeConfigCore(idle, configBox: configBox)
        await second.start()
        await second.refreshConfig()
        #expect(configBox.value.version == "cached")
        #expect(!configBox.value.telemetry)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await idle.requests == 0)
        await second.destroyCore()
    }

    @Test func recordFromAnotherEndpointIsAppliedButStale() async throws {
        let cached = #"{"version":"cached","rawErrors":true}"#
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        ObservePrefs().sdkConfigCache = CachedSdkConfig(
            endpoint: "https://other.invalid/v1/observe/config/pro-test?sdkName=observe-ios",
            freshness: ConfigFreshness(fetchedAt: now, expiresAt: now + 600_000), body: cached)
        let network = GatedConfigTransport()
        let configBox = Locked(SdkConfig.default)
        let core = makeConfigCore(network, configBox: configBox)
        await core.start()
        #expect(configBox.value.version == "cached")
        await eventually { await network.requests == 1 }
        let live = #"{"version":"live","rawErrors":false}"#
        await network.release(ConfigResponse(statusCode: 200, body: live))
        await eventually { configBox.value.version == "live" }
        #expect(!configBox.value.rawErrors)
        let record = try #require(ObservePrefs().sdkConfigCache)
        #expect(record.endpoint == "https://example.invalid/v1/observe/config/pro-test?sdkName=observe-ios")
        #expect(record.body == live)
        #expect(record.freshness.expiresAt - record.freshness.fetchedAt == ConfigManager.defaultTtlMs)
        await core.destroyCore()
    }
}
