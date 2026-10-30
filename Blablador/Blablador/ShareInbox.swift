import Foundation

/// Hand-over from the share extension to the app: items wait in the App Group's Inbox folder until the app opens.
/// Compiled into both the app and the extension.
enum ShareInbox {
#if os(macOS)
    static let group = "4Q84Z7RZ3Z.de.fz-juelich.blablador"
#else
    static let group = "group.de.fz-juelich.blablador"
#endif
    /// Opens the app after sharing (on the Mac; iOS extensions can't open apps).
    static let openURL = URL(string: "blablador://inbox")!

    struct Item: Codable {
        var text: String
        var files: [String]
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Saves shared text and files (extension side).
    static func put(text: String, files: [(name: String, data: Data)]) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let item = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        var names: [String] = []
        for file in files {
            var name = file.name.replacingOccurrences(of: "/", with: "_")
            if names.contains(name) { name = "\(names.count + 1) \(name)" }
            try file.data.write(to: item.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            names.append(name)
        }
        let info = try JSONEncoder().encode(Item(text: text, files: names))
        try info.write(to: item.appendingPathComponent("item.json"), options: [.atomic, .completeFileProtection])
    }

    /// Takes everything waiting (app side): the files are moved to a temporary folder and the inbox emptied.
    static func take() -> [(text: String, files: [URL])] {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        var result: [(String, [URL])] = []
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        for item in sorted {
            defer { try? FileManager.default.removeItem(at: item) }
            guard let data = try? Data(contentsOf: item.appendingPathComponent("item.json")),
                  let info = try? JSONDecoder().decode(Item.self, from: data) else { continue }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Shared-" + item.lastPathComponent, isDirectory: true)
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let files = info.files.compactMap { name -> URL? in
                let target = temporary.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                return (try? FileManager.default.moveItem(at: item.appendingPathComponent(name), to: target)) != nil ? target : nil
            }
            result.append((info.text, files))
        }
        return result
    }
}
