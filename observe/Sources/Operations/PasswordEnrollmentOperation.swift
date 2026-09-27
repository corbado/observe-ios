/// Password-enrollment subflow operation: the user setting a new password, either during signup
/// (`SpecType.passwordSet`) or in a recovery/reset flow (`SpecType.passwordReset`).
public final class PasswordEnrollmentOperation: OperationFull, @unchecked Sendable {
    /// Which enrollment situation this is (wire values).
    public enum SpecType: String, Sendable {
        /// First-time password creation (signup).
        case passwordSet = "password-set"
        /// Password change through a recovery/reset flow.
        case passwordReset = "password-reset"
    }

    /// Typed error codes for `postResponse`.
    public enum KnownError: String, Sendable {
        case requirementsNotFulfilled = "requirements_not_fulfilled"
    }

    /// Observation handle for the new-password input field (repeat fields share it).
    public let newPasswordField: FieldObserver

    /// Client-side validation of the new password (strength/requirements checks).
    public let clientValidation: StepHandle

    /// The password submission to the host backend and its outcome.
    public let postResponse: StepHandle

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.passwordEnrollment
        newPasswordField = tracker.fieldObserver("password-enrollment")
        clientValidation = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "client-validation")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "post-response")
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started`.
    public func start(specType: SpecType? = nil, actor: String = "user", options: StepOptions? = nil) {
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        subflowStart(data: data, options: options)
    }
}
