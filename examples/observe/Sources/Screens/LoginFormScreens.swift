import CorbadoObserve
import SwiftUI

/// Shared password-login plumbing of the three login-form screens: SDK operation lifecycle,
/// submission against the fake backend, outcome mapping. One screen = one form shape.
@MainActor
final class PasswordLoginModel: ObservableObject {
    @Published var identifier: String
    @Published var password = ""
    @Published var busy = false
    @Published var status: String?

    private(set) var operation: PasswordLoginOperation?
    private let specType: PasswordLoginOperation.SpecType

    init(specType: PasswordLoginOperation.SpecType, identifier: String = "") {
        self.specType = specType
        self.identifier = identifier
    }

    /// Emits the password-login subflow start once the flow is active on this screen.
    func flowActiveChanged(_ context: ScreenContext) {
        guard context.flowActive, operation == nil, let tracker = context.tracker else { return }
        let op = tracker.passwordLoginOperation()
        op.start(specType: specType)
        // A remembered identifier is an announced app write, not a fill.
        if !identifier.isEmpty {
            op.identifierField.applicationFill(actor: "app")
            op.identifierField.changed(newLength: identifier.count)
        }
        operation = op
    }

    func identifierChanged(_ value: String) {
        operation?.identifierField.changed(newLength: value.count)
    }

    func passwordChanged(_ value: String) {
        operation?.passwordField.changed(newLength: value.count)
    }

    func identifierFocus(_ focused: Bool) {
        operation?.identifierField.focusChanged(focused)
    }

    func passwordFocus(_ focused: Bool) {
        operation?.passwordField.focusChanged(focused)
    }

    func submit(_ context: ScreenContext) {
        Probe.log("ui_tap", ["target": "login"])
        status = nil
        let op = operation
        guard !identifier.isEmpty, !password.isEmpty else {
            op?.clientValidation.start()
            op?.clientValidation.errorTyped(["code": .string("empty_fields")])
            status = "Please fill in email and password."
            return
        }
        op?.clientValidation.start()
        op?.clientValidation.finished()
        busy = true
        op?.postResponse.start()
        Task {
            let result = await context.backend.passwordLogin(identifier: identifier, password: password)
            busy = false
            switch result {
            case .success(let userId):
                let user = UserReference(userId: userId, identifier: identifier)
                op?.postResponse.finished(options: StepOptions(userReference: user))
                context.tracker?.flowFinished("login", options: StepOptions(userReference: user))
                Probe.log("login_success", ["identifierLength": identifier.count])
                context.loginSuccess(identifier)
            case .invalidPassword:
                op?.postResponse.errorTyped(.invalidPassword)
                status = "Wrong password."
            case .userNotFound:
                op?.postResponse.errorTyped(.userNotFound)
                status = "No account with this email."
            case .accountLocked:
                op?.postResponse.errorTyped(.accountLocked)
                status = "Account locked."
            }
        }
    }
}

/// S11 (+ S15–S19 as tester actions): the classic identifier+password one-screen form. A
/// QuickType chip on either field fills both after Face ID. The richest AutoFill observation
/// surface; nothing fires automatically.
struct LoginFormScreen: View {
    let context: ScreenContext
    @StateObject private var model = PasswordLoginModel(specType: .withIdentifier)

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Log in", subtitle: "Your email and password, one screen.")
            ProbedTextField(
                fieldName: "identifier", text: $model.identifier, placeholder: "Email", contentType: .username,
                keyboardType: .emailAddress, onChange: model.identifierChanged, onFocus: model.identifierFocus)
            ProbedTextField(
                fieldName: "password", text: $model.password, placeholder: "Password", contentType: .password,
                isSecure: true, onChange: model.passwordChanged, onFocus: model.passwordFocus)
            Button(model.busy ? "Signing in…" : "Log in") { model.submit(context) }
                .buttonStyle(.pill).disabled(model.busy)
            if let status = model.status { Text(status).font(.callout) }
        }
        .onChange(of: context.flowActive, initial: true) { _, _ in model.flowActiveChanged(context) }
    }
}

/// S12: password fill with the identifier known (native2 pattern). Post-identifier password
/// screen, chip fills the password only. A hidden 1pt `.username` field carries the identifier so
/// the system can pair the credential (save prompt, chip scoping).
struct LoginFormPasswordScreen: View {
    let context: ScreenContext
    @StateObject private var model: PasswordLoginModel

    init(context: ScreenContext) {
        self.context = context
        _model = StateObject(
            wrappedValue: PasswordLoginModel(specType: .knownIdentifier, identifier: context.rememberedIdentifier))
    }

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Welcome back", subtitle: model.identifier)
            ProbedTextField(
                fieldName: "hidden-identifier", text: $model.identifier, contentType: .username,
                keyboardType: .emailAddress, onChange: model.identifierChanged, onFocus: model.identifierFocus
            )
            .frame(width: 1, height: 1).opacity(0.02).accessibilityHidden(true)
            ProbedTextField(
                fieldName: "password", text: $model.password, placeholder: "Password", contentType: .password,
                isSecure: true, onChange: model.passwordChanged, onFocus: model.passwordFocus)
            Button(model.busy ? "Signing in…" : "Log in") { model.submit(context) }
                .buttonStyle(.pill).disabled(model.busy)
            if let status = model.status { Text(status).font(.callout) }
        }
        .onChange(of: context.flowActive, initial: true) { _, _ in model.flowActiveChanged(context) }
    }
}

/// S13: identifier-only fill on a lone identifier field. Continue runs the server-side
/// identifier check and moves on to the password screen mid-flow.
struct LoginFormIdentifierScreen: View {
    let context: ScreenContext

    @State private var identifier = ""
    @State private var busy = false
    @State private var status: String?
    @State private var operation: ProvideIdentifierOperation?

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Welcome", subtitle: "Sign in or create an account.")
            ProbedTextField(
                fieldName: "identifier", text: $identifier, placeholder: "Email", contentType: .username,
                keyboardType: .emailAddress, onChange: { operation?.identifierField.changed(newLength: $0.count) },
                onFocus: { operation?.identifierField.focusChanged($0) })
            Button(busy ? "Checking…" : "Continue") { submit() }
                .buttonStyle(.pill).disabled(busy)
            if let status { Text(status).font(.callout) }
        }
        .onChange(of: context.flowActive, initial: true) { _, active in
            guard active, operation == nil, let tracker = context.tracker else { return }
            let op = tracker.provideIdentifierOperation()
            op.start(specType: .email)
            operation = op
        }
    }

    private func submit() {
        Probe.log("ui_tap", ["target": "continue"])
        guard !identifier.isEmpty else {
            operation?.clientValidation.errorTyped(["code": .string("empty_identifier")])
            status = "Please enter your email."
            return
        }
        busy = true
        operation?.postResponse.start()
        Task {
            let result = await context.backend.identifierCheck(identifier)
            busy = false
            switch result {
            case .success:
                operation?.postResponse.finished(
                    options: StepOptions(userReference: UserReference(identifier: identifier)))
                context.navigate("login-form-password")
            default:
                operation?.postResponse.errorTyped(["code": .string(result.code)])
                status = "Identifier check failed (\(result.code))."
            }
        }
    }
}
