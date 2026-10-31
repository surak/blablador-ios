import Foundation

/// Google Docs, Sheets and Slides without any Google sign-in: documents shared as "anyone with the link" are read
/// through Google's export links, and on the Mac the Google Drive for desktop folder is searched, read and written
/// like any folder. Native Google files can't be changed in place; results go back by pasting or as new files.
enum GoogleDocs {
    enum Kind: String { case document, spreadsheets, presentation }

    struct Link: Equatable {
        let kind: Kind
        let id: String
        /// The sheet (tab) of a spreadsheet link, from "#gid=…".
        var gid: String?
    }

    enum GoogleError: LocalizedError {
        case notShared
        var errorDescription: String? {
            "This Google file isn't shared as “anyone with the link”, so it can't be read without signing in to Google. Ask the user to share it by link, or to download it (File → Download → Word, PDF or CSV) and attach it."
        }
    }

    /// The Google file a link points to, or nil for other links.
    static func link(_ url: URL) -> Link? {
        guard url.host()?.lowercased() == "docs.google.com" else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { Kind(rawValue: $0) != nil }), let kind = Kind(rawValue: parts[index]),
              index + 2 < parts.count, parts[index + 1] == "d" else { return nil }
        let id = parts[index + 2]
        guard id.count >= 20, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let gid = (url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)?
            .split(separator: "&").first { $0.hasPrefix("gid=") }.map { String($0.dropFirst(4)) }
        return Link(kind: kind, id: id, gid: gid)
    }

    /// Export addresses to try, best first: Markdown keeps a document's headings, lists and tables.
    static func exports(_ link: Link) -> [(url: URL, format: String)] {
        let base = "https://docs.google.com/\(link.kind.rawValue)/d/\(link.id)/export"
        switch link.kind {
        case .document:
            return [(URL(string: base + "?format=md")!, "md"), (URL(string: base + "?format=txt")!, "txt")]
        case .spreadsheets:
            return [(URL(string: base + "?format=csv" + (link.gid.map { "&gid=\($0)" } ?? ""))!, "csv")]
        case .presentation:
            return [(URL(string: base + "?format=txt")!, "txt")]
        }
    }

    /// Reads a shared Google file as Markdown, CSV or text.
    static func read(_ link: Link, original: URL) async throws -> WebPage.Page {
        var lastError: Error = GoogleError.notShared
        for export in exports(link) {
            var request = URLRequest(url: export.url, timeoutInterval: 25)
            request.setValue("Mozilla/5.0 (compatible; Blablador)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let type = (response.mimeType ?? "").lowercased()
                // Private files answer 401/403, or a sign-in page after redirects.
                if status == 401 || status == 403 || type.contains("html") || response.url?.host()?.contains("accounts.google") == true {
                    throw GoogleError.notShared
                }
                guard (200..<300).contains(status) else { throw BlabladorAPIError.http(status: status, body: "Google couldn't export this file.") }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = text.split(separator: "\n").first.map { $0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
                let name = switch link.kind {
                case .document: "Google Doc"
                case .spreadsheets: "Google Sheet (CSV)"
                case .presentation: "Google Slides"
                }
                return WebPage.Page(title: [name, title.map { String($0.prefix(80)) }].compactMap { $0 }.joined(separator: ": "),
                                    url: original, text: String(text.prefix(WebPage.maxCharacters)))
            } catch let error as GoogleError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

#if os(macOS)
import AppKit

/// The Google Drive for desktop folder ("My Drive" under ~/Library/CloudStorage/GoogleDrive-…), when installed.
enum GoogleDrive {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "googleDriveEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "googleDriveEnabled") }
    }

    /// Each signed-in account's "My Drive" folder.
    static var roots: [URL] {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let accounts = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        return accounts.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }.flatMap { account -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: account.path)) ?? []
            let drives = names.filter { ["My Drive", "Meine Ablage", "Mon Drive", "Mi unidad", "Il mio Drive", "Meu Drive"].contains($0) }
            return (drives.isEmpty ? [account] : drives.map { account.appendingPathComponent($0, isDirectory: true) })
        }
    }

    static var available: Bool { enabled && !roots.isEmpty }

    static let names: Set<String> = ["drive_search", "drive_read", "drive_save"]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    static let definitions: [[String: Any]] = [
        function("drive_search", "Search the user's Google Drive (synced to this Mac) by file name and content.", [
            "query": ["type": "string"]
        ], required: ["query"]),
        function("drive_read", "Read a file from the user's Google Drive: Word, PDF, text, Markdown, CSV, RTF, or a Google Doc/Sheet/Slides that is shared by link.", [
            "path": ["type": "string", "description": "Path as returned by drive_search, relative to the Drive."]
        ], required: ["path"]),
        function("drive_save", "Save a document into the user's Google Drive; it syncs up by itself. Google Docs can't be changed in place: save a new file (Word keeps formatting and opens in Google Docs). The user is asked first.", [
            "path": ["type": "string", "description": "Path relative to the Drive, e.g. \"Reports/Summary.docx\". The extension sets the format: .docx (Word), .xlsx (Excel, from Markdown tables), .pptx (PowerPoint, one slide per heading), .md, .txt or .csv."],
            "content": ["type": "string", "description": "The document in Markdown (for .docx and .md), or plain text/CSV."]
        ], required: ["path", "content"])
    ]

    static let systemPrompt = "The user's Google Drive is synced to this Mac: use drive_search, drive_read and drive_save for their Drive files. Native Google Docs, Sheets and Slides can only be read when shared by link and can't be edited in place: write the changed version with drive_save as a new Word file, or give the text for the user to paste back (replies have a Copy for Google Docs button)."

    enum DriveError: LocalizedError {
        case outside, unreadable(String), exists(String)
        var errorDescription: String? {
            switch self {
            case .outside: "That path is outside the Google Drive folder."
            case let .unreadable(name): "\(name) can't be read as text (try a Word, PDF, text or CSV file)."
            case let .exists(name): "\(name) already exists; choose another name."
            }
        }
    }

    /// A path inside one of the Drive roots, following symlinks; nil when it leads outside.
    static func resolve(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        for root in roots {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(trimmed)).resolvingSymlinksInPath().standardizedFileURL
            if candidate.path == resolvedRoot || candidate.path.hasPrefix(resolvedRoot + "/") { return candidate }
        }
        return nil
    }

    private static func relative(_ url: URL) -> String {
        for root in roots {
            let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return url.lastPathComponent
    }

    static func run(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "drive_search": return try await search(arguments["query"] as? String ?? "")
        case "drive_read": return try await read(arguments["path"] as? String ?? "")
        case "drive_save": return try save(arguments["path"] as? String ?? "", content: arguments["content"] as? String ?? "")
        default: return "Unknown tool \(name)."
        }
    }

    /// Spotlight within the Drive folders, plus file names (Drive's online-only files may not be indexed).
    static func search(_ query: String) async throws -> String {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Give a search term." }
        var found: [URL] = []
        for root in roots {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", root.path, query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            found += String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            if found.count < 30, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                var checked = 0
                while let url = enumerator.nextObject() as? URL, checked < 20_000, found.count < 60 {
                    checked += 1
                    if url.lastPathComponent.localizedCaseInsensitiveContains(query), !found.contains(url) { found.append(url) }
                }
            }
        }
        guard !found.isEmpty else { return "Nothing in Google Drive matches \"\(query)\"." }
        return found.prefix(40).map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let date = values?.contentModificationDate.map { ", changed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "- \(relative(url))\(values?.isDirectory == true ? "/" : "")\(date)"
        }.joined(separator: "\n")
    }

    static func read(_ path: String) async throws -> String {
        guard let url = resolve(path) else { throw DriveError.outside }
        let ext = url.pathExtension.lowercased()
        // Native Google files are small JSON stubs with the document's link.
        if ["gdoc", "gsheet", "gslides"].contains(ext) {
            let data = try Data(contentsOf: url)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let address = object?["url"] as? String
                ?? (object?["doc_id"] as? String).map { id in
                    let kind = ext == "gsheet" ? "spreadsheets" : ext == "gslides" ? "presentation" : "document"
                    return "https://docs.google.com/\(kind)/d/\(id)/edit"
                }
            guard let address, let link = URL(string: address), let google = GoogleDocs.link(link) else { throw DriveError.unreadable(url.lastPathComponent) }
            let page = try await GoogleDocs.read(google, original: link)
            return "\(page.title)\n\(link.absoluteString)\n\n\(page.text)"
        }
        var text: String
        switch ext {
        case "pdf":
            text = try await PDFExtractor.extract(from: url).text
        case "docx", "doc", "rtf", "odt", "html", "htm", "webarchive":
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            text = attributed.string
        default:
            guard let plain = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
                throw DriveError.unreadable(url.lastPathComponent)
            }
            text = plain
        }
        return "\(relative(url))\n\n" + String(text.prefix(WebPage.maxCharacters))
    }

    static func save(_ path: String, content: String) throws -> String {
        guard let url = resolve(path), url.pathExtension.count > 0 else { throw DriveError.outside }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw DriveError.exists(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        switch url.pathExtension.lowercased() {
        case "docx": data = DocumentExport.docx(markdown: content)
        case "pptx": data = DocumentExport.pptx(markdown: content)
        case "xlsx":
            guard let workbook = DocumentExport.xlsx(markdown: content) else { throw DriveError.unreadable("The content has no table for a spreadsheet") }
            data = workbook
        default: data = Data(content.utf8)
        }
        try data.write(to: url)
        return "Saved \(relative(url)) to Google Drive; it syncs up by itself. In Google Docs, File → Save as Google Docs makes it a native document."
    }
}
#endif
