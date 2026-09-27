import AuthenticationServices
import Foundation

/// Passkey-enrollment subflow operation (registration ceremonies). Emits the `ceremony` step
/// (with `attestationOptions`/`attestationResponse`) and the `post-response` step.
///
/// ```swift
/// let attempt = tracker.passkeyEnrollmentOperation().begin(attestationOptions: optionsJson)
/// // ... run the ASAuthorizationController registration ...
/// attempt.ceremonyFinished(registration: registration)  // or the JSON-string overload
/// attempt.postResponse.start()
/// // ... register with your backend ...
/// attempt.postResponse.finished()
/// // on failure: attempt.ceremonyFailed(error)
/// ```
public final class PasskeyEnrollmentOperation: OperationFull, @unchecked Sendable {
    init(tracker: ObserveTracker) {
        super.init(tracker: tracker, subflowType: .passkeyEnrollment)
    }

    /// Emits `subflow_started` + the ceremony start. `specType` describes how the enrollment was
    /// offered (default `"auto-manual"`: automatically prompted, manually confirmed).
    public func begin(
        attestationOptions: String? = nil,
        specType: String = "auto-manual",
        options: StepOptions? = nil
    ) -> Attempt {
        tracker.trackSubflowStarted(
            subflowType, data: ["explicitSpecType": .string(specType)], options: options)
        var ceremonyData: [String: JSONValue] = [:]
        ceremonyData.putIfPresent("attestationOptions", attestationOptions)
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
        private let operation: PasskeyEnrollmentOperation

        /// Backend confirmation of the attestation.
        public let postResponse: StepHandle

        init(operation: PasskeyEnrollmentOperation) {
            self.operation = operation
            postResponse = operation.customStep("post-response")
        }

        public func ceremonyFinished(attestationResponse: String? = nil, options: StepOptions? = nil) {
            operation.tracker.autofillEngine.ceremonySettled()
            var data: [String: JSONValue] = [:]
            data.putIfPresent("attestationResponse", attestationResponse)
            operation.tracker.trackSubflowStepFinished(
                operation.subflowType, stepName: stepCeremony, data: data, options: options)
        }

        /// Typed convenience: serializes the `AuthenticationServices` result to WebAuthn JSON.
        public func ceremonyFinished(
            registration: any ASAuthorizationPublicKeyCredentialRegistration, options: StepOptions? = nil
        ) {
            ceremonyFinished(
                attestationResponse: WebAuthnSerialization.attestationResponseJSON(registration),
                options: options)
        }

        /// The ceremony failed (cancel, provider error). Ships the raw platform error.
        public func ceremonyFailed(_ error: any Error, options: StepOptions? = nil) {
            operation.tracker.autofillEngine.ceremonySettled()
            operation.tracker.trackSubflowStepError(
                operation.subflowType, stepName: stepCeremony, data: rawPlatformErrorData(error),
                options: options)
        }
    }
}

private let stepCeremony = "ceremony"
