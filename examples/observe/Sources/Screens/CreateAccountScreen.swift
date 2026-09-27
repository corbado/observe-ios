import SwiftUI

/// Setup utility: seed accounts in the fake backend. Fields are probed and tagged `.username` /
/// `.newPassword`, and creating the account leaves the screen. The fields leave the view
/// hierarchy, which is what lets the system save prompt (S28) and the strong-password
/// suggestion (S29) be observed here. No flow is tracked (setup, not a situation).
struct CreateAccountScreen: View {
    let context: ScreenContext

    @State private var identifier = "user@example.com"
    @State private var password = "correct horse"
    @State private var status: String?
    @State private var refresh = 0

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Create account", subtitle: "Seed the fake backend.")

            ProbedTextField(
                fieldName: "identifier", text: $identifier, placeholder: "Email", contentType: .username,
                keyboardType: .emailAddress)
            ProbedTextField(
                fieldName: "new-password", text: $password, placeholder: "Password", contentType: .newPassword,
                isSecure: true)

            Button("Create account") {
                Probe.log("ui_tap", ["target": "create-account"])
                guard !identifier.isEmpty, !password.isEmpty else { return }
                context.backend.createAccount(identifier: identifier, password: password)
                Probe.log("account_created")
                context.loginSuccess(identifier)
            }
            .buttonStyle(.pill)

            Button("Delete all accounts") {
                context.backend.deleteAllAccounts()
                context.webAuthn.deleteAllPasskeys()
                status = "Fake backend cleared (device-side credentials remain!)"
                refresh += 1
            }
            .buttonStyle(.outlinePill)

            if let status { Text(status).font(.callout) }

            let accounts = context.backend.accounts()
            Text("Accounts (\(accounts.count))").font(.headline).padding(.top)
            ForEach(accounts, id: \.self) { account in
                Text(account + (context.webAuthn.hasPasskey(account) ? " 🔑" : "")).font(.callout)
            }
            .id(refresh)

            Text("Magic identifiers: prefix `locked` → account locked, `slow` → 3s latency.")
                .font(.footnote).foregroundStyle(Theme.inkMuted).padding(.top)
        }
    }
}
