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
/// User identifiers are omitted unless the integration projects them: relying parties often put
/// an email there. Covers creation-options `user.id` (plus `user.name`/`user.displayName`) and
/// response `userHandle`.
///
/// Keyed by the wire field names the backend classifier uses; recurses so nested `stepData` (and
/// any future nesting) is covered. Anything that fails to parse is redacted wholesale rather than
/// passed through: a sanitizer must never leak on its error path.
struct WebAuthnSanitizer: Sendable {
    var userIdProjector: WebAuthnIdentifierProjector?

    private static let redacted = "[redacted]"

    /// Valid base64url, non-empty. Passes the backend's `len(challenge) > 0` presence gate.
    private static let redactedChallenge = "redacted"

    /// Neutral clientDataJSON (no challenge, no origin) that still parses as WebAuthn client data.
    private static let neutralClientDataJSON: String = {
        let json = #"{"type":"webauthn.create","challenge":"","origin":""}"#
        return base64Url(Data(json.utf8))
    }()

    func sanitize(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.reduce(into: [:]) { result, pair in result[pair.key] = entry(pair.key, pair.value) }
    }

    private func entry(_ key: String, _ value: JSONValue) -> JSONValue {
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

    private func string(_ key: String, _ raw: String) -> JSONValue {
        switch key {
        case "assertionResponse": .string(sanitizeAssertion(raw))
        case "attestationResponse": .string(sanitizeAttestation(raw))
        case "attestationOptions": .string(sanitizeCreationOptions(raw))
        default: .string(raw)
        }
    }

    /// Remove `response.signature` from a login assertion; project `response.userHandle`.
    private func sanitizeAssertion(_ raw: String) -> String {
        Self.transform(raw) { root in
            guard case .object(var response)? = root["response"] else { return root }
            response["signature"] = nil
            var result = root
            result["response"] = .object(projectUserId(response, key: "userHandle"))
            return result
        }
    }

    /// Replace the clientDataJSON (which carries the challenge) with a stub; project `response.userHandle`.
    private func sanitizeAttestation(_ raw: String) -> String {
        Self.transform(raw) { root in
            guard case .object(var response)? = root["response"] else { return root }
            response["clientDataJSON"] = .string(Self.neutralClientDataJSON)
            var result = root
            result["response"] = .object(projectUserId(response, key: "userHandle"))
            return result
        }
    }

    /// Replace the top-level `challenge` with a non-empty placeholder; drop user name fields, project `user.id`.
    private func sanitizeCreationOptions(_ raw: String) -> String {
        Self.transform(raw) { root in
            var result = root
            if root["challenge"] != nil { result["challenge"] = .string(Self.redactedChallenge) }
            if case .object(var user)? = root["user"] {
                user["name"] = nil
                user["displayName"] = nil
                result["user"] = .object(projectUserId(user, key: "id"))
            }
            return result
        }
    }

    /// JSON null stays null; strings go through the projector; everything else is omitted.
    private func projectUserId(_ object: [String: JSONValue], key: String) -> [String: JSONValue] {
        guard let value = object[key] else { return object }
        var result = object
        switch value {
        case .null:
            break
        case .string(let identifier):
            switch (try? userIdProjector?(identifier)) ?? .omit {
            case .value(let projected): result[key] = .string(projected)
            case .null: result[key] = .null
            case .omit: result[key] = nil
            }
        default:
            result[key] = nil
        }
        return result
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
