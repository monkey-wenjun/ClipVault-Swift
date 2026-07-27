import Foundation
import CryptoKit
import Security

/// 落盘加密：AES-256-GCM。
/// 密钥自动生成并保存在系统 Keychain，标记 synchronizable（经 iCloud 钥匙串同步），
/// 这样多台 Mac 可以解密彼此的同步文件。
enum CryptoService {
    private static let service = "com.local.ClipVault"
    private static let account = "history-key"

    static func encrypt(_ data: Data) -> Data? {
        guard let key = try? loadOrCreateKey(),
              let box = try? AES.GCM.seal(data, using: key) else { return nil }
        return box.combined // nonce(12) + ciphertext + tag(16)
    }

    static func decrypt(_ data: Data) -> Data? {
        guard let key = try? loadOrCreateKey(),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: - Keychain

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try findKey() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        // 优先 synchronizable（经 iCloud 钥匙串同步，多台 Mac 可解密彼此的同步文件）；
        // 未开启 iCloud 钥匙串时（errSecNoSuchKeychain -34018）退化为本机存储
        for synchronizable in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: synchronizable,
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return key }
            if status == errSecDuplicateItem, let existing = try findKey() {
                return SymmetricKey(data: existing)
            }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecIO))
    }

    private static func findKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result as? Data
    }
}
