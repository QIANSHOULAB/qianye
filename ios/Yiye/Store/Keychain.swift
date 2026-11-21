import Foundation
import Security

/// 钥匙串：信箱的配对（信箱号 + 钥匙）存这里，不进 UserDefaults、不进镜像文件夹。只在这台手机上，解锁过一次就能读。
enum Keychain {
    static let service = "lab.qianshou.yiye.butler"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, _ account: String) -> Bool {
        let q = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecSuccess { return true }
        var add = q
        for (k, v) in attrs { add[k] = v }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
