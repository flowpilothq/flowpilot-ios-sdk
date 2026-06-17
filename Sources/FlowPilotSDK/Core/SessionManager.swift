import Foundation
import Security

/// Manages user and session identifiers
final class SessionManager: @unchecked Sendable {
    static let shared = SessionManager()

    private let userIdKey = "io.flowpilot.user_id"
    private let sessionIdKey = "io.flowpilot.session_id"
    private let appVersionKey = "io.flowpilot.app_version"

    private var cachedSessionId: String?
    private let queue = DispatchQueue(label: "io.flowpilot.session")

    private init() {
        // Check if app version changed and clear cache if needed
        checkAppVersionChange()
    }

    /// Persistent user ID (stored in Keychain)
    var userId: String {
        queue.sync {
            if let stored = getFromKeychain(key: userIdKey) {
                return stored
            }
            let newId = UUID().uuidString
            saveToKeychain(key: userIdKey, value: newId)
            return newId
        }
    }

    /// Session ID (new per app launch)
    var sessionId: String {
        queue.sync {
            if let cached = cachedSessionId {
                return cached
            }
            let newId = UUID().uuidString
            cachedSessionId = newId
            return newId
        }
    }

    /// Set a custom user ID
    func setUserId(_ userId: String) {
        queue.sync {
            saveToKeychain(key: userIdKey, value: userId)
        }
    }

    /// Reset session ID (e.g., on logout)
    func resetSession() {
        queue.sync {
            cachedSessionId = UUID().uuidString
        }
    }

    /// Clear all stored identifiers
    func clearAll() {
        queue.sync {
            deleteFromKeychain(key: userIdKey)
            cachedSessionId = nil
        }
    }

    // MARK: - App Version Change Detection

    private func checkAppVersionChange() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let storedVersion = UserDefaults.standard.string(forKey: appVersionKey)

        if storedVersion != currentVersion {
            // App was updated, clear caches
            UserDefaults.standard.set(currentVersion, forKey: appVersionKey)
            Logger.shared.info("App version changed from \(storedVersion ?? "nil") to \(currentVersion)")
        }
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.shared.warn("Failed to save to keychain: \(status)")
            // Fallback to UserDefaults
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func getFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }

        // Fallback to UserDefaults
        return UserDefaults.standard.string(forKey: key)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
