import Foundation

struct SearchResult: Codable, Hashable {
    let title: String
    let url: String
    let content: String?
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
