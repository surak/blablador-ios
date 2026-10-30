import Foundation
import CryptoKit
import Security

enum KeychainHelper {
    private static let service = "de.fz-juelich.blablador"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// App files encrypted with AES-GCM; the key is kept in the Keychain. Used for chat history and memories.
enum EncryptedStorage {
    private static let keyAccount = "storageKey"

    /// Reads and decrypts a file. Files saved by older versions in plain JSON are read as they are and rewritten
    /// encrypted. A file that can't be decrypted is moved aside (".unreadable") rather than overwritten.
    static func read(_ url: URL) -> Data? {
        guard let stored = try? Data(contentsOf: url) else { return nil }
        if let key = key(create: false), let box = try? AES.GCM.SealedBox(combined: stored),
           let data = try? AES.GCM.open(box, using: key) {
            return data
        }
        if stored.first == UInt8(ascii: "[") || stored.first == UInt8(ascii: "{"),
           (try? JSONSerialization.jsonObject(with: stored)) != nil {
            write(stored, to: url)
            return stored
        }
        guard keychainAvailable else { return nil }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
        return nil
    }

    /// Encrypts and saves; nothing is written in plain text when the Keychain is unavailable.
    static func write(_ data: Data, to url: URL) {
        guard let key = key(create: true), let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// False when the Keychain can't be read right now (as opposed to having no key yet).
    private static var keychainAvailable: Bool {
        let status = SecItemCopyMatching(query(returnData: false) as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func key(create: Bool) -> SymmetricKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        // Only make a new key when there is none; any other error keeps the existing files readable later.
        guard create, status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        var attributes = query(returnData: false)
        attributes.removeValue(forKey: kSecMatchLimit as String)
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Not "ThisDeviceOnly": the key moves with encrypted backups, so restored history stays readable.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess ? key : nil
    }

    private static func query(returnData: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "de.fz-juelich.blablador",
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: returnData,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }
}
