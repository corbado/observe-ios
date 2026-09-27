import AuthenticationServices
import CorbadoObserve
import SwiftUI

/// S5/S6: the WWDC22 launch pattern. One `ASAuthorizationController` carrying a passkey
/// assertion request and a saved-password request; the system shows a single chooser and hands
/// back exactly one credential of a type unknown at call time. That is what the system-credential
/// subflow encapsulates. The password-only request (S6) is the degenerate case.
struct MixedRequestScreen: View {
    let context: ScreenContext

    @AppStorage("mixed_preferImmediate") private var preferImmediate = false
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Sign in", subtitle: "Passkey or saved password, one system sheet.")
            Button(busy ? "Signing in…" : "Sign in") {
                Probe.log("ui_tap", ["target": "mixed-request", "preferImmediate": preferImmediate])
                Task { await run(requested: [.passkey, .password]) }
            }
            .buttonStyle(.pill).disabled(busy)
            Button("Saved password only (S6)") {
                Probe.log("ui_tap", ["target": "password-request"])
                Task { await run(requested: [.password]) }
            }
            .buttonStyle(.softPill).disabled(busy)
            Toggle("preferImmediatelyAvailableCredentials", isOn: $preferImmediate).font(.footnote)
            if let status { Text(status).font(.callout) }
            if context.rpId.isEmpty {
                Text("rpId not set (devbar) — no passkey requests.").font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func run(requested: [SystemCredentialOperation.RequestedOption]) async {
        var requests: [ASAuthorizationRequest] = []
        var optionsJson: String?
        if requested.contains(.passkey) {
            guard !context.rpId.isEmpty, let (request, json) = context.webAuthn.assertionRequest(rpId: context.rpId)
            else {
                status = "rpId not set — configure it in the devbar first"
                return
            }
            requests.append(request)
            optionsJson = json
        }
        if requested.contains(.password) { requests.append(ASAuthorizationPasswordProvider().createRequest()) }

        busy = true
        defer { busy = false }
        let attempt = context.tracker?.systemCredentialOperation().begin(
            requested: requested, preferImmediatelyAvailable: preferImmediate, autoTriggered: false,
            assertionOptions: optionsJson)
        let outcome = await Ceremony(requests: requests, trigger: "mixed-button").perform(
            preferImmediatelyAvailable: preferImmediate)
        switch outcome {
        case .passkeyAssertion(let assertion):
            attempt?.resolved(.passkey, assertion: assertion)
            if PasskeyFlows.completeLogin(
                assertion: assertion, postResponse: attempt?.passkeyPostResponse, context: context) == nil
            {
                status = "Backend rejected the passkey assertion."
            }
        case .password(let credential):
            attempt?.resolved(.password)
            await passwordLogin(credential, postResponse: attempt?.passwordPostResponse)
        case .failure(let error):
            attempt?.failed(error)
            status = "AS: \((error as NSError).domain):\((error as NSError).code)"
        default:
            status = "Unexpected outcome"
        }
    }

    /// The chooser handed us username + password: submit them, no form involved.
    private func passwordLogin(_ credential: ASPasswordCredential, postResponse: StepHandle?) async {
        Probe.log(
            "password_credential",
            ["identifierLength": credential.user.count, "passwordLength": credential.password.count])
        postResponse?.start()
        let result = await context.backend.passwordLogin(identifier: credential.user, password: credential.password)
        switch result {
        case .success(let userId):
            let user = UserReference(userId: userId, identifier: credential.user)
            postResponse?.finished(options: StepOptions(userReference: user))
            context.tracker?.flowFinished("login", options: StepOptions(userReference: user))
            Probe.log("login_success", ["identifierLength": credential.user.count, "how": "system-password"])
            context.loginSuccess(credential.user)
        default:
            postResponse?.errorTyped(["code": .string(result.code)])
            status = "Password from the sheet rejected (\(result.code))."
        }
    }
}
