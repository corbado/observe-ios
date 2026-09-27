/// SMS-OTP subflow operation. There is deliberately no `send` step: the sending is implied by the
/// subflow start.
///
/// ```swift
/// let op = tracker.smsOtpOperation()
/// op.start(specType: .login)
/// op.postResponse.start()
/// // ... verify the code with your backend ...
/// op.postResponse.finished(options: StepOptions(userReference: user))
/// ```
public final class SmsOtpOperation: OperationFull, @unchecked Sendable {
    /// Whether the OTP verifies a login or enrolls/verifies a new number.
    public enum SpecType: String, Sendable {
        case login = "sms-otp-login"
        case enrollment = "sms-otp-enrollment"
    }

    /// Observation handle for the code input field.
    public let codeField: FieldObserver

    /// Submitting the entered code and its outcome.
    public let postResponse: StepHandle

    /// The user requesting another code.
    public let resend: StepHandle

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.smsOtp
        codeField = tracker.fieldObserver("sms-otp")
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
