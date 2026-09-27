import SwiftUI
import UIKit

/// A `UITextField` for SwiftUI whose delegate, change notification, responder churn and paste
/// are probed: the app-side fill signature from the research doc (§2.5). SwiftUI's own
/// `TextField` hides all of it. Values never reach the probe, only lengths and deltas.
struct ProbedTextField: UIViewRepresentable {
    let fieldName: String
    @Binding var text: String
    var placeholder = ""
    var contentType: UITextContentType?
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    /// Value changed by user input or a system fill (not by the binding).
    var onChange: (String) -> Void = { _ in }
    /// Focus gained (true) / lost (false).
    var onFocus: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> PasteAwareTextField {
        let field = PasteAwareTextField()
        field.fieldName = fieldName
        field.placeholder = placeholder
        field.textContentType = contentType
        field.isSecureTextEntry = isSecure
        field.keyboardType = keyboardType
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 17)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textDidChange(_:)),
            name: UITextField.textDidChangeNotification,
            object: field)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    func updateUIView(_ field: PasteAwareTextField, context: Context) {
        if field.text != text {
            // Binding-driven write (the app fills the field itself): UIKit posts no change
            // notification for programmatic sets, so the probe line is emitted here.
            field.text = text
            context.coordinator.appSet(length: text.count)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        private let parent: ProbedTextField
        private var lastLength = 0

        init(_ parent: ProbedTextField) {
            self.parent = parent
        }

        private var name: String { parent.fieldName }

        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
        ) -> Bool {
            Probe.log(
                "field_delegate",
                [
                    "field": name,
                    "rangeLength": range.length,
                    "replacementLength": string.count,
                    "lengthBefore": textField.text?.count ?? 0,
                    "paste": (textField as? PasteAwareTextField)?.pasting == true ? true : nil,
                    "msSinceActive": LifecycleProbe.shared.msSinceBecomeActive,
                ])
            return true
        }

        @available(iOS 26.0, *)
        func textField(
            _ textField: UITextField, shouldChangeCharactersInRanges ranges: [NSValue], replacementString string: String
        ) -> Bool {
            Probe.log(
                "field_delegate_ranges",
                [
                    "field": name,
                    "ranges": ranges.count,
                    "replacementLength": string.count,
                    "lengthBefore": textField.text?.count ?? 0,
                    "paste": (textField as? PasteAwareTextField)?.pasting == true ? true : nil,
                    "msSinceActive": LifecycleProbe.shared.msSinceBecomeActive,
                ])
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            Probe.log("field_focus", ["field": name, "state": "begin"])
            parent.onFocus(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            Probe.log("field_focus", ["field": name, "state": "end"])
            parent.onFocus(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func appSet(length: Int) {
            lastLength = length
            Probe.log("field_app_set", ["field": name, "length": length])
        }

        @objc func editingChanged(_ textField: UITextField) {
            let value = textField.text ?? ""
            parent.text = value
            parent.onChange(value)
        }

        @objc func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? UITextField else { return }
            let length = field.text?.count ?? 0
            let delta = length - lastLength
            lastLength = length
            Probe.log(
                "field_text_changed",
                [
                    "field": name,
                    "delta": delta,
                    "length": length,
                    "bulk": abs(delta) > 1 ? true : nil,
                    "isFirstResponder": field.isFirstResponder,
                    "msSinceActive": LifecycleProbe.shared.msSinceBecomeActive,
                ])
        }
    }
}

/// `UITextField` that knows when a change comes from the paste menu, the one bulk-change source
/// app code can tell apart with certainty. The delegate call arrives after `paste(_:)` returns,
/// so the flag stays up for a short window instead of the call's duration.
final class PasteAwareTextField: UITextField {
    var fieldName = ""
    private var pastedAt: Date?

    var pasting: Bool { pastedAt.map { Date().timeIntervalSince($0) < 0.3 } ?? false }

    override func paste(_ sender: Any?) {
        pastedAt = Date()
        Probe.log("field_paste", ["field": fieldName])
        super.paste(sender)
    }
}
