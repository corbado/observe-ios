import Foundation

/// Redacts WebAuthn completion material from event payloads before they leave the SDK.
///
/// The SDK must NEVER transmit data that would let Corbado complete a login or a passkey creation
/// on the user's behalf (which could mint a session). The integrating app legitimately holds the
/// full credential response (it performs the real ceremony with the relying party), but the SDK
/// sanitizes its OWN copy here, at the `ObserveTracker` track() serialization choke point, so the
/// raw material never enters an event, the durable outbox, or the transport.
///
/// Per ceremony, exactly one element is completion-critical, and it differs by what the holder
/// could otherwise reconstruct:
/// - **Login assertion** (`assertionResponse`): the `signature`, the sole proof, unforgeable
///   without the hardware-held private key. Removed. Everything analytically useful stays
///   (credential id, authenticator-data flags, clientDataJSON).
/// - **Passkey enrollment** (`attestationResponse` + `attestationOptions`): the single-use
///   `challenge`. There is no per-user secret to strip, so denying the challenge is what blocks
///   completion. It must be denied everywhere it appears (the response's clientDataJSON AND
///   the options), or the two copies reconstruct each other.
///
/// Keyed by the wire field names the backend classifier uses; recurses so nested `stepData` (and
/// any future nesting) is covered. Anything that fails to parse is redacted wholesale rather than
/// passed through: a sanitizer must never leak on its error path.
enum WebAuthnSanitizer {
    private static let redacted = "[redacted]"

    /// Valid base64url, non-empty. Passes the backend's `len(challenge) > 0` presence gate.
    private static let redactedChallenge = "redacted"

    /// Neutral clientDataJSON (no challenge, no origin) that still parses as WebAuthn client data.
    private static let neutralClientDataJSON: String = {
        let json = #"{"type":"webauthn.create","challenge":"","origin":""}"#
        return base64Url(Data(json.utf8))
    }()

    static func sanitize(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.reduce(into: [:]) { result, pair in result[pair.key] = entry(pair.key, pair.value) }
    }

    private static func entry(_ key: String, _ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let nested):
            return .object(sanitize(nested))
        case .array(let items):
            return .array(items.map { if case .object(let nested) = $0 { .object(sanitize(nested)) } else { $0 } })
        case .string(let raw):
            return string(key, raw)
        default:
            return value
        }
    }

    private static func string(_ key: String, _ raw: String) -> JSONValue {
        switch key {
        case "assertionResponse": .string(stripSignature(raw))
        case "attestationResponse": .string(neutralizeEnrollmentChallenge(raw))
        case "attestationOptions": .string(redactOptionsChallenge(raw))
        default: .string(raw)
        }
    }

    /// Remove `response.signature` from a login assertion.
    private static func stripSignature(_ raw: String) -> String {
        transform(raw) { root in
            guard case .object(var response)? = root["response"] else { return root }
            response["signature"] = nil
            var result = root
            result["response"] = .object(response)
            return result
        }
    }

    /// Replace the enrollment response's clientDataJSON (which carries the challenge) with a stub.
    private static func neutralizeEnrollmentChallenge(_ raw: String) -> String {
        transform(raw) { root in
            guard case .object(var response)? = root["response"] else { return root }
            response["clientDataJSON"] = .string(neutralClientDataJSON)
            var result = root
            result["response"] = .object(response)
            return result
        }
    }

    /// Replace the top-level `challenge` in attestation options with a non-empty placeholder.
    private static func redactOptionsChallenge(_ raw: String) -> String {
        transform(raw) { root in
            guard root["challenge"] != nil else { return root }
            var result = root
            result["challenge"] = .string(redactedChallenge)
            return result
        }
    }

    private static func transform(
        _ raw: String, _ block: ([String: JSONValue]) -> [String: JSONValue]
    ) -> String {
        guard let data = raw.data(using: .utf8),
            let parsed = try? WireJson.decoder.decode(JSONValue.self, from: data),
            case .object(let root) = parsed,
            let encoded = try? WireJson.encoder.encode(JSONValue.object(block(root))),
            let result = String(data: encoded, encoding: .utf8)
        else { return redacted }
        return result
    }

    static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
