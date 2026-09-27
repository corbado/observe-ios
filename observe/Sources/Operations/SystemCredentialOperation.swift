import AuthenticationServices
import Foundation

/// System-credential subflow operation: a system credential chooser, i.e.
/// `ASAuthorizationController` with several request types (passkey + password, Sign in with
/// Apple). The chooser is not an authentication method; its resolution hands over to (or
/// completes as) a method.
///
/// The requested set may contain only passkeys for an entry-screen sheet. Dedicated passkey
/// login buttons use the passkey-login subflow instead.
///
/// The SDK never runs the ceremony itself. The integration wraps its own
/// `ASAuthorizationController` and reports the settle:
///
/// ```swift
/// let attempt = tracker.systemCredentialOperation().begin(
///     requested: [.passkey, .password], preferImmediatelyAvailable: true)
/// // ... performRequests ...
/// // passkey picked:
/// attempt.resolved(.passkey, assertion: assertion)
/// attempt.passkeyPostResponse.start()
/// // ... verify with your backend ...
/// attempt.passkeyPostResponse.finished(options: StepOptions(userReference: user))
/// // failure: attempt.failed(error)
/// ```
///
/// Emission is eager: `begin` emits subflow and ceremony starts. Automatic or immediate
/// ceremony starts are not interaction evidence on their own. Every outcome is sent raw;
/// the backend uses the request preference, error code and duration to classify interaction.
/// Silent no-credential attempts remain raw events but produce no classified error or user path.

public final class SystemCredentialOperation: OperationFull, @unchecked Sendable {
    /// Credential types the authorization request asked for. Spec types deduplicate and sort
    /// their wire values lexicographically, so equivalent option sets produce the same spec.
    public enum RequestedOption: String, Sendable {
        case passkey
        case password
        case federated
    }

    /// What the ceremony narrowed to.
    public enum ResolvedCredentialType: String, Sendable {
        case passkey
        case password
        case federated
    }

    init(tracker: ObserveTracker) {
        super.init(tracker: tracker, subflowType: .systemCredential)
    }

    /// Starts an attempt around one authorization request and emits its start events.
    /// `autoTriggered` marks a sheet fired by the integration without a user gesture (screen
    /// entry). It adds the `-auto` suffix to the spec type and flags the start as
    /// `ignoreAsInteraction`; pass `false` for button-triggered calls. `assertionOptions` is the
    /// WebAuthn request JSON when a passkey option is included (it rides on the ceremony start).
    public func begin(
        requested: [RequestedOption],
        preferImmediatelyAvailable: Bool = false,
        autoTriggered: Bool = true,
        assertionOptions: String? = nil
    ) -> Attempt {
        Attempt(
            operation: self,
            requested: requested,
            preferImmediatelyAvailable: preferImmediatelyAvailable,
            autoTriggered: autoTriggered,
            assertionOptions: assertionOptions)
    }

    public final class Attempt: @unchecked Sendable {
        private let operation: SystemCredentialOperation
        private let ceremony: StepHandle

        /// Backend confirmation steps for the resolved credential (inside this subflow).
        public let passkeyPostResponse: StepHandle
        public let passwordPostResponse: StepHandle
        public let federatedPostResponse: StepHandle

        init(
            operation: SystemCredentialOperation,
            requested: [RequestedOption],
            preferImmediatelyAvailable: Bool,
            autoTriggered: Bool,
            assertionOptions: String?
        ) {
            self.operation = operation
            ceremony = StepHandle(
                tracker: operation.tracker, subflowType: operation.subflowType, stepName: stepCeremony,
                ignoreAsInteractionOnStart: autoTriggered || preferImmediatelyAvailable)
            passkeyPostResponse = operation.customStep("pk-post-response")
            passwordPostResponse = operation.customStep("pw-post-response")
            federatedPostResponse = operation.customStep("fed-post-response")

            let specType =
                Set(requested.map(\.rawValue)).sorted().joined(separator: "-")
                + (autoTriggered ? "-auto" : "")
            var startData: [String: JSONValue] = ["explicitSpecType": .string(specType)]
            if autoTriggered { startData["ignoreAsInteraction"] = .bool(true) }
            operation.subflowStart(data: startData)
            var ceremonyData: [String: JSONValue] = [
                "preferImmediatelyAvailableCredentials": .bool(preferImmediatelyAvailable)
            ]
            ceremonyData.putIfPresent("assertionOptions", assertionOptions)
            ceremony.start(data: ceremonyData)
            operation.tracker.autofillEngine.ceremonyArmed()
        }

        /// The ceremony settled with a credential of `type`. For a passkey pick, pass the WebAuthn
        /// `assertionResponse` JSON. The backend matches it to the stored passkey to resolve the
        /// authenticator model (AAGUID) shown in the funnel and user search; without it the pick
        /// still classifies, just without authenticator attribution.
        public func resolved(
            _ type: ResolvedCredentialType,
            assertionResponse: String? = nil,
            data: [String: JSONValue] = [:],
            options: StepOptions? = nil
        ) {
            var payload: [String: JSONValue] = ["narrowedSpecType": .string(type.rawValue)]
            payload.putIfPresent("assertionResponse", assertionResponse)
            payload.merge(data) { _, explicit in explicit }
            operation.tracker.autofillEngine.ceremonySettled()
            ceremony.finished(data: payload, options: options)
        }

        /// Typed convenience for a passkey pick: serializes the `AuthenticationServices` result.
        public func resolved(
            _ type: ResolvedCredentialType,
            assertion: any ASAuthorizationPublicKeyCredentialAssertion,
            data: [String: JSONValue] = [:],
            options: StepOptions? = nil
        ) {
            resolved(
                type,
                assertionResponse: WebAuthnSerialization.assertionResponseJSON(assertion),
                data: data,
                options: options)
        }

        /// The ceremony failed (dismissal, no credential, provider error). Ships the raw platform
        /// error; the backend owns the semantic mapping, including telling an instant
        /// no-credential answer from a dismissal.
        public func failed(_ error: any Error, options: StepOptions? = nil) {
            operation.tracker.autofillEngine.ceremonySettled()
            ceremony.errorTyped(rawPlatformErrorData(error), options: options)
        }
    }
}

private let stepCeremony = "ceremony"
