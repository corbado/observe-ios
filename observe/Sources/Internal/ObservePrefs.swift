import Foundation

/// UserDefaults wrapper for the SDK's persistent state (own suite so host-app defaults stay
/// untouched). Storage keys use the `cbo_` prefix. Deliberately not the Keychain: state dies
/// with the app install, so a reinstall is a fresh client environment.
///
/// The suite is resolved lazily on first access (SDK actor): `UserDefaults(suiteName:)` is a
/// synchronous cfprefsd round-trip, and construction happens on the caller's thread during init,
/// which must stay free of I/O (main-safety). All access is on the SDK's internal actor.
final class ObservePrefs {
    private let suiteName: String
    private lazy var defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    init(suiteName: String = "corbado_observe") {
        self.suiteName = suiteName
    }

    var sessionId: String? {
        get { defaults.string(forKey: Self.keySessionId) }
        set { defaults.set(newValue, forKey: Self.keySessionId) }
    }

    var sessionLastActivityAt: Int64 {
        get { Int64(defaults.double(forKey: Self.keySessionLastActivity)) }
        set { defaults.set(Double(newValue), forKey: Self.keySessionLastActivity) }
    }

    var clientEnvHandle: String? {
        get { defaults.string(forKey: Self.keyClientEnvHandle) }
        set { defaults.set(newValue, forKey: Self.keyClientEnvHandle) }
    }

    var clientEnvHandleCreatedAt: Int64 {
        get { Int64(defaults.double(forKey: Self.keyClientEnvHandleTs)) }
        set { defaults.set(Double(newValue), forKey: Self.keyClientEnvHandleTs) }
    }

    /// Last-known remote policy with its endpoint and freshness, written as one record so policy
    /// and times always change together.
    var sdkConfigCache: CachedSdkConfig? {
        get {
            guard let stored = defaults.dictionary(forKey: Self.keySdkConfigCache),
                let endpoint = stored["endpoint"] as? String,
                let fetchedAt = (stored["fetchedAt"] as? NSNumber)?.int64Value,
                let expiresAt = (stored["expiresAt"] as? NSNumber)?.int64Value,
                let body = stored["config"] as? String
            else { return nil }
            return CachedSdkConfig(
                endpoint: endpoint, freshness: ConfigFreshness(fetchedAt: fetchedAt, expiresAt: expiresAt), body: body)
        }
        set {
            defaults.set(
                newValue.map {
                    [
                        "endpoint": $0.endpoint, "fetchedAt": $0.freshness.fetchedAt,
                        "expiresAt": $0.freshness.expiresAt, "config": $0.body,
                    ] as [String: Any]
                },
                forKey: Self.keySdkConfigCache)
        }
    }

    /// Policy JSON cached by SDK versions before `sdkConfigCache`.
    var legacySdkConfigJson: String? { defaults.string(forKey: Self.keyLegacySdkConfig) }

    func removeLegacySdkConfig() { defaults.removeObject(forKey: Self.keyLegacySdkConfig) }

    /// Keyed by project: codes select policies of one project and mean nothing in another.
    func dataPolicy(projectId: String) -> Int? {
        defaults.object(forKey: Self.keyDataPolicy + projectId) as? Int
    }

    func setDataPolicy(_ code: Int, projectId: String) {
        defaults.set(code, forKey: Self.keyDataPolicy + projectId)
    }

    func updateSession(id: String, lastActivityAt: Int64) {
        defaults.set(id, forKey: Self.keySessionId)
        defaults.set(Double(lastActivityAt), forKey: Self.keySessionLastActivity)
    }

    private static let keySessionId = "cbo_session"
    private static let keySessionLastActivity = "cbo_session_activity"
    private static let keyClientEnvHandle = "cbo_client_env_handle"
    private static let keyClientEnvHandleTs = "cbo_client_env_handle_ts"
    private static let keyLegacySdkConfig = "cbo_sdk_config"
    private static let keySdkConfigCache = "cbo_sdk_config_cache"
    private static let keyDataPolicy = "cbo_data_policy_"
}

struct CachedSdkConfig: Equatable {
    var endpoint: String
    var freshness: ConfigFreshness
    /// Raw server body.
    var body: String
}
