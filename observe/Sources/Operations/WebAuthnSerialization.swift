import AuthenticationServices
import Foundation

/// Serialization layer from the typed `AuthenticationServices` ceremony results the host app
/// holds to the WebAuthn JSON shape the wire (and the sanitizer) speak, i.e. the standard
/// `PublicKeyCredential` JSON encoding. Host apps with a custom WebAuthn stack can bypass this
/// and pass JSON strings directly.
enum WebAuthnSerialization {
    static func assertionResponseJSON(_ assertion: any ASAuthorizationPublicKeyCredentialAssertion) -> String {
        let credentialId = WebAuthnSanitizer.base64Url(assertion.credentialID)
        var response: [String: JSONValue] = [
            "clientDataJSON": .string(WebAuthnSanitizer.base64Url(assertion.rawClientDataJSON)),
            "authenticatorData": .string(WebAuthnSanitizer.base64Url(assertion.rawAuthenticatorData)),
            "signature": .string(WebAuthnSanitizer.base64Url(assertion.signature)),
        ]
        if let userID = assertion.userID, !userID.isEmpty {
            response["userHandle"] = .string(WebAuthnSanitizer.base64Url(userID))
        }
        return WireJson.encodeToString(
            JSONValue.object([
                "id": .string(credentialId),
                "rawId": .string(credentialId),
                "type": .string("public-key"),
                "response": .object(response),
            ]))
    }

    static func attestationResponseJSON(
        _ registration: any ASAuthorizationPublicKeyCredentialRegistration
    ) -> String {
        let credentialId = WebAuthnSanitizer.base64Url(registration.credentialID)
        var response: [String: JSONValue] = [
            "clientDataJSON": .string(WebAuthnSanitizer.base64Url(registration.rawClientDataJSON))
        ]
        if let attestationObject = registration.rawAttestationObject {
            response["attestationObject"] = .string(WebAuthnSanitizer.base64Url(attestationObject))
        }
        return WireJson.encodeToString(
            JSONValue.object([
                "id": .string(credentialId),
                "rawId": .string(credentialId),
                "type": .string("public-key"),
                "response": .object(response),
            ]))
    }

}
