import Foundation
import Security
import CryptoKit

/// 启动密码锁：密码哈希（加盐 SHA-256）保存在本机钥匙串，不随项目文件外泄。
enum AppLock {
    private static let service = "com.monsterisdrinkingwater.studentdb.applock"
    private static let account = "password"
    private static let saltLength = 16

    // MARK: - 状态

    static var isEnabled: Bool {
        readPair() != nil
    }

    // MARK: - 操作

    static func enable(password: String) {
        let salt = randomSalt()
        let digest = hash(password: password, salt: salt)
        savePair("\(salt)$\(digest)")
    }

    static func disable() {
        deletePair()
    }

    static func verify(password: String) -> Bool {
        guard let pair = readPair() else { return false }
        let parts = pair.split(separator: "$", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let salt = String(parts[0])
        let expected = String(parts[1])
        let digest = hash(password: password, salt: salt)
        // 恒定时间比较
        guard digest.utf8.count == expected.utf8.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(digest.utf8, expected.utf8) { result |= a ^ b }
        return result == 0
    }

    // MARK: - 内部

    private static func hash(password: String, salt: String) -> String {
        let input = Data("\(salt):\(password)".utf8)
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 钥匙串

    private static func savePair(_ value: String) {
        deletePair()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func readPair() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deletePair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
