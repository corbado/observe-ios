import CorbadoObserve
import SwiftUI

/// S9: passkey registration. Settings variant (`manual`): user-initiated from an account menu.
/// Offer variant (`auto-manual`): shown automatically after a password login for accounts without
/// a passkey (the server-driven upsell), confirmed or declined by the user. Existing ids ride as
/// `excludedCredentials`, so enrolling twice reproduces the exclude-match error.
struct EnrollPasskeyScreen: View {
    let context: ScreenContext
    let offer: Bool

    @State private var identifier: String
    @State private var status: String?
    @State private var refresh = 0

    init(context: ScreenContext, offer: Bool) {
        self.context = context
        self.offer = offer
        _identifier = State(
            initialValue: offer
                ? (context.lastLoginIdentifier ?? context.rememberedIdentifier)
                : context.rememberedIdentifier)
    }

    var body: some View {
        ScreenColumn {
            ScreenHeader(
                title: offer ? "Sign in faster next time" : "Secure your account",
                subtitle: "Create a passkey to sign in with Face ID next time.")
            if offer {
                Text(identifier).font(.callout).foregroundStyle(Theme.inkMuted)
            } else {
                Menu {
                    ForEach(context.backend.accounts(), id: \.self) { account in
                        Button(account) { identifier = account }
                    }
                } label: {
                    Label(identifier, systemImage: "person.crop.circle").font(.callout)
                }
                Text("Passkeys for this account: \(context.webAuthn.passkeyIds(identifier).count)")
                    .font(.callout).id(refresh)
            }
            Button("Create passkey") {
                Probe.log("ui_tap", ["target": "create-passkey"])
                Task { await enroll() }
            }
            .buttonStyle(.pill)
            if offer {
                Button("Not now") {
                    Probe.log("ui_tap", ["target": "enrollment-declined"])
                    context.tracker?.flowFinished("enrollment", explicitOutcome: "declined")
                    context.loginSuccess(identifier)
                }
                .buttonStyle(.outlinePill)
            } else {
                Button("Clear local passkey registry") {
                    context.webAuthn.deleteAllPasskeys()
                    refresh += 1
                    status = "Local passkey registry cleared (device-side passkeys remain!)"
                }
                .buttonStyle(.outlinePill)
            }
            if let status { Text(status).font(.callout) }
        }
    }

    private func enroll() async {
        guard !context.rpId.isEmpty else {
            status = "rpId not set — configure it in the devbar first"
            return
        }
        let (request, optionsJson) = context.webAuthn.registrationRequest(identifier: identifier, rpId: context.rpId)
        let attempt = context.tracker?.passkeyEnrollmentOperation().begin(
            attestationOptions: optionsJson, specType: offer ? "auto-manual" : "manual")
        let outcome = await Ceremony(requests: [request], trigger: offer ? "offer" : "button").perform(
            preferImmediatelyAvailable: false)
        switch outcome {
        case .passkeyRegistration(let registration):
            attempt?.ceremonyFinished(registration: registration)
            attempt?.postResponse.start()
            context.webAuthn.registerPasskey(identifier: identifier, registration: registration)
            attempt?.postResponse.finished()
            context.tracker?.flowFinished("enrollment")
            refresh += 1
            status = "Passkey created ✓"
            Probe.log("enrollment_success", ["identifierLength": identifier.count])
            if offer { context.loginSuccess(identifier) }
        case .failure(let error):
            attempt?.ceremonyFailed(error)
            status = "AS: \((error as NSError).domain):\((error as NSError).code)"
        default:
            status = "Unexpected outcome"
        }
    }
}
