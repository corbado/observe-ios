import CorbadoObserve
import Foundation

/// Devbar environment: which ingest endpoint/project the SDK talks to, the passkey rpId, the
/// auto-start-flow toggle and the last screen. Persisted so choices survive restarts; applying an
/// endpoint change re-initializes the SDK (destroy → init).
enum ObserveEnv {
    struct Endpoint: Hashable {
        let label: String
        let apiBaseUrl: String
        let projectId: String
    }

    /// Local backend (reachable from the iOS simulator), Cloud Staging and Cloud Prod, each with
    /// its Observe project.
    static let presets = [
        Endpoint(label: "Local (simulator)", apiBaseUrl: "http://127.0.0.1:15960", projectId: "pro-30"),
        Endpoint(
            label: "Cloud Staging",
            apiBaseUrl: "https://api.cloud.corbado-staging.io",
            projectId: "pro-4878977077203178919"),
        Endpoint(
            label: "Cloud Prod",
            apiBaseUrl: "https://api.cloud.corbado.io",
            projectId: "pro-9412238872233540874"),
    ]

    private static var defaults: UserDefaults { .standard }

    static var apiBaseUrl: String {
        get { defaults.string(forKey: "observe_env_apiBaseUrl") ?? presets[0].apiBaseUrl }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "observe_env_apiBaseUrl") }
    }

    static var projectId: String {
        get { defaults.string(forKey: "observe_env_projectId") ?? presets[0].projectId }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "observe_env_projectId") }
    }

    /// Relying-party id for passkey ceremonies. The default domain's association file lists this
    /// app. Empty = passkey requests are omitted (password/AutoFill-only experiments).
    static var rpId: String {
        get { defaults.string(forKey: "observe_env_rpId") ?? "corbado-demo.com" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "observe_env_rpId") }
    }

    static var autoStartFlow: Bool {
        get { defaults.object(forKey: "observe_env_autoStartFlow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "observe_env_autoStartFlow") }
    }

    /// Route completed logins of passkey-less accounts into the post-login enrollment offer
    /// (native2's server decision, emulated). Default OFF so other experiments stay untouched.
    static var offerEnrollment: Bool {
        get { defaults.bool(forKey: "observe_env_offerEnrollment") }
        set { defaults.set(newValue, forKey: "observe_env_offerEnrollment") }
    }

    static var currentScreenId: String? {
        get { defaults.string(forKey: "observe_env_screenId") }
        set { defaults.set(newValue, forKey: "observe_env_screenId") }
    }

    @discardableResult
    static func initTracker() -> ObserveTracker? {
        CorbadoObserve.initialize(
            options: ObserveOptions(
                projectId: projectId,
                apiBaseUrl: apiBaseUrl,
                debug: true,
                applicationId: "observe-example-ios"))
    }

    /// Persist a new environment and re-initialize the SDK against it.
    @discardableResult
    static func apply(apiBaseUrl: String, projectId: String) -> ObserveTracker? {
        self.apiBaseUrl = apiBaseUrl.hasSuffix("/") ? String(apiBaseUrl.dropLast()) : apiBaseUrl
        self.projectId = projectId
        CorbadoObserve.destroy()
        return initTracker()
    }
}
