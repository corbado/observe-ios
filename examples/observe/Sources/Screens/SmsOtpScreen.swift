import CorbadoObserve
import SwiftUI

/// S18: SMS one-time code on a `.oneTimeCode` field. The code arrives as a QuickType chip (or is
/// pushed straight into a focused field) with no Face ID gate; the probe records how the system
/// inserts it. Any six-digit code verifies against the fake backend.
struct SmsOtpScreen: View {
    let context: ScreenContext

    @State private var code = ""
    @State private var status: String?
    @State private var operation: SmsOtpOperation?

    var body: some View {
        ScreenColumn {
            ScreenHeader(title: "Enter the code", subtitle: "We sent a 6-digit code to your phone.")
            ProbedTextField(
                fieldName: "otp", text: $code, placeholder: "123456", contentType: .oneTimeCode,
                keyboardType: .numberPad, onChange: { operation?.codeField.changed(newLength: $0.count) },
                onFocus: { operation?.codeField.focusChanged($0) })
            Button("Verify") { verify() }.buttonStyle(.pill)
            Button("Resend code") {
                Probe.log("ui_tap", ["target": "otp-resend"])
                operation?.resend.start()
                operation?.resend.finished()
            }
            .buttonStyle(.outlinePill)
            Text("Text this phone: \"Your ObserveExample code is 482913\" (any 6 digits verify).")
                .font(.footnote).foregroundStyle(Theme.inkMuted)
            if let status { Text(status).font(.callout) }
        }
        .onChange(of: context.flowActive, initial: true) { _, active in
            guard active, operation == nil, let tracker = context.tracker else { return }
            let op = tracker.smsOtpOperation()
            op.start(specType: .login)
            operation = op
        }
    }

    private func verify() {
        Probe.log("ui_tap", ["target": "otp-verify"])
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            status = "Enter the 6-digit code."
            return
        }
        let identifier = context.rememberedIdentifier.isEmpty ? "user@example.com" : context.rememberedIdentifier
        let user = UserReference(userId: context.backend.userIdFor(identifier), identifier: identifier)
        operation?.postResponse.start()
        operation?.postResponse.finished(options: StepOptions(userReference: user))
        context.tracker?.flowFinished("login", options: StepOptions(userReference: user))
        Probe.log("login_success", ["identifierLength": identifier.count, "how": "sms-otp"])
        context.loginSuccess(identifier)
    }
}
