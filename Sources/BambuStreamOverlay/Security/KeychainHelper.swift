import Foundation
import Security

/// Tiny wrapper around the macOS Keychain for the two secrets this app
/// handles (LAN access code, client-certificate password). Everything else
/// (IP, serial, port, visible-field selection) is plain UserDefaults since
/// it isn't sensitive.
///
/// Every call runs with a hard timeout on a background queue instead of
/// calling the Security framework directly on the caller's thread. Verified
/// with lldb during development that `SecItemCopyMatching` can genuinely
/// deadlock inside `securityd`/legacy CSSM keychain code (stuck in
/// `SecurityServer::ClientSession::decrypt`, unrelated to any auth-UI
/// prompt — `kSecUseAuthenticationUISkip` did not help) — this seems tied
/// to ad-hoc signing changing the app's code identity on every rebuild,
/// which can confuse the item's ACL. `AppSettings.init()` reads the saved
/// access code on the main thread before the menu bar, HTTP server, or
/// MQTT connection exist — a hang there took the *entire app* down with
/// it. A timeout is the only way to guarantee that can never happen again:
/// worst case, a read times out and comes back empty (you re-enter that
/// one value), rather than the whole app never launching.
enum KeychainHelper {
    private static let service = "com.bambustreamoverlay.app"
    private static let timeout: TimeInterval = 3
    private static let queue = DispatchQueue(label: "com.bambustreamoverlay.keychain", qos: .userInitiated)

    /// Runs `body` on a background queue and waits up to `timeout` for it.
    /// On timeout, returns `nil` immediately and abandons the still-running
    /// operation (it may never actually finish, but it's isolated to one
    /// queue rather than blocking whoever called this).
    private static func withTimeout<T>(_ body: @escaping () -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        queue.async {
            result = body()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            print("[Keychain] operation timed out after \(Int(timeout))s — continuing without it. If this keeps happening, it's likely the ad-hoc code signature changing on rebuild confusing an existing Keychain item's ACL; deleting and re-saving the value (e.g. re-typing the Access Code once) usually clears it.")
            return nil
        }
        return result
    }

    static func set(_ value: String, account: String) {
        _ = withTimeout { () -> Bool? in
            let data = Data(value.utf8)
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
            return true
        }
    }

    static func get(account: String) -> String? {
        withTimeout { () -> String? in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                if status != errSecItemNotFound {
                    let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                    print("[Keychain] read for account \"\(account)\" failed: OSStatus \(status) (\(message))")
                }
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    static func delete(account: String) {
        _ = withTimeout { () -> Bool? in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            return true
        }
    }
}
