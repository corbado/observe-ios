/// Password-login subflow operation. Its step names, spec types and typed error codes are the
/// wire vocabulary the backend classifier keys off.
///
/// Typical shape:
/// ```swift
/// let op = tracker.passwordLoginOperation()
/// op.start(specType: .knownIdentifier)
/// op.postResponse.start()
/// // ... call your backend ...
/// op.postResponse.finished()                        // success
/// op.postResponse.errorTyped(.invalidPassword)      // known failure
/// ```
public final class PasswordLoginOperation: OperationFull, @unchecked Sendable {
    /// Spec types distinguishing the password-form variants (wire values).
    public enum SpecType: String, Sendable {
        /// Identifier already known; the screen only asks for the password.
        case knownIdentifier = "password-known-identifier"
        /// Combined identifier + password form.
        case withIdentifier = "password-with-identifier"
    }

    /// Typed error codes for `postResponse`.
    public enum KnownError: String, Sendable {
        case invalidPassword = "invalid_password"
        case userNotFound = "user_not_found"
        case accountLocked = "account_locked"
    }

    /// Observation handle for the password input field.
    public let passwordField: FieldObserver

    /// Observation handle for the identifier field of combined forms (`SpecType.withIdentifier`).
    /// Field type is field SEMANTICS: the identifier box is a provide-identifier-kind field even
    /// when no provide-identifier subflow runs.
    public let identifierField: FieldObserver

    /// Client-side validation of the form (before any request leaves the device).
    public let clientValidation: StepHandle

    /// The credential submission to the host backend and its outcome.
    public let postResponse: StepHandle

    /// Conditional-UI passkey steps hosted on the password-login subflow (a passkey login offered
    /// while the password form is visible is attributed to password-login).
    public let cui: ConditionalUISteps

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.passwordLogin
        passwordField = tracker.fieldObserver("password-login")
        identifierField = tracker.fieldObserver("provide-identifier")
        clientValidation = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "client-validation")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "post-response")
        cui = ConditionalUISteps(tracker: tracker, subflowType: subflowType)
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started` for this password-login attempt.
    ///
    /// - Parameter specType: Which form variant the user is on.
    /// - Parameter actor: Who initiated the subflow (`"user"` or `"system"`).
    /// - Parameter ignoreAsInteraction: the form rendered with the screen (actor `"system"`), no
    ///   user gesture behind it.
    public func start(
        specType: SpecType? = nil, actor: String = "user", ignoreAsInteraction: Bool = false,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        if ignoreAsInteraction { data["ignoreAsInteraction"] = .bool(true) }
        subflowStart(data: data, options: options)
    }
}

extension StepHandle {
    /// Convenience for `errorTyped` with a known password-login error code.
    public func errorTyped(_ error: PasswordLoginOperation.KnownError, options: StepOptions? = nil) {
        errorTyped(["code": .string(error.rawValue)], options: options)
    }

    /// Convenience for `errorTyped` with a known password-enrollment error code.
    public func errorTyped(_ error: PasswordEnrollmentOperation.KnownError, options: StepOptions? = nil) {
        errorTyped(["code": .string(error.rawValue)], options: options)
    }
}
