import Foundation

enum BlabladorAPIError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Add your Blablador API key in Settings."
        case let .http(status, body):
            return "Server returned \(status). \(body)"
        }
    }
}

struct BlabladorAPI {
    static let baseURL = URL(string: "https://api.blablador.fz-juelich.de/v1")!
    static let defaultModel = "deepseek-v4.1-flash-at-hzdr"

    var apiKey: String

    private func request(path: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw BlabladorAPIError.missingAPIKey }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func models() async throws -> [RemoteModel] {
        struct Response: Decodable { let data: [RemoteModel] }
        let (data, response) = try await URLSession.shared.data(for: request(path: "models"))
        try Self.validate(response, body: String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    enum StreamEvent {
        case content(String)
        case toolCalls([ToolCall])
    }

    struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""

        var wire: [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
    }

    /// Streams a chat completion. `messages` are OpenAI wire-format dictionaries.
    func streamChat(model: String, messages: [[String: Any]], tools: [[String: Any]] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try request(path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
                    if !tools.isEmpty { body["tools"] = tools }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw BlabladorAPIError.http(status: http.statusCode, body: body)
                    }

                    var toolCalls: [Int: ToolCall] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                              let delta = chunk.choices.first?.delta else { continue }
                        if let content = delta.content, !content.isEmpty {
                            continuation.yield(.content(content))
                        }
                        for call in delta.tool_calls ?? [] {
                            var current = toolCalls[call.index ?? 0] ?? ToolCall()
                            if let id = call.id { current.id = id }
                            if let name = call.function?.name { current.name += name }
                            if let arguments = call.function?.arguments { current.arguments += arguments }
                            toolCalls[call.index ?? 0] = current
                        }
                    }
                    if !toolCalls.isEmpty {
                        continuation.yield(.toolCalls(toolCalls.sorted { $0.key < $1.key }.map(\.value)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func validate(_ response: URLResponse, body: String) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: body)
        }
    }
}

private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallDelta: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int?
                let id: String?
                let function: Function?
            }
            let content: String?
            let tool_calls: [ToolCallDelta]?
        }
        let delta: Delta
    }

    let choices: [Choice]
}
