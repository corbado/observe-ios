import CorbadoObserve
import SwiftUI

/// S3/S4/S7: button-triggered passkey login, UI always intended. Known identifier (native2's
/// password-screen button): the request carries `allowedCredentials` for that account, and with
/// no matching local credential this is where the hybrid/QR sheet appears. Usernameless: no
/// allow list, discoverable credentials, account chooser.
struct PasskeyButtonScreen: View {
    let context: ScreenContext
    let usernameless: Bool

    @State private var identifier: String
    @State private var status: String?
    @State private var decided = false

    init(context: ScreenContext, usernameless: Bool) {
        self.context = context
        self.usernameless = usernameless
        _identifier = State(initialValue: context.rememberedIdentifier)
    }

    var body: some View {
        ScreenColumn {
            ScreenHeader(
                title: usernameless ? "Welcome back" : "Sign in with your passkey",
                subtitle: usernameless ? "Use a passkey saved on this device." : "Fast and phishing-resistant.")
            if !usernameless {
                Menu {
                    ForEach(context.backend.accounts(), id: \.self) { account in
                        Button(account + (context.webAuthn.hasPasskey(account) ? " 🔑" : "")) { identifier = account }
                    }
                } label: {
                    Label(identifier, systemImage: "person.crop.circle").font(.callout)
                }
            }
            Button(usernameless ? "Sign in with a passkey" : "Sign in with passkey") {
                Probe.log("ui_tap", ["target": usernameless ? "passkey-login-usernameless" : "passkey-login-known"])
                Task { await login() }
            }
            .buttonStyle(.pill)
            if let status { Text(status).font(.callout) }
            if !usernameless, !context.webAuthn.hasPasskey(identifier) {
                Text("No passkey enrolled for this account yet (see enroll-passkey).")
                    .font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
        .onChange(of: context.flowActive, initial: true) { _, active in
            guard active, !decided else { return }
            decided = true
            if usernameless {
                context.tracker?.authMethodDecisionStarted(
                    "pre-identifier", decisionOptions: ["passkey-login", "identifier-email"])
            } else {
                context.tracker?.authMethodDecisionStarted(
                    "post-identifier", decisionOptions: ["passkey-login", "change-identifier"])
            }
        }
    }

    private func login() async {
        guard !context.rpId.isEmpty else {
            status = "rpId not set — configure it in the devbar first"
            return
        }
        guard
            let (request, optionsJson) = context.webAuthn.assertionRequest(
                rpId: context.rpId, identifier: usernameless ? nil : identifier)
        else {
            // Real-backend behavior: no assertion options for a passkey-less user.
            status = "Backend knows no passkey for \(identifier) — enroll one first."
            return
        }
        let attempt = context.tracker?.passkeyLoginOperation().begin(
            specType: usernameless ? .noIdentifier : .knownIdentifier, assertionOptions: optionsJson)
        let outcome = await Ceremony(requests: [request], trigger: "button").perform(preferImmediatelyAvailable: false)
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
}
