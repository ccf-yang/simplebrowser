import Foundation
import Flutter
import Security

/// Encrypted-at-rest storage for `SessionSnapshot` JSON.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to
/// background refreshes after the first unlock, never migrated to another
/// device, never included in iCloud backups.
final class KeychainVault {
    private let service = "com.browser_http.vault"

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let key = args["key"] as? String else {
            result(FlutterError(code: "vault.read", message: "missing key", details: nil))
            return
        }

        switch call.method {
        case "read":
            result(read(key))

        case "write":
            guard let value = args["value"] else {
                result(FlutterError(code: "vault.write", message: "missing value", details: nil))
                return
            }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else {
                result(FlutterError(code: "vault.write", message: "value is not JSON", details: nil))
                return
            }
            result(write(key, data: data))

        case "delete":
            result(delete(key))

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ key: String, data: Data) -> FlutterError? {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            baseQuery(key) as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var query = baseQuery(key)
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                return FlutterError(code: "vault.write",
                                    message: "SecItemAdd failed: \(addStatus)",
                                    details: nil)
            }
            return nil
        }

        guard status == errSecSuccess else {
            return FlutterError(code: "vault.write",
                                message: "SecItemUpdate failed: \(status)",
                                details: nil)
        }
        return nil
    }

    private func delete(_ key: String) -> FlutterError? {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return nil }
        return FlutterError(code: "vault.write",
                            message: "SecItemDelete failed: \(status)",
                            details: nil)
    }
}
