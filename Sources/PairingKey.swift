import Foundation
import Security

// The secret your Macs share before they forward input to each other. Kept in the login keychain.
enum PairingKey {
    // Only Tests/PairingKeyChecks.swift changes this, to use a disposable service.
    static var service = "uc-steer"
    static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "pairing key"]
    }

    static func read() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns errSecSuccess when the keychain now holds `key` (or nothing, for nil). Existing item is kept on failure.
    static func save(_ key: String?) -> OSStatus {
        guard let key else {
            let status = SecItemDelete(item as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(item.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
    }

    // 4 groups of 5 characters from an alphabet without look-alikes: 100 random bits.
    static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (0..<4).map { _ in String((0..<5).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }
}
