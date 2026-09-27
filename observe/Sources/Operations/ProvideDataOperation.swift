/// Provide-data subflow operation: a user-triggered data submission that is not an identifier or
/// credential (signup form fields, profile data, consent).
public final class ProvideDataOperation: OperationFull, @unchecked Sendable {
    /// Which flow the data collection belongs to (wire values).
    public enum SpecType: String, Sendable {
        case signup
        case login
        case recovery
        case enrollment
    }

    /// Observation handle for the data input field.
    public let dataField: FieldObserver

    /// Client-side validation of the form.
    public let clientValidation: StepHandle

    /// The data submission to the host backend and its outcome.
    public let postResponse: StepHandle

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.provideData
        dataField = tracker.fieldObserver("provide-data")
        clientValidation = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "client-validation")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "post-response")
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started`.
    ///
    /// - Parameter fieldName: Stable name of the data field collected by this subflow, when known.
    public func start(
        specType: SpecType? = nil,
        fieldName: String? = nil,
        actor: String = "user",
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        data.putIfPresent("fieldName", fieldName)
        subflowStart(data: data, options: options)
    }
}
