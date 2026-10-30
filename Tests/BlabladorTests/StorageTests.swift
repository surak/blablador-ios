import XCTest
@testable import BlabladorCore

/// Encrypted storage, with a Keychain entry of its own so the app's key is never touched.
final class StorageTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        EncryptedStorage.keychainService = "de.fz-juelich.blablador.tests"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "de.fz-juelich.blablador.tests"] as CFDictionary)
    }

    func testRoundTripIsEncryptedOnDisk() throws {
        let file = folder.appendingPathComponent("chat.json")
        let secret = Data(#"[{"text":"my secret project"}]"#.utf8)
        EncryptedStorage.write(secret, to: file)
        let stored = try Data(contentsOf: file)
        XCTAssertNotEqual(stored, secret)
        XCTAssertNil(String(data: stored, encoding: .utf8)?.range(of: "secret"))
        XCTAssertEqual(EncryptedStorage.read(file), secret)
    }

    func testPlainJSONFromOlderVersionsIsReadAndConverted() throws {
        let file = folder.appendingPathComponent("old.json")
        let plain = Data(#"{"a":1}"#.utf8)
        try plain.write(to: file)
        XCTAssertEqual(EncryptedStorage.read(file), plain)
        XCTAssertNotEqual(try Data(contentsOf: file), plain, "should be rewritten encrypted")
        XCTAssertEqual(EncryptedStorage.read(file), plain)
    }

    func testUnreadableFileIsMovedAsideNotOverwritten() throws {
        let file = folder.appendingPathComponent("broken.json")
        try Data([1, 2, 3, 4, 5]).write(to: file)
        XCTAssertNil(EncryptedStorage.read(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".unreadable"))
    }

    func testMediaDetectionAndDecryptedCopy() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let mp4 = Data([0, 0, 0, 0x18] + Array("ftypmp42".utf8))
        XCTAssertTrue(EncryptedStorage.isMedia(png))
        XCTAssertTrue(EncryptedStorage.isMedia(mp4))
        XCTAssertFalse(EncryptedStorage.isMedia(Data("hello world!".utf8)))

        let file = folder.appendingPathComponent("picture.png")
        EncryptedStorage.write(png, to: file)
        let copy = EncryptedStorage.decryptedCopy(of: file)
        XCTAssertEqual(try Data(contentsOf: copy), png)
        EncryptedStorage.delete(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
}

final class DataFileTests: XCTestCase {
    override func setUp() { EncryptedStorage.keychainService = "de.fz-juelich.blablador.tests" }

    func testCSVIsStoredEncryptedAndDescribed() throws {
        let csv = "year,nodes\n2025,10\n2026,40\n"
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("quota.csv")
        try csv.write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let document = try DataFiles.attach(source)
        defer { DataFiles.delete([document.dataFile!]) }
        XCTAssertEqual(document.name, "quota.csv")
        XCTAssertTrue(document.text.contains("/data/quota.csv"))
        XCTAssertTrue(document.text.contains("year,nodes"))
        XCTAssertEqual(DataFiles.data(for: document.dataFile!), Data(csv.utf8))
        XCTAssertTrue(DataFiles.supports(URL(fileURLWithPath: "/x/Book.XLSX")))
        XCTAssertFalse(DataFiles.supports(URL(fileURLWithPath: "/x/app.exe")))
    }
}
