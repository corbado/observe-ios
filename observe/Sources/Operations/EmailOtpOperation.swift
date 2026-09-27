/// Email-OTP subflow operation. Its step names and spec types are the wire vocabulary the backend
/// classifier keys off.
///
/// ```swift
/// let op = tracker.emailOtpOperation()
/// op.start(specType: .login)
/// op.send.start()
/// op.send.finished()
/// op.postResponse.start()
/// // ... verify the code with your backend ...
/// op.postResponse.finished(options: StepOptions(userReference: user))
/// ```
public final class EmailOtpOperation: OperationFull, @unchecked Sendable {
    /// Whether the OTP verifies a login or enrolls/verifies a new address.
    public enum SpecType: String, Sendable {
        case login = "email-otp-login"
        case enrollment = "email-otp-enrollment"
    }

    /// Observation handle for the code input field.
    public let codeField: FieldObserver

    /// Requesting the OTP email from the host backend.
    public let send: StepHandle

    /// Submitting the entered code and its outcome.
    public let postResponse: StepHandle

    /// The user requesting another code.
    public let resend: StepHandle

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.emailOtp
        codeField = tracker.fieldObserver("email-otp")
        send = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "send")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "post-response")
        resend = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "resend")
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started`.
    public func start(specType: SpecType? = nil, actor: String = "user", options: StepOptions? = nil) {
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        subflowStart(data: data, options: options)
    }
}
