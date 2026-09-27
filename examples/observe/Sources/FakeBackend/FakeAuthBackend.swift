import Foundation

/// The "backend" of the example app: no server, no network. Accounts live in UserDefaults so
/// they survive restarts, latency is simulated, and outcomes are controlled by magic values:
///
/// - identifier starting `locked` → `.accountLocked`
/// - identifier starting `slow`   → 3s latency before the normal outcome
/// - unknown identifier           → `.userNotFound`
/// - any non-matching password    → `.invalidPassword`
@MainActor
final class FakeAuthBackend {
    enum Result {
        case success(userId: String)
        case invalidPassword
        case userNotFound
        case accountLocked

        var code: String {
            switch self {
            case .success: "success"
            case .invalidPassword: "invalid_password"
            case .userNotFound: "user_not_found"
            case .accountLocked: "account_locked"
            }
        }
    }

    private let key = "fake_auth_backend"
    private var store: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func accounts() -> [String] { store.keys.sorted() }

    /// Stable fake user id for an identifier (what a successful login returns).
    func userIdFor(_ identifier: String) -> String {
        "usr-\(UInt32(truncatingIfNeeded: identifier.hashValue))"
    }

    func createAccount(identifier: String, password: String) {
        store[identifier] = password
    }

    func deleteAllAccounts() {
        store = [:]
    }

    /// Pre-identifier submission check ("does this identifier exist?"), mirroring native2's
    /// server-side identifier check. Same magic values as `passwordLogin`.
    func identifierCheck(_ identifier: String) async -> Result {
        await latency(identifier)
        if identifier.hasPrefix("locked") { return .accountLocked }
        guard store[identifier] != nil else { return .userNotFound }
        return .success(userId: userIdFor(identifier))
    }

    func passwordLogin(identifier: String, password: String) async -> Result {
        await latency(identifier)
        if identifier.hasPrefix("locked") { return .accountLocked }
        guard let stored = store[identifier] else { return .userNotFound }
        if password != stored { return .invalidPassword }
        return .success(userId: userIdFor(identifier))
    }

    private func latency(_ identifier: String) async {
        try? await Task.sleep(for: .milliseconds(identifier.hasPrefix("slow") ? 3000 : 600))
    }
}

/// Simulated server-side rejection (e.g. passkey assertion verification failed). Name and message
/// travel as the raw error on `subflow_step_error`.
struct BackendError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
