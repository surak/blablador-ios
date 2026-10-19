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

    /// Image models available on Blablador. Only Qwen-Image can edit images.
    static let imageModels: [(id: String, name: String)] = [
        ("alias-flux2", "FLUX.2-dev"),
        ("alias-image", "Qwen-Image 2.1")
    ]
    static let defaultImageModel = "alias-flux2"
    static let imageEditModel = "alias-image"
    static let speechModel = "alias-voice-drama3"
    static let transcriptionModel = "faster-whisper-large-v3"
    static let embeddingModel = "alias-qwen3-4b-embeddings"
    /// Used for a new knowledge base when the default embedding model doesn't respond.
    static let fallbackEmbeddingModel = "alias-embeddings"
    static let rerankModel = "alias-qwen3-4b-reranker"

    var apiKey: String

    private func request(path: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw BlabladorAPIError.missingAPIKey }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Blablador keys are Helmholtz Codebase (GitLab) tokens, so the owner's name comes from GitLab.
    func userName() async throws -> String {
        struct User: Decodable { let name: String }
        guard !apiKey.isEmpty else { throw BlabladorAPIError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://codebase.helmholtz.cloud/api/v4/user")!)
        request.setValue(apiKey, forHTTPHeaderField: "PRIVATE-TOKEN")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: "")
        return try JSONDecoder().decode(User.self, from: data).name
    }

    func models() async throws -> [RemoteModel] {
        struct Response: Decodable { let data: [RemoteModel] }
        let (data, response) = try await URLSession.shared.data(for: request(path: "models"))
        try Self.validate(response, body: String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    func generateImage(model: String, prompt: String) async throws -> Data {
        var request = try request(path: "images/generations")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "n": 1, "size": "1024x1024"])
        return try await imageResponse(for: request)
    }

    func editImage(prompt: String, image: Data) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try request(path: "images/edits")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", Self.imageEditModel)
        field("prompt", prompt)
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image.\(isPNG ? "png" : "jpg")\"\r\nContent-Type: image/\(isPNG ? "png" : "jpeg")\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return try await imageResponse(for: request)
    }

    func embeddings(_ texts: [String], model: String = BlabladorAPI.embeddingModel) async throws -> [[Float]] {
        struct Response: Decodable {
            struct Item: Decodable { let index: Int; let embedding: [Float] }
            let data: [Item]
        }
        var request = try request(path: "embeddings")
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    /// Returns document indices, most relevant first.
    func rerank(query: String, documents: [String]) async throws -> [Int] {
        struct Response: Decodable {
            struct Item: Decodable { let index: Int; let relevance_score: Double }
            let results: [Item]
        }
        var request = try request(path: "rerank")
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": Self.rerankModel, "query": query, "documents": documents])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).results.sorted { $0.relevance_score > $1.relevance_score }.map(\.index)
    }

    /// Speaks `text` with Drama 3, either with a built-in voice or cloned from a reference recording.
    /// Returns MP3 audio.
    func speech(text: String, voice: Voice) async throws -> Data {
        var request = try request(path: "audio/speech")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        var body: [String: Any] = ["model": Self.speechModel, "input": text, "response_format": "mp3"]
        if let referenceID = voice.referenceID {
            body["voice"] = referenceID
        } else if let sample = voice.sampleFile, let audio = VoiceLibrary.sampleData(for: sample) {
            body["references"] = [["audio_path": "data:audio/mp4;base64," + audio.base64EncodedString(), "text": voice.transcript]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return data
    }

    /// Transcribes an audio file with Whisper; used for the transcript voice cloning needs.
    func transcribe(audio: Data, fileName: String = "sample.wav") async throws -> String {
        struct Response: Decodable { let text: String }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try request(path: "audio/transcriptions")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Self.transcriptionModel)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func imageResponse(for request: URLRequest) async throws -> Data {
        struct Response: Decodable {
            struct Item: Decodable { let b64_json: String? }
            let data: [Item]
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data, encoding: .utf8)?.prefix(500).description ?? "")
        guard let encoded = try JSONDecoder().decode(Response.self, from: data).data.first?.b64_json,
              let image = Data(base64Encoded: encoded) else {
            throw BlabladorAPIError.http(status: 200, body: "No image in response.")
        }
        return image
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
