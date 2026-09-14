import Foundation

/// Options for `CorbadoObserve.initialize`.
public struct ObserveOptions: Sendable {
    /// Corbado project id (`pro-...`). Required.
    public var projectId: String
    /// Base URL of the ingest API — `https://api.cloud.corbado.io`, or your own proxy. Must
    /// include the scheme and carry no trailing slash. Required.
    public var apiBaseUrl: String
    /// Terminal path of the events endpoint. Override only when a proxy mounts ingestion under a
    /// custom path; the project id is always appended.
    public var apiEventPath: String
    /// Config endpoint path on the same API base/proxy; the project id is appended.
    public var apiConfigPath: String
    /// Optional per-field reliability policy overrides.
    public var sdkConfig: SdkConfigOverrides?
    /// Verbose logging (silent warnings/errors otherwise).
    public var debug: Bool
    /// Tags automatically attached to every event.
    public var defaultTags: [String: String]
    /// Optional identifier when several apps report into one project.
    public var applicationId: String?
    /// Flush pending events when the app leaves the foreground (the last reliable delivery
    /// moment). Host apps that want full control can disable this and call
    /// `ObserveTracker.flush` themselves; the server config can also switch it off remotely.
    public var flushOnBackground: Bool

    public init(
        projectId: String,
        apiBaseUrl: String,
        apiEventPath: String = "/v1/observe/events",
        debug: Bool = false,
        defaultTags: [String: String] = [:],
        applicationId: String? = nil,
        flushOnBackground: Bool = true,
        apiConfigPath: String = "/v1/observe/config",
        sdkConfig: SdkConfigOverrides? = nil
    ) {
        self.projectId = projectId
        self.apiBaseUrl = apiBaseUrl
        self.apiEventPath = apiEventPath
        self.apiConfigPath = apiConfigPath
        self.sdkConfig = sdkConfig
        self.debug = debug
        self.defaultTags = defaultTags
        self.applicationId = applicationId
        self.flushOnBackground = flushOnBackground
    }
}

/// Reference to the (possibly not yet known) user an event belongs to.
public struct UserReference: Sendable {
    public var userId: String?
    public var identifier: String?
    public var crossEnvironmentTransactionID: String?

    public init(userId: String? = nil, identifier: String? = nil, crossEnvironmentTransactionID: String? = nil) {
        self.userId = userId
        self.identifier = identifier
        self.crossEnvironmentTransactionID = crossEnvironmentTransactionID
    }
}

/// Per-call options accepted by all tracking methods.
public struct StepOptions: Sendable {
    public var userReference: UserReference?
    /// Override the capture timestamp (unix ms); defaults to now.
    public var explicitTimestamp: Int64?

    public init(userReference: UserReference? = nil, explicitTimestamp: Int64? = nil) {
        self.userReference = userReference
        self.explicitTimestamp = explicitTimestamp
    }
}

/// Serializable error shape used in error event payloads (the sibling of the web SDK's
/// `normalizeError`).
public struct NormalizedError: Sendable {
    public var name: String?
    public var code: String?
    public var message: String?

    public init(name: String? = nil, code: String? = nil, message: String? = nil) {
        self.name = name
        self.code = code
        self.message = message
    }

    public static func from(_ error: any Error) -> NormalizedError {
        let nsError = error as NSError
        return NormalizedError(
            name: String(describing: type(of: error)),
            code: "\(nsError.domain):\(nsError.code)",
            message: String(error.localizedDescription.prefix(maxMessageLength))
        )
    }

    private static let maxMessageLength = 500
}

extension ObserveOptions {
    /// Event endpoint; nil for anything but a parseable http(s) base URL (checked at `initialize`).
    var eventsURL: URL? {
        guard let url = URL(string: "\(apiBaseUrl)\(apiEventPath)/\(projectId)"),
            let scheme = url.scheme, scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}

extension ObserveOptions {
    var configURL: URL? {
        guard var components = URLComponents(string: "\(apiBaseUrl)\(apiConfigPath)/\(projectId)"),
            let scheme = components.scheme, scheme == "http" || scheme == "https", components.host != nil
        else { return nil }
        components.queryItems = [URLQueryItem(name: "sdkName", value: Sdk.name)]
        return components.url
    }
}
