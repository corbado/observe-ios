import Foundation

/// Wire data model of the Observe ingest API (`POST <apiBaseUrl>/v1/observe/events/<projectId>`).
///
/// The contract is owned by the backend (`corbado` repo, `backend/openapi/api_public_v1.yml`).
/// Field names and event vocabulary must match exactly because the backend classifier keys off
/// them. Never invent fields here; contract
/// changes start in the backend OpenAPI spec.
enum WireJson {
    static let encoder: JSONEncoder = JSONEncoder()
    static let decoder: JSONDecoder = JSONDecoder()

    static func encodeToString(_ value: some Encodable) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct WireEventBatch: Codable {
    // Spec casing is `sessionID`. Go's JSON decoder would also accept `sessionId`
    // (case-insensitive match), but the SDK follows the spec.
    var sessionID: String
    var events: [WireEvent]
    var sdk: WireSdkInfo
    var lows: [WireLowEvent]?
    var telemetry: [WireTelemetryEntry]?
    var meta: WireBatchMeta?
}

struct WireSdkInfo: Codable {
    var name: String
    var version: String
}

struct WireBatchMeta: Codable {
    var sent: Int64
    /// Always `"native"` for this SDK. Free-form string on the wire (deliberately not an enum).
    var transport: String
    /// Native flush-trigger vocabulary; see `FlushReason`.
    var flushReason: String?
    /// Number of prior failed delivery attempts for this batch; omitted on the first attempt.
    var retryCount: Int?
    /// Version of the SDK reliability config this batch was captured under.
    var configVersion: String?
}

struct WireEvent: Codable {
    /// Client-generated idempotency id (uuidv7) so safe resends (retry/outbox) dedupe server-side.
    var id: String
    var timestamp: Int64
    var seq: Int64
    var type: String = "predefined"
    var name: String
    var data: JSONValue
    var user: WireUserReference?
    var contexts: JSONValue?
    var tags: [String: String]?
    var experiments: [String: String]?
    var deviceInfo: WireDeviceInfo?
    var meta: WireEventMeta?
}

struct WireUserReference: Codable {
    var userId: String?
    var identifier: String?
    var crossEnvironmentTransactionID: String?
}

struct WireEventMeta: Codable {
    /// Where the event originated. Native: the host-app-provided screen name (see `setScreen`);
    /// omitted while no screen is set.
    var trackingSourcePath: String?
    /// Short-lived stream id, attached to EVERY event: a per-process id minted at process start.
    /// The backend splits interleaved streams of one long-horizon session by it, and it
    /// disambiguates the per-process seq counter across incarnations.
    var tabId: String?
}

struct WireLowEvent: Codable, Equatable {
    var lowType: String
    var ts: Int64
    var durationMs: Int64?
    /// Which semantic field the low relates to, named by subflow-type vocabulary
    /// (`provide-identifier`, `password-login`, ...).
    var fieldType: String?
    /// Who caused the observed effect, when known (`password-manager`, `app`).
    var actor: String?
}

struct WireTelemetryEntry: Codable {
    /// Client-generated idempotency id (uuidv7).
    var id: String
    /// `"info"` or `"error"`.
    var level: String
    /// Free-form diagnostic message. Truncated client-side. Must not contain credentials or PII.
    var message: String
    /// Capture time, unix ms.
    var ts: Int64
}

// MARK: - Device info (`deviceInfo.type == "app"`, schema `observeDeviceInfoApp`)

struct WireDeviceInfo: Codable {
    var type: String = "app"
    var clientEnvHandle: String
    var clientEnvHandleMeta: WireClientEnvHandleMeta
    /// Per-process id (same value as `WireEventMeta.tabId`).
    var tabId: String?
    var data: WireDeviceInfoDataApp?
}

struct WireClientEnvHandleMeta: Codable {
    var timestamp: Int64
    var source: String = "native"
}

struct WireDeviceInfoDataApp: Codable {
    var osName: String
    var osVersion: String
    /// Device model: the machine identifier, e.g. "iPhone15,3".
    var model: String?
    /// Device manufacturer/brand, always "Apple".
    var brand: String?
    /// Host application name.
    var appName: String?
    /// Host application version.
    var appVersion: String?
    /// One of: none, code, bio-face, bio-touch, bio-strong, bio-weak, bio.
    var deviceOwnerAuth: String?
    /// Never probed on iOS (a `CBCentralManager` probe would trigger the Bluetooth permission
    /// dialog); stays absent.
    var isBluetoothAvailable: Bool?
    /// Not applicable on iOS; always absent.
    var androidGooglePlayServicesVersion: String?
    /// BCP-47 locale tag, e.g. "de-DE".
    var locale: String?
    var screen: WireAppScreen?
}

struct WireAppScreen: Codable {
    var widthPoints: Float
    var heightPoints: Float
    var scale: Float
}
