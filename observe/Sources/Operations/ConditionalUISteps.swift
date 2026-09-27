import AuthenticationServices
import Foundation

/// Conditional-UI passkey steps hosted on a form subflow (`password-login`, `provide-identifier`):
/// a passkey picked from the QuickType chip while the form is visible is attributed to that
/// form's subflow. The `passkey-cui` spec type and the WebAuthn payload shapes are fixed here so
/// the wire vocabulary cannot drift. An armed request is idle; the focused field it serves arms
/// the window lows.
///
/// ```swift
/// op.cui.getOptionsStarted()
/// let options = try await backend.assertionOptions()
/// op.cui.getOptionsFinished(assertionOptions: options.json)
/// op.cui.ceremonyStarted()
/// controller.performAutoFillAssistedRequests()          // armed until picked or cancelled
/// // delegate success:
/// op.cui.ceremonyFinished(assertion: assertion)
/// op.cui.postResponse.start()
/// ```
///
/// Abort contract: an armed request is process-scoped and settles as
/// `ASAuthorizationError.canceled` (1001) after the app's own `cancel()` (on navigation or before
/// a modal handover), exactly like a dismissal would. Leave the ceremony step open in that case
/// (neutral for classification). `ceremonyFailed` is for failures outside the app's control,
/// e.g. 1004 "already in progress" from arming while a request is still alive.
public final class ConditionalUISteps: Sendable {
    private let getOptions: StepHandle
    private let ceremony: StepHandle

    /// Backend verification of the picked assertion.
    public let postResponse: StepHandle

    init(tracker: ObserveTracker, subflowType: SubflowType) {
        getOptions = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "cui-get-options", ignoreAsInteractionOnStart: true)
        ceremony = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "cui-ceremony")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "cui-post-response")
    }

    /// Fetching assertion options for the conditional request (not a user interaction).
    public func getOptionsStarted(options: StepOptions? = nil) {
        getOptions.start(data: Self.specTypeData, options: options)
    }

    /// - Parameter assertionOptions: WebAuthn `PublicKeyCredentialRequestOptions` as JSON.
    public func getOptionsFinished(assertionOptions: String, options: StepOptions? = nil) {
        getOptions.finished(data: ["assertionOptions": .string(assertionOptions)], options: options)
    }

    /// The options fetch failed (backend or network error).
    public func getOptionsFailed(_ error: any Error, options: StepOptions? = nil) {
        getOptions.error(error, options: options)
    }

    /// The request is armed (`performAutoFillAssistedRequests`).
    public func ceremonyStarted(options: StepOptions? = nil) {
        ceremony.start(data: Self.specTypeData, options: options)
    }

    /// - Parameter assertionResponse: WebAuthn `PublicKeyCredential` (assertion) as JSON.
    public func ceremonyFinished(assertionResponse: String, options: StepOptions? = nil) {
        ceremony.finished(data: ["assertionResponse": .string(assertionResponse)], options: options)
    }

    /// Typed convenience: serializes the `AuthenticationServices` result to WebAuthn JSON.
    public func ceremonyFinished(
        assertion: any ASAuthorizationPublicKeyCredentialAssertion, options: StepOptions? = nil
    ) {
        ceremonyFinished(assertionResponse: WebAuthnSerialization.assertionResponseJSON(assertion), options: options)
    }

    /// A failure outside the app's control. Ships the raw platform error (`domain:code`); the
    /// backend owns the semantic mapping. The 1001 after your own `cancel()` stays unreported.
    public func ceremonyFailed(_ error: any Error, options: StepOptions? = nil) {
        ceremony.errorTyped(rawPlatformErrorData(error), options: options)
    }

    private static let specTypeData: [String: JSONValue] = ["explicitSpecType": .string("passkey-cui")]
}
