import CorbadoObserve
import SwiftUI

/// Catalog of situation screens. Each screen represents ONE situation in an auth process (see
/// docs/as-af-situations.md for the S# mapping). Stubs are listed so the catalog shape is
/// visible; they become real screens in later stages.
@MainActor
struct SituationScreen: Identifiable {
    let id: String
    let title: String
    let group: String
    var implemented = false
    /// Flow the screen participates in (auto-start emits it on load); nil = setup utility.
    var flowName: String?
    /// Remembered-identifier session (the reference-suite convention for post-identifier starts):
    /// a direct flow start on this screen carries the remembered user on `flow_started` and emits
    /// NO provide-identifier events, since the identifier was never typed this session.
    var rememberedIdentifier = false
    var content: (ScreenContext) -> AnyView = { _ in AnyView(EmptyView()) }
}

/// What a screen gets from the host: SDK, fake backend, devbar settings, flow state and the
/// navigation callbacks. Screens never touch the host model directly.
@MainActor
struct ScreenContext {
    let tracker: ObserveTracker?
    let backend: FakeAuthBackend
    let webAuthn: FakeWebAuthn
    /// Relying-party id for passkey ceremonies; empty = passkey requests omitted (devbar setting).
    let rpId: String
    /// True while a flow is active on this screen (auto-started or via the devbar button).
    let flowActive: Bool
    /// The identifier a remembered-identifier screen starts with.
    let rememberedIdentifier: String
    /// Navigate to another screen WITHOUT resetting the flow (mid-flow transitions). The target
    /// screen must not re-emit a flow start; it emits its own decision on arrival.
    let navigate: (String) -> Void
    /// The login completed (flow_finished already emitted by the screen): show the success screen.
    let loginSuccess: (String?) -> Void
    /// Success screen only: who just logged in.
    let lastLoginIdentifier: String?
    /// Success screen only: back to the start screen of the finished flow, fresh flow.
    let restartFlow: () -> Void
}

@MainActor
enum ScreenRegistry {
    static let screens: [SituationScreen] = [
        // --- Setup ---
        SituationScreen(
            id: "create-account", title: "Create account", group: "Setup", implemented: true,
            content: { AnyView(CreateAccountScreen(context: $0)) }),
        SituationScreen(
            id: "enroll-passkey", title: "enroll-passkey (settings, manual) S9", group: "Setup", implemented: true,
            flowName: "enrollment",
            content: { AnyView(EnrollPasskeyScreen(context: $0, offer: false)) }),
        // --- Welcome (auto ceremonies) ---
        SituationScreen(
            id: "welcome-auto-probe", title: "welcome-auto-probe S1 S2 S8 S14 S16", group: "Welcome",
            implemented: true, flowName: "login",
            content: { AnyView(WelcomeAutoProbeScreen(context: $0)) }),
        SituationScreen(
            id: "passkey-button", title: "passkey-button (identifier known) S3 S7", group: "Welcome",
            implemented: true, flowName: "login", rememberedIdentifier: true,
            content: { AnyView(PasskeyButtonScreen(context: $0, usernameless: false)) }),
        SituationScreen(
            id: "passkey-button-usernameless", title: "passkey-button-usernameless S4 S7", group: "Welcome",
            implemented: true, flowName: "login",
            content: { AnyView(PasskeyButtonScreen(context: $0, usernameless: true)) }),
        SituationScreen(
            id: "mixed-request", title: "mixed-request (passkey + saved password) S5 S6", group: "Welcome",
            implemented: true, flowName: "login",
            content: { AnyView(MixedRequestScreen(context: $0)) }),
        SituationScreen(
            id: "cui-identifier", title: "cui-identifier S21–S25", group: "Welcome", implemented: true,
            flowName: "login",
            content: { AnyView(CuiIdentifierScreen(context: $0)) }),
        // --- Login form (AutoFill) ---
        SituationScreen(
            id: "login-form", title: "login-form (identifier + password) S11 S15–S19", group: "Login form",
            implemented: true, flowName: "login",
            content: { AnyView(LoginFormScreen(context: $0)) }),
        SituationScreen(
            id: "login-form-password", title: "login-form-password (identifier known) S12", group: "Login form",
            implemented: true, flowName: "login", rememberedIdentifier: true,
            content: { AnyView(LoginFormPasswordScreen(context: $0)) }),
        SituationScreen(
            id: "login-form-identifier", title: "login-form-identifier S13", group: "Login form",
            implemented: true, flowName: "login",
            content: { AnyView(LoginFormIdentifierScreen(context: $0)) }),
        SituationScreen(
            id: "login-form-swiftui", title: "login-form-swiftui (FocusState only) S11", group: "Login form",
            implemented: true, flowName: "login",
            content: { AnyView(SwiftUIFormScreen(context: $0)) }),
        SituationScreen(
            id: "sms-otp", title: "sms-otp (one-time code chip) S18", group: "Login form",
            implemented: true, flowName: "login", rememberedIdentifier: true,
            content: { AnyView(SmsOtpScreen(context: $0)) }),
        // --- Stubs ---
        SituationScreen(id: "security-key", title: "security-key", group: "Stubs"),
        SituationScreen(id: "webview-login", title: "webview-login S20", group: "Stubs"),
        // --- Post-login ---
        SituationScreen(
            id: "enrollment-offer", title: "enrollment-offer (post-login, auto) S9", group: "Post-login",
            implemented: true, flowName: "enrollment", rememberedIdentifier: true,
            content: { AnyView(EnrollPasskeyScreen(context: $0, offer: true)) }),
        // --- Result ---
        SituationScreen(
            id: "login-success", title: "Login success", group: "Result", implemented: true,
            content: { AnyView(LoginSuccessScreen(context: $0)) }),
    ]

    /// Neutral default: no flow, no ceremony firing on a cold start.
    static let `default` = screens.first { $0.id == "create-account" }!

    static func byId(_ id: String?) -> SituationScreen {
        screens.first { $0.id == id && $0.implemented } ?? `default`
    }

    static var groups: [(String, [SituationScreen])] {
        var order: [String] = []
        var byGroup: [String: [SituationScreen]] = [:]
        for screen in screens {
            if byGroup[screen.group] == nil { order.append(screen.group) }
            byGroup[screen.group, default: []].append(screen)
        }
        return order.map { ($0, byGroup[$0]!) }
    }
}
