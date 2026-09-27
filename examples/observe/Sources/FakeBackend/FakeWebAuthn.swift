import AuthenticationServices
import Foundation

/// WebAuthn side of the fake backend: mints registration/assertion requests for
/// `AuthenticationServices` and keeps a local passkey registry (identifier → credential ids). No
/// verification; we only need the ceremonies and their telemetry. The rpId comes from the devbar;
/// its `apple-app-site-association` must list this app.
@MainActor
final class FakeWebAuthn {
    private let key = "fake_webauthn"
    private var store: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func passkeyIds(_ identifier: String) -> [String] { store[identifier] ?? [] }

    func hasPasskey(_ identifier: String) -> Bool { !passkeyIds(identifier).isEmpty }

    func deleteAllPasskeys() { store = [:] }

    /// Registration request for `identifier`. Existing ids ride as `excludedCredentials` (iOS
    /// 17.4+) so a second enrollment reproduces the exclude-match error path.
    func registrationRequest(
        identifier: String, rpId: String
    ) -> (request: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest, optionsJson: String) {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let challenge = randomChallenge()
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: identifier, userID: Data(identifier.utf8))
        request.userVerificationPreference = .required
        let excluded = passkeyIds(identifier)
        if #available(iOS 17.4, *), !excluded.isEmpty {
            request.excludedCredentials = excluded.compactMap { id in
                Data(base64URL: id).map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            }
        }
        let options: [String: Any] = [
            "challenge": challenge.base64URL,
            "rp": ["id": rpId, "name": "Observe Example"],
            "user": ["id": Data(identifier.utf8).base64URL, "name": identifier, "displayName": identifier],
            "pubKeyCredParams": [["type": "public-key", "alg": -7], ["type": "public-key", "alg": -257]],
            "timeout": 60_000,
            "authenticatorSelection": [
                "authenticatorAttachment": "platform", "residentKey": "required", "userVerification": "required",
            ],
            "excludeCredentials": excluded.map { ["type": "public-key", "id": $0] },
            "attestation": "none",
        ]
        return (request, json(options))
    }

    /// Records a finished registration ceremony.
    func registerPasskey(identifier: String, registration: ASAuthorizationPlatformPublicKeyCredentialRegistration) {
        var ids = passkeyIds(identifier)
        ids.append(registration.credentialID.base64URL)
        store[identifier] = ids
    }

    /// Assertion request. With `identifier` the request carries `allowedCredentials` for that
    /// account (identifier-known variant), and, like a real backend, only when passkey ids are on
    /// record for it (nil otherwise). Without an identifier it is usernameless (discoverable).
    func assertionRequest(
        rpId: String, identifier: String? = nil
    ) -> (request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest, optionsJson: String)? {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let challenge = randomChallenge()
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        var options: [String: Any] = [
            "challenge": challenge.base64URL, "rpId": rpId, "timeout": 60_000, "userVerification": "required",
        ]
        if let identifier {
            let ids = passkeyIds(identifier)
            if ids.isEmpty { return nil }
            request.allowedCredentials = ids.compactMap { id in
                Data(base64URL: id).map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            }
            options["allowCredentials"] = ids.map { ["type": "public-key", "id": $0] }
        }
        return (request, json(options))
    }

    /// Resolves an assertion to the identifier its credential is registered for (nil = unknown
    /// credential, i.e. a passkey the backend never saw: the "assertion rejected" case).
    func passkeyLogin(_ assertion: ASAuthorizationPlatformPublicKeyCredentialAssertion) -> String? {
        let id = assertion.credentialID.base64URL
        return store.first { $0.value.contains(id) }?.key
    }

    private func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
