import CorbadoObserve
import SwiftUI

/// S21–S25: Conditional UI: a passkey assertion armed with `performAutoFillAssistedRequests`
/// surfaces as a QuickType chip on the identifier field. Arm timing (before / after focus), the
/// silence cases (typing, focus loss, backgrounding), the handover to a modal request
/// (`cancel()` first, or not; the "already in progress" hazard) and re-arming are the
/// experiments. With the password field shown, the AF password chip competes with the passkey
/// chip (S24) and the CUI steps are hosted on the password-login subflow instead.
struct CuiIdentifierScreen: View {
    let context: ScreenContext

    @State private var identifier = ""
    @State private var password = ""
    // Persisted: the screen is re-created on every screen switch, the experiment setup must not be.
    @AppStorage("cui_armBeforeFocus") private var armBeforeFocus = true
    @AppStorage("cui_cancelBeforeModal") private var cancelBeforeModal = true
    @AppStorage("cui_showPassword") private var showPassword = false
    @State private var armed: Ceremony?
    @State private var armedCount = 0
    @State private var status: String?
    @State private var started = false
    @State private var identifierOp: ProvideIdentifierOperation?
    @State private var passwordOp: PasswordLoginOperation?

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Welcome", subtitle: "Your passkey is one tap away.")
            ProbedTextField(
                fieldName: "identifier", text: $identifier, placeholder: "Email", contentType: .username,
                keyboardType: .emailAddress,
                onChange: { value in
                    identifierOp?.identifierField.changed(newLength: value.count)
                    passwordOp?.identifierField.changed(newLength: value.count)
                },
                onFocus: { focused in
                    identifierOp?.identifierField.focusChanged(focused)
                    passwordOp?.identifierField.focusChanged(focused)
                    if focused, !armBeforeFocus, armed == nil { arm(trigger: "focus") }
                })
            if showPassword {
                ProbedTextField(
                    fieldName: "password", text: $password, placeholder: "Password", contentType: .password,
                    isSecure: true, onChange: { passwordOp?.passwordField.changed(newLength: $0.count) },
                    onFocus: { passwordOp?.passwordField.focusChanged($0) })
            }
            if !showPassword { Button("Continue") { submitIdentifier() }.buttonStyle(.pill) }
            Button("Sign in with passkey") {
                Probe.log("ui_tap", ["target": "passkey-modal", "armed": armed != nil])
                Task { await modalPasskey() }
            }
            .buttonStyle(.softPill)
            Button(armed == nil ? "Arm conditional request" : "Cancel armed request") {
                if let armed {
                    Probe.log("ui_tap", ["target": "cui-cancel"])
                    armed.cancel()
                } else {
                    Probe.log("ui_tap", ["target": "cui-arm"])
                    arm(trigger: "button")
                }
            }
            .buttonStyle(.outlinePill)

            Toggle("Arm before focus (on flow start)", isOn: $armBeforeFocus).font(.footnote)
            Toggle("cancel() armed request before modal", isOn: $cancelBeforeModal).font(.footnote)
            Toggle("Show password field (AF chip next to passkey chip)", isOn: $showPassword).font(.footnote)
            Text("armed: \(armed == nil ? "no" : "yes") · arms this flow: \(armedCount)")
                .font(.footnote).foregroundStyle(Theme.inkMuted)
            if let status { Text(status).font(.callout) }
        }
        .onChange(of: context.flowActive, initial: true) { _, active in
            guard active, !started, let tracker = context.tracker else { return }
            started = true
            tracker.authMethodDecisionStarted("pre-identifier", decisionOptions: ["identifier-email", "passkey-login"])
            startForm(tracker)
            if armBeforeFocus { arm(trigger: "flow-start") }
        }
        .onChange(of: showPassword) { _, _ in
            // The form changed shape: one host operation at a time (the old one stays unfinished).
            identifierOp = nil
            passwordOp = nil
            if context.flowActive, let tracker = context.tracker { startForm(tracker) }
        }
        // Armed requests are process-scoped: one left behind blocks every later arm with 1004.
        .onDisappear { armed?.cancel() }
    }

    /// The subflow that hosts the `cui-*` steps: provide-identifier for the lone identifier field,
    /// password-login when the password field is part of the form.
    private func startForm(_ tracker: ObserveTracker) {
        if showPassword, passwordOp == nil {
            let op = tracker.passwordLoginOperation()
            op.start(specType: .withIdentifier, actor: "system")
            passwordOp = op
        } else if !showPassword, identifierOp == nil {
            let op = tracker.provideIdentifierOperation()
            op.start(specType: .email, actor: "system", ignoreAsInteraction: true)
            identifierOp = op
        }
    }

    /// The hosted CUI steps: password-login when the password field is part of the form,
    /// provide-identifier for the lone identifier field.
    private var cui: ConditionalUISteps? { showPassword ? passwordOp?.cui : identifierOp?.cui }

    private func arm(trigger: String) {
        guard !context.rpId.isEmpty, let (request, optionsJson) = context.webAuthn.assertionRequest(rpId: context.rpId)
        else {
            status = "rpId not set — configure it in the devbar first"
            return
        }
        let cui = cui
        cui?.getOptionsStarted()
        cui?.getOptionsFinished(assertionOptions: optionsJson)
        cui?.ceremonyStarted()
        let ceremony = Ceremony(requests: [request], trigger: "cui-\(trigger)")
        armed = ceremony
        armedCount += 1
        status = "Conditional request armed (\(trigger))."
        Task {
            let outcome = await ceremony.performAutoFillAssisted()
            if armed === ceremony { armed = nil }
            switch outcome {
            case .passkeyAssertion(let assertion):
                cui?.ceremonyFinished(assertion: assertion)
                if PasskeyFlows.completeLogin(assertion: assertion, postResponse: cui?.postResponse, context: context)
                    == nil
                {
                    status = "Backend rejected the passkey assertion."
                }
            case .failure(let error):
                // Our own cancel() (navigation, modal handover) settles as 1001: not an error.
                if !ceremony.cancelled { cui?.ceremonyFailed(error) }
                status = "CUI settled: \((error as NSError).domain):\((error as NSError).code)"
            default:
                status = "Unexpected outcome"
            }
        }
    }

    /// S23: handover to a modal request while (maybe) armed.
    private func modalPasskey() async {
        guard !context.rpId.isEmpty, let (request, optionsJson) = context.webAuthn.assertionRequest(rpId: context.rpId)
        else {
            status = "rpId not set — configure it in the devbar first"
            return
        }
        if cancelBeforeModal, let armed {
            armed.cancel()
            // Give the cancel a runloop turn to settle before the modal request.
            try? await Task.sleep(for: .milliseconds(50))
        }
        let attempt = context.tracker?.passkeyLoginOperation().begin(
            specType: .noIdentifier, assertionOptions: optionsJson)
        let outcome = await Ceremony(requests: [request], trigger: "modal-after-cui").perform(
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

    private func submitIdentifier() {
        Probe.log("ui_tap", ["target": "continue"])
        guard !identifier.isEmpty else {
            status = "Please enter your email."
            return
        }
        let step = identifierOp?.postResponse
        step?.start()
        Task {
            let result = await context.backend.identifierCheck(identifier)
            switch result {
            case .success:
                step?.finished(options: StepOptions(userReference: UserReference(identifier: identifier)))
                armed?.cancel()
                context.navigate("login-form-password")
            default:
                step?.errorTyped(["code": .string(result.code)])
                status = "Identifier check failed (\(result.code))."
            }
        }
    }
}
