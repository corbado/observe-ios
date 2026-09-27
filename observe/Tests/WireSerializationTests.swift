import Foundation
import Testing

@testable import CorbadoObserve

/// Wire-contract tests: the JSON leaving this SDK must match the backend OpenAPI spec
/// (api_public_v1.yml): spec casing (`sessionID`), no null noise, `deviceInfo.type == "app"`.
@Suite struct WireSerializationTests {
    @Test func batchUsesSpecCasingAndOmitsAbsentFields() throws {
        let batch = WireEventBatch(
            sessionID: "0198b842-0000-7000-8000-000000000000",
            events: [
                WireEvent(
                    id: "0198b842-0000-7000-8000-000000000001",
                    timestamp: 1_755_000_000_000,
                    seq: 0,
                    name: "flow_started",
                    data: .object(["flowName": .string("login")]))
            ],
            sdk: WireSdkInfo(name: "observe-ios", version: "0.1.0"),
            meta: WireBatchMeta(sent: 1_755_000_000_100, transport: "native", flushReason: "timer"))

        let json = WireJson.encodeToString(batch)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(root["sessionID"] as? String == "0198b842-0000-7000-8000-000000000000")
        #expect(!json.contains("\"sessionId\""))
        #expect(!json.contains("null"))
        #expect(root["lows"] == nil)
        #expect(root["telemetry"] == nil)

        let event = try #require((root["events"] as? [[String: Any]])?.first)
        #expect(event["type"] as? String == "predefined")
        #expect(event["name"] as? String == "flow_started")
        #expect((event["data"] as? [String: Any])?["flowName"] as? String == "login")
        #expect(event["user"] == nil)
        #expect(event["tags"] == nil)
    }

    @Test func deviceInfoCarriesAppTypeAndNativeSource() throws {
        let info = WireDeviceInfo(
            clientEnvHandle: "handle",
            clientEnvHandleMeta: WireClientEnvHandleMeta(timestamp: 1),
            tabId: "tab",
            data: WireDeviceInfoDataApp(osName: "iOS", osVersion: "18.5"))
        let json = WireJson.encodeToString(info)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(root["type"] as? String == "app")
        #expect((root["clientEnvHandleMeta"] as? [String: Any])?["source"] as? String == "native")
        let data = try #require(root["data"] as? [String: Any])
        #expect(data["osName"] as? String == "iOS")
        #expect(data["isBluetoothAvailable"] == nil)
        #expect(data["androidGooglePlayServicesVersion"] == nil)
    }

    @Test func outboxEntryRoundTrips() throws {
        let entry = Outbox.Entry(
            sessionId: "session",
            event: WireEvent(
                id: "id", timestamp: 5, seq: 2, name: "subflow_started",
                data: .object(["subflowType": .string("password-login")]),
                tags: ["applicationId": "app"],
                meta: WireEventMeta(trackingSourcePath: "LoginScreen", tabId: "tab")))
        let encoded = try WireJson.encoder.encode(entry)
        let decoded = try WireJson.decoder.decode(Outbox.Entry.self, from: encoded)
        #expect(decoded.sessionId == "session")
        #expect(decoded.event.id == "id")
        #expect(decoded.event.seq == 2)
        #expect(decoded.event.data == .object(["subflowType": .string("password-login")]))
        #expect(decoded.event.meta?.trackingSourcePath == "LoginScreen")
    }
}
