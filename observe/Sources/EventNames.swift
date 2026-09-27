/// Predefined auth event names. Wire values are snake_case and part of the ingest contract; the
/// backend classifier keys off them, so they must match exactly.
public enum AuthEventName: String, Sendable {
    case flowStarted = "flow_started"
    case flowDecided = "flow_decided"
    case flowFinished = "flow_finished"
    case flowReset = "flow_reset"
    case flowAutoFinished = "flow_auto_finished"
    case authMethodDecisionStarted = "auth_method_decision_started"
    case authMethodDecisionFinished = "auth_method_decision_finished"
    case authDecisionStarted = "auth_decision_started"
    case authDecisionFinished = "auth_decision_finished"
    case subflowStarted = "subflow_started"
    case subflowTrigger = "subflow_trigger"
    case subflowStepStarted = "subflow_step_started"
    case subflowStepFinished = "subflow_step_finished"
    case subflowStepError = "subflow_step_error"
    case subflowFinished = "subflow_finished"
    case subflowError = "subflow_error"
    case conversion = "conversion"
}

/// Subflow types understood by the backend classifier. Wire values are hyphenated and part of the
/// ingest contract.
public enum SubflowType: String, Sendable {
    case passkeyEnrollment = "passkey-enrollment"
    case passkeyLogin = "passkey-login"

    /// System credential chooser (`ASAuthorizationController`). Includes passkey-only entry
    /// sheets; dedicated passkey buttons use `passkeyLogin`.
    case systemCredential = "system-credential"
    case emailOtp = "email-otp"
    case emailLink = "email-link"
    case socialLogin = "social-login"
    case smsOtp = "sms-otp"
    case provideIdentifier = "provide-identifier"
    case provideData = "provide-data"
    case passwordLogin = "password-login"
    case passwordEnrollment = "password-enrollment"
    case totp = "totp"
    case appConfirmation = "app-confirmation"
    case captcha = "captcha"
}
