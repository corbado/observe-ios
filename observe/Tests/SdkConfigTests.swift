import Testing

@testable import CorbadoObserve

@Suite struct SdkConfigTests {
    @Test func defaultsAreConservative() {
        let config = SdkConfig.default
        #expect(config.flushIntervalMs == 2_000)
        #expect(config.sessionInactivityMs == 30 * 60 * 1_000)
        #expect(config.telemetry)
        #expect(!config.flushOnTelemetry)
        #expect(config.flushOnBackground)
        #expect(config.lows)
        #expect(config.retryMaxAttempts == 1)
    }

    @Test func parsesFullConfig() throws {
        let config = try #require(
            SdkConfig.parse(
                """
                {"version":"v3","flushIntervalMs":5000,"sessionInactivityMs":600000,
                 "telemetry":false,"flushOnTelemetry":true,"flushOnFlowTypeFinished":["login"],
                 "flushOnBackground":false,"lows":false,
                 "retry":{"maxAttempts":3,"baseDelayMs":500,"maxDelayMs":10000}}
                """))
        #expect(config.version == "v3")
        #expect(config.flushIntervalMs == 5_000)
        #expect(config.sessionInactivityMs == 600_000)
        #expect(!config.telemetry)
        #expect(config.flushOnTelemetry)
        #expect(config.flushOnFlowTypeFinished == ["login"])
        #expect(!config.flushOnBackground)
        #expect(!config.lows)
        #expect(config.retryMaxAttempts == 3)
        #expect(config.retryBaseDelayMs == 500)
        #expect(config.retryMaxDelayMs == 10_000)
    }

    @Test func clampsHostileValues() throws {
        let config = try #require(
            SdkConfig.parse(
                """
                {"version":"v1","flushIntervalMs":1,"sessionInactivityMs":1,
                 "retry":{"maxAttempts":99,"baseDelayMs":-5}}
                """
            ))
        #expect(config.flushIntervalMs == 200)
        #expect(config.sessionInactivityMs == 60_000)
        #expect(config.retryMaxAttempts == 10)
        #expect(config.retryBaseDelayMs == 0)
    }

    @Test func unknownFieldsAndMissingFieldsKeepDefaults() throws {
        let config = try #require(SdkConfig.parse(#"{"version":"v1","someFutureField":{"a":1}}"#))
        #expect(config.flushIntervalMs == SdkConfig.default.flushIntervalMs)
        #expect(config.telemetry == SdkConfig.default.telemetry)
    }

    @Test func malformedBodyReturnsNil() {
        #expect(SdkConfig.parse("not json") == nil)
        #expect(SdkConfig.parse("[1,2,3]") == nil)
        #expect(SdkConfig.parse("") == nil)
    }
    @Test(arguments: ["1e100", "9223372036854775808", "1.7976931348623157e308", "-1e100"])
    func outOfRangeJsonNumbersClampWithoutTrapping(value: String) throws {
        let config = try #require(
            SdkConfig.parse(
                "{\"version\":\"v1\",\"sessionInactivityMs\":\(value),\"retry\":{\"maxAttempts\":\(value)}}"))
        #expect(config.sessionInactivityMs == (value.hasPrefix("-") ? 60_000 : 86_400_000))
        #expect(config.retryMaxAttempts == (value.hasPrefix("-") ? 1 : 10))
    }

    @Test func partialOverridesWinPerRetryFieldAndKeepNativeDefaults() throws {
        let remote = try #require(
            SdkConfig.parse(
                """
                {"version":"server","flushIntervalMs":6000,"telemetry":false,
                 "retry":{"maxAttempts":5,"baseDelayMs":200,"maxDelayMs":5000}}
                """))
        let overrides = SdkConfigOverrides(
            telemetry: true, retry: RetryConfigOverrides(maxAttempts: 2))
        let resolved = overrides.resolve(over: remote)
        #expect(!overrides.isComplete)
        #expect(resolved.version == "server")
        #expect(resolved.flushIntervalMs == 6000)
        #expect(resolved.telemetry)
        #expect(resolved.retryMaxAttempts == 2)
        #expect(resolved.retryBaseDelayMs == 200)
        #expect(resolved.retryMaxDelayMs == 5000)
        #expect(SdkConfigOverrides().resolve(over: nil).retryBaseDelayMs == 0)
    }

    @Test func configEndpointUsesProxyPathAndNativePolicySelector() {
        let options = ObserveOptions(
            projectId: "pro-test", apiBaseUrl: "https://proxy.example", apiConfigPath: "/auth/config")
        #expect(options.configURL?.absoluteString == "https://proxy.example/auth/config/pro-test?sdkName=observe-ios")
        #expect(options.eventsURL?.absoluteString == "https://proxy.example/v1/observe/events/pro-test")
    }

}
