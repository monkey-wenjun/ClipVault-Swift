import Foundation
import Security

/// Keychain 封装，用于安全存储图床凭证等敏感信息。
/// 沙盒内应用仍可通过 kSecAttrService / kSecAttrAccount 访问自己的 Keychain 项。
enum KeychainService {
    private static let service = "com.awen.ClipVault.credentials"

    enum CredentialField: String, CaseIterable {
        case accessKey
        case secretKey
    }

    static func saveCredential(configID: UUID, field: CredentialField, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let account = accountString(configID: configID, field: field)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return updateCredential(configID: configID, field: field, value: value)
        }
        return status == errSecSuccess
    }

    static func loadCredential(configID: UUID, field: CredentialField) -> String? {
        let account = accountString(configID: configID, field: field)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func deleteCredential(configID: UUID, field: CredentialField) -> Bool {
        let account = accountString(configID: configID, field: field)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func deleteCredentials(for configID: UUID) {
        CredentialField.allCases.forEach { _ = deleteCredential(configID: configID, field: $0) }
    }

    private static func updateCredential(configID: UUID, field: CredentialField, value: String) -> Bool {
        let account = accountString(configID: configID, field: field)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data = value.data(using: .utf8) else { return false }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        return status == errSecSuccess
    }

    private static func accountString(configID: UUID, field: CredentialField) -> String {
        "\(configID.uuidString).\(field.rawValue)"
    }
}
