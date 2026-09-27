/// Provide-identifier subflow operation: the user entering their email/phone before an auth
/// method is chosen. Emits `pi-*` steps for the identifier form itself and `cui-*` steps for a
/// credential suggestion surfaced on the identifier field (conditional UI: a QuickType-bar
/// passkey suggestion resolved through `ASAuthorizationController`).
public final class ProvideIdentifierOperation: OperationFull, @unchecked Sendable {
    /// Identifier kinds (wire values).
    public enum SpecType: String, Sendable {
        case email
        case phone
    }

    /// Observation handle for the identifier input field.
    public let identifierField: FieldObserver

    /// Client-side validation of the identifier (format checks before any request).
    public let clientValidation: StepHandle

    /// The identifier submission to the host backend and its outcome.
    public let postResponse: StepHandle

    /// Hosted conditional-UI steps: a credential offered on the identifier field classifies into
    /// this subflow. The options fetch is preparatory, never interaction, so its start rides
    /// `ignoreAsInteraction`.
    public let cui: ConditionalUISteps

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.provideIdentifier
        identifierField = tracker.fieldObserver("provide-identifier")
        clientValidation = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "pi-client-validation")
        postResponse = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "pi-post-response")
        cui = ConditionalUISteps(tracker: tracker, subflowType: subflowType)
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started` for this identifier form.
    ///
    /// - Parameter actor: Who initiated the subflow (`"user"` or `"system"` for auto-shown forms).
    /// - Parameter ignoreAsInteraction: the form rendered with the screen (actor `"system"`), no
    ///   user gesture behind it.
    public func start(
        specType: SpecType? = nil, actor: String = "user", ignoreAsInteraction: Bool = false,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        if ignoreAsInteraction { data["ignoreAsInteraction"] = .bool(true) }
        subflowStart(data: data, options: options)
    }
}
