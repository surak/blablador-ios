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

/// App files encrypted with AES-GCM; the key is kept in the Keychain. Used for chats, memories, images, audio,
/// videos, voice samples, knowledge bases and custom instructions.
enum EncryptedStorage {
    private static let keyAccount = "storageKey"
    /// Keychain service of the key; tests use their own.
    nonisolated(unsafe) static var keychainService = "de.fz-juelich.blablador"

    /// Reads and decrypts a JSON file. Files saved by older versions in plain JSON are read as they are and
    /// rewritten encrypted. A file that can't be decrypted is moved aside (".unreadable") rather than overwritten.
    static func read(_ url: URL) -> Data? {
        if let data = readFile(url, isPlain: isJSON) { return data }
        if FileManager.default.fileExists(atPath: url.path), keychainAvailable {
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
        }
        return nil
    }

    /// Reads and decrypts any file; `isPlain` recognises unencrypted files from older versions, which are converted.
    static func readFile(_ url: URL, isPlain: (Data) -> Bool) -> Data? {
        guard let stored = try? Data(contentsOf: url) else { return nil }
        if let key = key(create: false), let box = try? AES.GCM.SealedBox(combined: stored),
           let data = try? AES.GCM.open(box, using: key) {
            return data
        }
        guard keychainAvailable, isPlain(stored) else { return nil }
        write(stored, to: url)
        return stored
    }

    /// Encrypts and saves; nothing is written in plain text when the Keychain is unavailable.
    static func write(_ data: Data, to url: URL) {
        guard let key = key(create: true), let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func isJSON(_ data: Data) -> Bool {
        (data.first == UInt8(ascii: "[") || data.first == UInt8(ascii: "{")) && (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Recognises unencrypted JPEG, PNG, MP3 and MP4/M4A files.
    static func isMedia(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return false }
        return bytes.starts(with: [0xFF, 0xD8]) || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || bytes.starts(with: Array("ID3".utf8)) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
            || Array(bytes[4..<8]) == Array("ftyp".utf8)
    }

    /// Encrypts files saved unencrypted by versions before 3.0: media in Images, Audio, Videos and Voices, and
    /// each knowledge base's chunks and vectors.
    static func encryptOldFiles() {
        let support = AppFolder.url
        let files = { (folder: URL) in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }
        for folder in ["Images", "Audio", "Videos", "Voices"] {
            for file in files(support.appendingPathComponent(folder)) {
                guard let data = try? Data(contentsOf: file), isMedia(data) else { continue }
                write(data, to: file)
            }
        }
        for index in ["Knowledge/bases.json", "Voices/voices.json"] {
            _ = read(support.appendingPathComponent(index))
        }
        for base in files(support.appendingPathComponent("Knowledge")) {
            let chunks = base.appendingPathComponent("chunks.json")
            guard let data = try? Data(contentsOf: chunks), isJSON(data) else { continue }
            let vectors = base.appendingPathComponent("vectors.bin")
            if let floats = try? Data(contentsOf: vectors) { write(floats, to: vectors) }
            write(data, to: chunks)
        }
    }

    // MARK: - Decrypted copies

    /// Players, share sheets and exporters need a real file: a decrypted copy in a temporary folder,
    /// removed when the app starts and when the original is deleted.
    static func decryptedCopy(of url: URL) -> URL {
        let copy = decryptedDirectory.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: copy.path), let data = readFile(url, isPlain: isMedia) {
            try? data.write(to: copy, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return copy
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: decryptedDirectory.appendingPathComponent(url.lastPathComponent))
    }

    static func removeDecryptedCopies() {
        try? FileManager.default.removeItem(at: decryptedDirectory)
    }

    private static var decryptedDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Decrypted", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: returnData,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }
}

/// Where the app keeps its files. On iOS that is the app's own Application Support folder; the Mac app isn't
/// sandboxed, so it uses a folder of its own inside ~/Library/Application Support (before 3.0 its files sat in
/// that shared folder itself, next to other apps' and macOS's folders, and are moved once).
enum AppFolder {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#if os(macOS)
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "de.fz-juelich.blablador", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        moveOldFiles(from: support, to: folder)
        return folder
#else
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
#endif
    }()

#if os(macOS)
    private static func moveOldFiles(from support: URL, to folder: URL) {
        let manager = FileManager.default
        for name in ["conversations.json", "memories.json", "decisions.json", "instructions.json", "Images", "Audio", "Videos", "Voices"] {
            let old = support.appendingPathComponent(name), new = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) {
                try? manager.moveItem(at: old, to: new)
            }
        }
        // "Knowledge" there belongs to macOS; only Blablador's index and its per-base folders (UUID names) move.
        let oldKnowledge = support.appendingPathComponent("Knowledge"), newKnowledge = folder.appendingPathComponent("Knowledge")
        guard !manager.fileExists(atPath: newKnowledge.path),
              let items = try? manager.contentsOfDirectory(atPath: oldKnowledge.path),
              items.contains("bases.json") else { return }
        try? manager.createDirectory(at: newKnowledge, withIntermediateDirectories: true)
        for item in items where item == "bases.json" || UUID(uuidString: item) != nil {
            try? manager.moveItem(at: oldKnowledge.appendingPathComponent(item), to: newKnowledge.appendingPathComponent(item))
        }
    }
#endif
}
