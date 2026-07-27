import Foundation
import CryptoKit

/// 图床敏感凭证的加密/解密。
/// 采用 AES-256-GCM，密钥从固定 salt 派生（与 ClipVault 同级：避免明文存储，但不具备硬件级安全）。
enum ImageHostingCrypto {
    private static let prefix = "MPENC:"
    private static let salt = "ClipVaultImageHostingSalt2024".data(using: .utf8)!

    private static var key: SymmetricKey {
        let hash = SHA256.hash(data: salt)
        return SymmetricKey(data: Data(hash))
    }

    static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return "" }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext.data(using: .utf8)!, using: key, nonce: nonce)
            let combined = nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
            return prefix + combined.base64EncodedString()
        } catch {
            return plaintext
        }
    }

    static func decrypt(_ ciphertext: String) -> String {
        guard !ciphertext.isEmpty else { return "" }
        guard ciphertext.hasPrefix(prefix) else { return ciphertext }
        do {
            let data = Data(base64Encoded: String(ciphertext.dropFirst(prefix.count))) ?? Data()
            guard data.count > 12 else { return "" }
            let nonceData = data.prefix(12)
            let tagData = data.suffix(16)
            let cipherData = data.dropFirst(12).dropLast(16)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
            let plain = try AES.GCM.open(sealed, using: key)
            return String(data: plain, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    /// 加密配置中的 accessKey / secretKey（原地修改）。
    static func encryptConfig(_ config: inout ImageHostingConfig) {
        if !isEncrypted(config.accessKey) {
            config.accessKey = encrypt(config.accessKey)
        }
        if !isEncrypted(config.secretKey) {
            config.secretKey = encrypt(config.secretKey)
        }
    }

    /// 解密一份配置的副本（不修改原始配置）。
    static func decryptedCopy(of config: ImageHostingConfig) -> ImageHostingConfig {
        var copy = config
        copy.accessKey = decrypt(copy.accessKey)
        copy.secretKey = decrypt(copy.secretKey)
        return copy
    }
}
