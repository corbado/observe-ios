import Foundation

/// Social-login subflow operation. The step names map directly onto native equivalents:
/// `getRedirectUrl` is the preparation of the provider handoff (`ASWebAuthenticationSession`
/// URL, or a provider SDK call including Sign in with Apple), `exchangeCode` is redeeming the
/// provider's result with the host backend. An Apple/Google credential picked from a
/// multi-option system chooser stays with `SystemCredentialOperation`; this operation is for the
/// dedicated provider button flow.
public final class SocialLoginOperation: OperationFull, @unchecked Sendable {
    /// Where in the flow the social button lives (wire values).
    public enum SpecType: String, Sendable {
        case preIdentifier = "pre-identifier"
        case postIdentifier = "post-identifier"
    }

    /// Social providers (wire values).
    public enum Provider: String, Sendable {
        case google
        case apple
        case facebook
        case github
        case microsoft
        case other
    }

    private let providerBox = Locked<Provider?>(nil)

    /// Preparing the provider handoff (auth session URL / provider SDK call). Start data carries
    /// the provider.
    public let getRedirectUrl: StepHandle

    /// Redeeming the provider result with the host backend. Start data carries the provider.
    public let exchangeCode: StepHandle

    init(tracker: ObserveTracker) {
        let subflowType = SubflowType.socialLogin
        getRedirectUrl = StepHandle(
            tracker: tracker, subflowType: subflowType, stepName: "get-redirect-url")
        exchangeCode = StepHandle(tracker: tracker, subflowType: subflowType, stepName: "exchange-code")
        super.init(tracker: tracker, subflowType: subflowType)
    }

    /// Emits `subflow_started` and remembers `provider` so `startWithProvider` can carry it
    /// (the provider rides on the step-start payloads).
    public func start(
        specType: SpecType? = nil,
        provider: Provider? = nil,
        actor: String = "user",
        options: StepOptions? = nil
    ) {
        providerBox.value = provider
        var data: [String: JSONValue] = ["actor": .string(actor)]
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        data.putIfPresent("provider", provider?.rawValue)
        subflowStart(data: data, options: options)
    }

    /// `StepHandle.start` carrying the provider from `start` (plus `specType` on
    /// get-redirect-url).
    public func startWithProvider(
        _ step: StepHandle, specType: SpecType? = nil, options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = [:]
        data.putIfPresent("provider", providerBox.value?.rawValue)
        data.putIfPresent("explicitSpecType", specType?.rawValue)
        step.start(data: data, options: options)
    }
}
