import AuthenticationServices
import LocalAuthentication
import UIKit

/// Instrumented `ASAuthorizationController` run: request mix, options, timing and the typed
/// settle are probed. This is the call-site observation layer from the research doc: the exact
/// seam the SDK's passkey / system-credential operations formalize.
///
/// One instance per ceremony; it retains itself until the delegate settles (the controller holds
/// its delegate weakly). Keep the handle when you need `cancel()` (conditional-UI handover).
@MainActor
final class Ceremony: NSObject {
    enum Outcome: @unchecked Sendable {
        case passkeyAssertion(ASAuthorizationPlatformPublicKeyCredentialAssertion)
        case passkeyRegistration(ASAuthorizationPlatformPublicKeyCredentialRegistration)
        case password(ASPasswordCredential)
        case other(ASAuthorizationCredential)
        case failure(any Error)
    }

    private let controller: ASAuthorizationController
    private let trigger: String
    private let requestKinds: [String]
    private var startedAt = Date()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var retained: Ceremony?
    /// Set by `cancel()`: the 1001 that follows is the app's own doing, not a user answer.
    private(set) var cancelled = false

    init(requests: [ASAuthorizationRequest], trigger: String) {
        controller = ASAuthorizationController(authorizationRequests: requests)
        self.trigger = trigger
        requestKinds = requests.map(Self.describe)
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
    }

    /// Modal ceremony (`performRequests`).
    func perform(preferImmediatelyAvailable: Bool) async -> Outcome {
        start(["preferImmediatelyAvailable": preferImmediatelyAvailable])
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if preferImmediatelyAvailable {
                controller.performRequests(options: [.preferImmediatelyAvailableCredentials])
            } else {
                controller.performRequests()
            }
        }
    }

    /// Conditional UI (`performAutoFillAssistedRequests`): armed, settles only on a chip pick,
    /// an error, or `cancel()`.
    func performAutoFillAssisted() async -> Outcome {
        start(["assisted": true])
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performAutoFillAssistedRequests()
        }
    }

    func cancel() {
        Probe.log("as_cancel", ["trigger": trigger, "msSinceStart": msSinceStart])
        cancelled = true
        controller.cancel()
    }

    private func start(_ extra: [String: Any?]) {
        startedAt = Date()
        retained = self
        var fields: [String: Any?] = ["trigger": trigger, "requests": requestKinds.joined(separator: ",")]
        fields.merge(extra) { _, new in new }
        fields["biometry"] = Self.biometryState
        Probe.log("as_start", fields)
    }

    private var msSinceStart: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    /// S32: what the biometry capability probe says right before the ceremony ("ok" or the
    /// `LAError` code, e.g. -8 = lockout).
    private static var biometryState: String {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok ? "ok" : "laerror:\((error?.code).map(String.init) ?? "unknown")"
    }

    private func settle(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
        retained = nil
    }

    private static func describe(_ request: ASAuthorizationRequest) -> String {
        switch request {
        case is ASAuthorizationPlatformPublicKeyCredentialAssertionRequest: "passkey-assertion"
        case is ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest: "passkey-registration"
        case is ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest: "security-key-assertion"
        case is ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest: "security-key-registration"
        case is ASAuthorizationPasswordRequest: "password"
        case is ASAuthorizationAppleIDRequest: "apple-id"
        default: String(describing: type(of: request))
        }
    }
}

extension Ceremony: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential
        let outcome: Outcome
        let kind: String
        switch credential {
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            outcome = .passkeyAssertion(assertion)
            kind = "passkey-assertion"
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            outcome = .passkeyRegistration(registration)
            kind = "passkey-registration"
        case let password as ASPasswordCredential:
            outcome = .password(password)
            kind = "password"
        default:
            outcome = .other(credential)
            kind = String(describing: type(of: credential))
        }
        Probe.log("as_result", ["trigger": trigger, "durationMs": msSinceStart, "credentialType": kind])
        settle(outcome)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let nsError = error as NSError
        Probe.log(
            "as_error",
            [
                "trigger": trigger,
                "durationMs": msSinceStart,
                "domain": nsError.domain,
                "code": nsError.code,
                "message": String(error.localizedDescription.prefix(200)),
                "underlying": (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain):\($0.code)" },
            ])
        settle(.failure(error))
    }
}

extension Ceremony: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }
}
