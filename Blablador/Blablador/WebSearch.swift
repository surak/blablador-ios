import Foundation

struct SearchResult: Codable, Hashable {
    let title: String
    let url: String
    let content: String?
}

/// A picture found online, shown next to the answer.
struct WebImage: Codable, Hashable {
    let title: String
    /// The page the picture is on.
    let url: String
    let image: String
    let thumbnail: String?
}

enum WebSearch {
    static let baseURL = URL(string: "https://search.blablador.fz-juelich.de/search")!
    static let maxResults = 6

    static func search(_ query: String, category: String? = nil, timeRange: String? = nil) async throws -> [SearchResult] {
        struct Response: Decodable { let results: [SearchResult] }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        if let category, ["general", "news", "science", "it"].contains(category) {
            components.queryItems?.append(URLQueryItem(name: "categories", value: category))
        }
        if let timeRange, ["day", "week", "month", "year"].contains(timeRange) {
            components.queryItems?.append(URLQueryItem(name: "time_range", value: timeRange))
        }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: "Web search failed.")
        }
        return Array(try JSONDecoder().decode(Response.self, from: data).results.prefix(maxResults))
    }

    static let maxImages = 4

    /// Image search; only pictures served over HTTPS are kept.
    static func searchImages(_ query: String) async throws -> [WebImage] {
        struct Item: Decodable {
            let title: String?
            let url: String?
            let img_src: String?
            let thumbnail_src: String?
        }
        struct Response: Decodable { let results: [Item] }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "categories", value: "images")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: "Image search failed.")
        }
        let https = { (link: String?) in link.flatMap { $0.hasPrefix("https://") ? $0 : nil } }
        let images = try JSONDecoder().decode(Response.self, from: data).results.compactMap { item -> WebImage? in
            guard let image = https(item.img_src), let page = https(item.url) else { return nil }
            return WebImage(title: item.title ?? "", url: page, image: image, thumbnail: https(item.thumbnail_src))
        }
        return Array(images.prefix(maxImages))
    }

    /// Formats results as the tool response handed back to the model.
    static func toolOutput(query: String, results: [(number: Int, result: SearchResult)]) -> String {
        guard !results.isEmpty else { return "No results for \"\(query)\"." }
        return results.map { number, result in
            "[\(number)] \(result.title)\nURL: \(result.url)\n\(result.content ?? "")"
        }.joined(separator: "\n\n")
    }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web for current information, news, facts or anything you are unsure about. Returns titles, URLs and snippets.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query. Use specific keywords, not dates."],
                    "category": [
                        "type": "string",
                        "enum": ["general", "news", "science", "it"],
                        "description": "Use news for current events and headlines, science for papers, it for programming. Defaults to general."
                    ],
                    "time_range": [
                        "type": "string",
                        "enum": ["day", "week", "month", "year"],
                        "description": "Only return results from this period, e.g. day for today's news."
                    ]
                ],
                "required": ["query"]
            ]
        ]
    ]
}

extension WebSearch {
    static let imageTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "image_search",
            "description": "Find pictures online of a person, place, animal, plant, building, artwork, product or anything easier to understand when seen. The pictures are shown to the user next to your answer.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to find pictures of, e.g. a full name or place."]
                ],
                "required": ["query"]
            ]
        ]
    ]

    static let systemPrompt = " You can use the web_search tool for current or uncertain information, and read_page to read a link the user gives you or a search result in full. Cite sources inline as [1], [2] matching the search results. When asked about a person, place or thing you don't know well, search the web first instead of saying you don't know. When the user asks about something that is easier to understand with a picture, such as a person, place, animal, building or artwork, also call image_search; the pictures are shown next to your answer, so don't include image links."
}

/// Image tools the chat model can call.
enum ImageTools {
    static let generate: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_image",
            "description": "Create a new image from a text description. Use when the user asks to draw, create, generate or imagine a picture.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Detailed description of the image, in English."]
                ],
                "required": ["prompt"]
            ]
        ]
    ]

    static let edit: [String: Any] = [
        "type": "function",
        "function": [
            "name": "edit_image",
            "description": "Edit the most recent image in the conversation (attached by the user or generated earlier). Use when the user asks to change, modify or restyle that image.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Instruction describing the change, in English."]
                ],
                "required": ["prompt"]
            ]
        ]
    ]
}

/// Fetches a web page (or PDF) and reduces it to readable text, for the read_page tool.
enum WebPage {
    /// Characters of page text handed to the model.
    static let maxCharacters = 24_000

    struct Page {
        let title: String
        let url: URL
        let text: String
    }

    enum PageError: LocalizedError {
        case notAllowed, notText(String)
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Only public http(s) pages can be read."
            case let .notText(type): "This link is not a web page or PDF (\(type))."
            }
        }
    }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "read_page",
            "description": "Read the text of a web page or online PDF. Use it for links the user gives you and to read search results in full when the snippet is not enough.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The full http(s) address."]
                ],
                "required": ["url"]
            ]
        ]
    ]

    /// Refuses local addresses, so a page or prompt can't make the app read from the user's own network.
    static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") || !host.contains(".") && !host.contains(":") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: break
            }
        }
        if host.contains(":") || host.hasPrefix("[") { return false } // IPv6 literals
        return true
    }

    static func read(_ address: String) async throws -> Page {
        guard var url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PageError.notAllowed }
        if url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            url = components.url ?? url
        }
        guard isPublic(url) else { throw PageError.notAllowed }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (compatible; Blablador)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let final = response.url ?? url
        guard isPublic(final) else { throw PageError.notAllowed }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: "The page could not be loaded.")
        }
        let type = (response.mimeType ?? "").lowercased()
        if type == "application/pdf" || data.starts(with: Array("%PDF".utf8)) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let document = try await PDFExtractor.extract(from: file)
            return Page(title: final.lastPathComponent, url: final, text: String(document.text.prefix(maxCharacters)))
        }
        guard type.isEmpty || type.hasPrefix("text/") || type.contains("html") || type.contains("xml") || type.contains("json") else {
            throw PageError.notText(type)
        }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        if !type.contains("html") && !html.lowercased().contains("<html") {
            return Page(title: final.lastPathComponent, url: final, text: String(html.prefix(maxCharacters)))
        }
        return Page(title: title(of: html) ?? final.host() ?? final.absoluteString, url: final, text: String(readableText(html).prefix(maxCharacters)))
    }

    static func title(of html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let title = decodeEntities(String(html[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// The page's main text: the <article> or <main> element when there is one, without scripts, menus and footers;
    /// headings, list items and paragraphs kept on their own lines.
    static func readableText(_ html: String) -> String {
        var body = html
        for tag in ["article", "main"] {
            if let range = html.range(of: "<\(tag)[\\s>][\\s\\S]*</\(tag)>", options: [.regularExpression, .caseInsensitive]),
               html[range].count > 500 {
                body = String(html[range])
                break
            }
        }
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "template", "iframe"] {
            body = body.replacingOccurrences(of: "<\(tag)[\\s>][\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: #"<h[1-6][^>]*>"#, with: "\n\n## ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<li[^>]*>"#, with: "\n- ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<(br|/p|/div|/h[1-6]|/tr|/li|/section|/table|p|div|tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<(td|th)[^>]*>"#, with: " | ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        body = decodeEntities(body)
        let lines = body.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && result.last?.isEmpty != false) {
            // A list marker whose text ended up on a later line: join them.
            if !line.isEmpty, let last = result.indices.last {
                let previous = result[last].isEmpty && last > 0 ? last - 1 : last
                if result[previous] == "-" || result[previous] == "##" {
                    result[previous] += " " + line
                    result.removeSubrange((previous + 1)...)
                    continue
                }
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return text }
        let ns = text as NSString
        var output = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            if let value = UInt32(ns.substring(with: match.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                output += String(Character(scalar))
            } else {
                output += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        return output + ns.substring(from: last)
    }
}
