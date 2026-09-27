import Foundation

/// Typed emitter for one step of a subflow: the `start`/`finished`/`error` triple guarantees the
/// exact wire vocabulary the backend classifier expects.
public final class StepHandle: Sendable {
    private let tracker: ObserveTracker
    private let subflowType: SubflowType
    private let stepName: String
    private let ignoreAsInteractionOnStart: Bool

    init(
        tracker: ObserveTracker,
        subflowType: SubflowType,
        stepName: String,
        ignoreAsInteractionOnStart: Bool = false
    ) {
        self.tracker = tracker
        self.subflowType = subflowType
        self.stepName = stepName
        self.ignoreAsInteractionOnStart = ignoreAsInteractionOnStart
    }

    public func start(data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        tracker.trackSubflowStepStarted(
            subflowType,
            stepName: stepName,
            data: data,
            options: options,
            ignoreAsInteraction: ignoreAsInteractionOnStart ? true : nil)
    }

    public func finished(data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        tracker.trackSubflowStepFinished(subflowType, stepName: stepName, data: data, options: options)
    }

    /// Report a step error from a thrown error (normalized to `{name, code, message}`).
    public func error(_ error: any Error, options: StepOptions? = nil) {
        self.error(NormalizedError.from(error), options: options)
    }

    /// Report an application error, preserving its string code in the nested error payload.
    public func error(_ normalized: NormalizedError, options: StepOptions? = nil) {
        var payload: [String: JSONValue] = [:]
        payload.putIfPresent("name", normalized.name)
        payload.putIfPresent("code", normalized.code)
        payload.putIfPresent("message", normalized.message)
        tracker.trackSubflowStepError(
            subflowType, stepName: stepName, data: ["error": .object(payload)], options: options)
    }

    /// Report a step error with a typed payload (e.g. a known error code).
    public func errorTyped(_ data: [String: JSONValue], options: StepOptions? = nil) {
        tracker.trackSubflowStepError(subflowType, stepName: stepName, data: data, options: options)
    }
}

/// Raw platform-error payload for ceremony step errors ({name, code, message}). The SDK never
/// maps error semantics; the backend owns that (raw errors feed the error flavours). `code` is
/// `NSError` `domain:code`, in the wire position the backend reads as the error code.
func rawPlatformErrorData(_ error: any Error) -> [String: JSONValue] {
    let nsError = error as NSError
    return [
        "error": .object([
            "name": .string(String(describing: type(of: error))),
            "code": .string("\(nsError.domain):\(nsError.code)"),
            "message": .string(String(error.localizedDescription.prefix(200))),
        ])
    ]
}

/// Base class for subflow operations: the typed layer that guarantees the event vocabulary
/// (subflow type, step names, payload shapes) the backend classifier keys off.
///
/// All stored properties here and in the subclasses are immutable (`let`). The `@unchecked`
/// is only for the non-final-class conformance rule, not for hidden mutable state.
public class OperationFull: @unchecked Sendable {
    let tracker: ObserveTracker
    let subflowType: SubflowType

    init(tracker: ObserveTracker, subflowType: SubflowType) {
        self.tracker = tracker
        self.subflowType = subflowType
    }

    /// Emits `subflow_started`. Supported `data` keys:
    /// `actor` (`"user"` or `"system"`), `explicitSpecType`, and `ignoreAsInteraction` (set it on
    /// programmatic starts whose abandonment is expected rather than an error signal).
    public func subflowStart(data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        tracker.trackSubflowStarted(subflowType, data: data, options: options)
    }

    /// Emits `subflow_finished`.
    public func subflowFinished(data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        tracker.trackSubflowFinished(subflowType, data: data, options: options)
    }

    /// Emits `subflow_error`.
    public func subflowError(data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        tracker.trackSubflowError(subflowType, data: data, options: options)
    }

    /// Define an ad-hoc step not covered by the operation's typed steps.
    public func customStep(_ stepName: String) -> StepHandle {
        StepHandle(tracker: tracker, subflowType: subflowType, stepName: stepName)
    }

    func defineStep(_ stepName: String, ignoreAsInteractionOnStart: Bool = false) -> StepHandle {
        StepHandle(
            tracker: tracker,
            subflowType: subflowType,
            stepName: stepName,
            ignoreAsInteractionOnStart: ignoreAsInteractionOnStart)
    }

    /// Define a field-observation handle with an SDK-fixed semantic field type. Operations expose
    /// these for their observable input fields; operations without fields expose none.
    func defineField(_ fieldType: String) -> FieldObserver {
        tracker.fieldObserver(fieldType)
    }
}
