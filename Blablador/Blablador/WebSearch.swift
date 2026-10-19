import Foundation

struct SearchResult: Codable, Hashable {
    let title: String
    let url: String
    let content: String?
}

/// Client for the Blablador SearXNG instance.
enum WebSearch {
    static let baseURL = URL(string: "https://search.blablador.fz-juelich.de/search")!
    static let maxResults = 6

    static func search(_ query: String) async throws -> [SearchResult] {
        struct Response: Decodable { let results: [SearchResult] }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
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
                    "query": ["type": "string", "description": "The search query"]
                ],
                "required": ["query"]
            ]
        ]
    ]
}
