/// Untyped operation for subflow types without a dedicated operation class yet. Emits the same
/// wire events (`subflowStart`/`subflowFinished`/`subflowError` plus `customStep` handles). The
/// caller is responsible for using step names the backend classifier knows.
public final class GenericOperation: OperationFull, @unchecked Sendable {
    override init(tracker: ObserveTracker, subflowType: SubflowType) {
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Step handle whose `start` carries `ignoreAsInteraction` (programmatic, non-user steps).
    public func customStepIgnoredAsInteraction(_ stepName: String) -> StepHandle {
        defineStep(stepName, ignoreAsInteractionOnStart: true)
    }

    /// Untyped field-observation handle. `fieldType` must use the subflow-type vocabulary.
    public func field(_ fieldType: String) -> FieldObserver {
        defineField(fieldType)
    }
}
