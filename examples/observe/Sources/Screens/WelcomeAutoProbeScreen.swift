import CorbadoObserve
import SwiftUI

/// S1/S2: the native2 welcome pattern. Identifier field, passkey-only assertion fired
/// automatically on flow start with `preferImmediatelyAvailableCredentials` (nothing shows without
/// a local passkey; the delegate answers 1001 instantly). Tracked as a `system-credential` sheet
/// requesting passkeys only. Extras: the re-fire button (S8, usernameless request right after a
/// dismissal) and the hidden `.password` harvest field (S14). A QuickType pick on the identifier
/// field also fills the hidden password, and the app submits both, skipping the password screen.
/// Dismissing the sheet lands the user on the identifier field where AutoFill takes over
/// (S16 → S13).
struct WelcomeAutoProbeScreen: View {
    let context: ScreenContext

    @State private var identifier = ""
    @State private var harvestedPassword = ""
    @AppStorage("welcome_harvestEnabled") private var harvestEnabled = true
    @State private var busy = false
    @State private var status: String?
    @State private var provideIdentifier: ProvideIdentifierOperation?
    @State private var started = false

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Welcome", subtitle: "Sign in or create an account.")
            ProbedTextField(
                fieldName: "identifier", text: $identifier, placeholder: "Email", contentType: .username,
                keyboardType: .emailAddress,
                onChange: { provideIdentifier?.identifierField.changed(newLength: $0.count) },
                onFocus: { provideIdentifier?.identifierField.focusChanged($0) })
            if harvestEnabled {
                ProbedTextField(
                    fieldName: "hidden-password", text: $harvestedPassword, contentType: .password, isSecure: true,
                    onChange: harvested
                )
                .frame(width: 1, height: 1).opacity(0.02).accessibilityHidden(true)
            }
            Button(busy ? "Checking…" : "Continue") { submitIdentifier() }
                .buttonStyle(.pill).disabled(busy)
            Button("Sign in with a passkey") {
                Probe.log("ui_tap", ["target": "passkey-refire"])
                Task { await passkeyRefire() }
            }
            .buttonStyle(.softPill)
            Toggle("Hidden password harvest field (native2)", isOn: $harvestEnabled).font(.footnote)
            if let status { Text(status).font(.callout) }
            if context.rpId.isEmpty {
                Text("rpId not set (devbar) — no passkey requests.").font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
        .onChange(of: context.flowActive, initial: true) { _, active in
            guard active, !started else { return }
            started = true
            Task { await autoProbe() }
        }
    }

    /// The situation: the probe fires when the flow starts on this screen.
    private func autoProbe() async {
        guard let tracker = context.tracker else { return }
        tracker.authMethodDecisionStarted(
            "pre-identifier",
            decisionOptions: ["identifier-email", "system-credential", "passkey-login-no-identifier"])
        // The identifier field renders with the screen: auto provide-identifier start (actor system).
        let identifierOp = tracker.provideIdentifierOperation()
        identifierOp.start(specType: .email, actor: "system", ignoreAsInteraction: true)
        provideIdentifier = identifierOp

        guard !context.rpId.isEmpty, let (request, optionsJson) = context.webAuthn.assertionRequest(rpId: context.rpId)
        else { return }
        let attempt = tracker.systemCredentialOperation().begin(
            requested: [.passkey], preferImmediatelyAvailable: true, assertionOptions: optionsJson)
        let outcome = await Ceremony(requests: [request], trigger: "auto").perform(preferImmediatelyAvailable: true)
        switch outcome {
        case .passkeyAssertion(let assertion):
            attempt.resolved(.passkey, assertion: assertion)
            if PasskeyFlows.completeLogin(
                assertion: assertion, postResponse: attempt.passkeyPostResponse, context: context)
                == nil
            {
                status = "Backend rejected the passkey assertion."
            }
        case .failure(let error):
            attempt.failed(error)
            status = "AS: \((error as NSError).domain):\((error as NSError).code)"
        default:
            status = "Unexpected outcome"
        }
    }

    /// The native2 re-fire: passkey-only, usernameless, UI always intended.
    private func passkeyRefire() async {
        guard !context.rpId.isEmpty, let (request, optionsJson) = context.webAuthn.assertionRequest(rpId: context.rpId)
        else {
            status = "rpId not set — configure it in the devbar first"
            return
        }
        let attempt = context.tracker?.passkeyLoginOperation().begin(
            specType: .noIdentifier, assertionOptions: optionsJson)
        let outcome = await Ceremony(requests: [request], trigger: "button-refire").perform(
            preferImmediatelyAvailable: false)
        switch outcome {
        case .passkeyAssertion(let assertion):
            attempt?.ceremonyFinished(assertion: assertion)
            if PasskeyFlows.completeLogin(assertion: assertion, postResponse: attempt?.postResponse, context: context)
                == nil
            {
                status = "Backend rejected the passkey assertion."
            }
        case .failure(let error):
            attempt?.ceremonyFailed(error)
            status = "AS: \((error as NSError).domain):\((error as NSError).code)"
        default:
            status = "Unexpected outcome"
        }
    }

    /// S14: the hidden password field received a value; only a system fill can do that. The
    /// credential arrived before its screen existed; native2 submits right away.
    private func harvested(_ password: String) {
        guard !password.isEmpty, !identifier.isEmpty, !busy else { return }
        Probe.log("harvest", ["identifierLength": identifier.count, "passwordLength": password.count])
        busy = true
        Task {
            provideIdentifier?.postResponse.start()
            provideIdentifier?.postResponse.finished(
                options: StepOptions(userReference: UserReference(identifier: identifier)))
            let op = context.tracker?.passwordLoginOperation()
            op?.start(specType: .knownIdentifier, actor: "system")
            op?.passwordField.changed(newLength: password.count)
            op?.postResponse.start()
            let result = await context.backend.passwordLogin(identifier: identifier, password: password)
            busy = false
            switch result {
            case .success(let userId):
                let user = UserReference(userId: userId, identifier: identifier)
                op?.postResponse.finished(options: StepOptions(userReference: user))
                context.tracker?.flowFinished("login", options: StepOptions(userReference: user))
                Probe.log("login_success", ["identifierLength": identifier.count, "how": "harvest"])
                context.loginSuccess(identifier)
            default:
                op?.postResponse.errorTyped(["code": .string(result.code)])
                status = "Harvested login failed (\(result.code))."
            }
        }
    }

    private func submitIdentifier() {
        Probe.log("ui_tap", ["target": "continue"])
        guard !identifier.isEmpty else {
            provideIdentifier?.clientValidation.errorTyped(["code": .string("empty_identifier")])
            status = "Please enter your email."
            return
        }
        busy = true
        provideIdentifier?.postResponse.start()
        Task {
            let result = await context.backend.identifierCheck(identifier)
            busy = false
            switch result {
            case .success:
                provideIdentifier?.postResponse.finished(
                    options: StepOptions(userReference: UserReference(identifier: identifier)))
                context.navigate("login-form-password")
            default:
                provideIdentifier?.postResponse.errorTyped(["code": .string(result.code)])
                status = "Identifier check failed (\(result.code))."
            }
        }
    }
}
