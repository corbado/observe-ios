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

    /// Cached SDK reliability config JSON (raw response body), applied as boot snapshot next start.
    var sdkConfigJson: String? {
        get { defaults.string(forKey: Self.keySdkConfig) }
        set { defaults.set(newValue, forKey: Self.keySdkConfig) }
    }

    func updateSession(id: String, lastActivityAt: Int64) {
        defaults.set(id, forKey: Self.keySessionId)
        defaults.set(Double(lastActivityAt), forKey: Self.keySessionLastActivity)
    }

    private static let keySessionId = "cbo_session"
    private static let keySessionLastActivity = "cbo_session_activity"
    private static let keyClientEnvHandle = "cbo_client_env_handle"
    private static let keyClientEnvHandleTs = "cbo_client_env_handle_ts"
    private static let keySdkConfig = "cbo_sdk_config"
}
