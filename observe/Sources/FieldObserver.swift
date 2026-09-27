import Foundation

/// Observation handle for one input field, obtained from the owning subflow operation (e.g.
/// `passwordLoginOperation().passwordField`). The `fieldType` is fixed by the SDK, so the low
/// vocabulary can never drift. Operations without observable fields expose no handles.
///
/// The integration forwards a single signal per value change (lengths only, never the value):
///
/// ```swift
/// SecureField("Password", text: $password)
///     .onChange(of: password) { newValue in
///         op.passwordField.changed(newLength: newValue.count)
///     }
/// ```
///
/// Everything else is automatic: typing batches into one `input` low per stretch, bulk changes
/// emit `big-input-add`/`big-input-rem`, announced writes (`applicationFill`) emit `af-fill` with
/// their actor, and batches flush on step starts / flow finish / app background. The affordance
/// signals `shown()`/`hidden()`/`unavailable()` are manual: iOS has no API to observe the
/// QuickType/password AutoFill bar.
///
/// Optional focus evidence: forward first-responder changes through `focusChanged(_:)`, from
/// `@FocusState` in SwiftUI or from the editing delegate callbacks in UIKit. A system fill moves
/// focus across the fields it writes. The app's active-state churn around a fill (Face ID) is
/// reported by the tracker itself as `window-blur`/`window-focus` while a field is focused, so a
/// field that goes away focused forwards `false` first.
///
/// Main-safe, never throws. One handle per rendered field; a fresh operation (new screen/attempt)
/// provides fresh handles.
public final class FieldObserver: @unchecked Sendable {
    private let engine: AutofillEngine
    /// Semantic field type (subflow-type vocabulary) stamped on this field's lows.
    public let fieldType: String

    private let lock = NSLock()
    private var previousLength = 0

    init(engine: AutofillEngine, fieldType: String) {
        self.engine = engine
        self.fieldType = fieldType
    }

    /// The field's value changed to `newLength` characters. Set `paste` when the integration
    /// knows this change is a user paste with certainty; the bulk low then carries
    /// `actor: "user"` instead of landing in the unknown bucket.
    public func changed(newLength: Int, paste: Bool = false) {
        let previous = lock.withLocked {
            let value = previousLength
            previousLength = newLength
            return value
        }
        engine.fieldChanged(fieldType: fieldType, previousLength: previous, newLength: newLength, paste: paste)
    }

    /// The field became (`true`) or stopped being (`false`) first responder. Emits `focus`/`blur`.
    /// Forward `false` before the field is torn down while focused.
    public func focusChanged(_ focused: Bool) {
        engine.fieldFocus(handle: ObjectIdentifier(self), fieldType: fieldType, focused: focused)
    }

    /// The integration is about to write a value into the field itself. The next bulk change
    /// within a short window emits `af-fill` with `actor` instead of an unattributed
    /// `big-input-add`. The default `"app"` covers generic programmatic writes (e.g. applying a
    /// system credential result); pass the mechanism when known.
    public func applicationFill(actor: String = "app") {
        engine.applicationFill(fieldType: fieldType, actor: actor)
    }

    /// Manually report an autofill affordance shown for this field (`af-shown`).
    public func shown() {
        engine.shown(fieldType: fieldType)
    }

    /// Manually report the affordance hidden (`af-hidden`); carries the shown duration.
    public func hidden() {
        engine.hidden(fieldType: fieldType)
    }

    /// Manually report that autofill had nothing to offer (`af-unavailable`).
    public func unavailable() {
        engine.unavailable(fieldType: fieldType)
    }
}
