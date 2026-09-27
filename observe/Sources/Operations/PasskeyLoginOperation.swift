import AuthenticationServices
import Foundation

/// Passkey-login subflow operation for passkey-ONLY assertion requests. Emits the spec types and
/// the `ceremony`/`post-response` steps the backend classifier keys off. Entry-screen credential
/// sheets belong to `SystemCredentialOperation`, including sheets requesting only passkeys.
///
/// Emission is eager: `begin` immediately emits `subflow_started` + the ceremony start.
///
/// ```swift
/// let attempt = tracker.passkeyLoginOperation().begin(
///     specType: .knownIdentifier, assertionOptions: assertionOptionsJson)
/// // ... run the ASAuthorizationController request ...
/// attempt.ceremonyFinished(assertion: assertion)  // or the JSON-string overload
/// attempt.postResponse.start()
/// // ... verify with your backend ...
/// attempt.postResponse.finished(options: StepOptions(userReference: user))
/// // on failure: attempt.ceremonyFailed(error)
/// ```
public final class PasskeyLoginOperation: OperationFull, @unchecked Sendable {
    /// Passkey-login spec types (wire values).
    public enum SpecType: String, Sendable {
        /// Identifier already known; assertion options carry an allowCredentials list.
        case knownIdentifier = "passkey-known-identifier"
        /// Usernameless login over discoverable credentials.
        case noIdentifier = "passkey-no-identifier"
    }

    init(tracker: ObserveTracker) {
        super.init(tracker: tracker, subflowType: .passkeyLogin)
    }

    /// Emits `subflow_started` + the ceremony start and returns the attempt handle.
    /// `autoTriggered` appends the `-auto` spec suffix for ceremonies the integration fires
    /// without a user gesture.
    public func begin(
        specType: SpecType,
        assertionOptions: String? = nil,
        autoTriggered: Bool = false,
        options: StepOptions? = nil
    ) -> Attempt {
        let wireSpecType = specType.rawValue + (autoTriggered ? "-auto" : "")

        let startData: [String: JSONValue] = ["explicitSpecType": .string(wireSpecType)]
        tracker.trackSubflowStarted(subflowType, data: startData, options: options)

        var ceremonyData: [String: JSONValue] = ["explicitSpecType": .string(wireSpecType)]
        ceremonyData.putIfPresent("assertionOptions", assertionOptions)
        tracker.trackSubflowStepStarted(
            subflowType,
            stepName: stepCeremony,
            data: ceremonyData,
            options: options,
            ignoreAsInteraction: nil)

        tracker.autofillEngine.ceremonyArmed()

        return Attempt(operation: self)
    }

    public final class Attempt: Sendable {
        private let operation: PasskeyLoginOperation

        /// Backend confirmation of the assertion.
        public let postResponse: StepHandle

        init(operation: PasskeyLoginOperation) {
            self.operation = operation
            postResponse = operation.customStep("post-response")
        }

        public func ceremonyFinished(assertionResponse: String? = nil, options: StepOptions? = nil) {
            operation.tracker.autofillEngine.ceremonySettled()
            var data: [String: JSONValue] = [:]
            data.putIfPresent("assertionResponse", assertionResponse)
            operation.tracker.trackSubflowStepFinished(
                operation.subflowType, stepName: stepCeremony, data: data, options: options)
        }

        /// Typed convenience: serializes the `AuthenticationServices` result to WebAuthn JSON.
        public func ceremonyFinished(
            assertion: any ASAuthorizationPublicKeyCredentialAssertion, options: StepOptions? = nil
        ) {
            ceremonyFinished(
                assertionResponse: WebAuthnSerialization.assertionResponseJSON(assertion), options: options)
        }

        /// The ceremony failed (dismissal, no credential, provider error). Ships the raw platform
        /// error; the backend owns the semantic mapping.
        public func ceremonyFailed(_ error: any Error, options: StepOptions? = nil) {
            operation.tracker.autofillEngine.ceremonySettled()
            operation.tracker.trackSubflowStepError(
                operation.subflowType, stepName: stepCeremony, data: rawPlatformErrorData(error),
                options: options)
        }
    }
}

private let stepCeremony = "ceremony"
