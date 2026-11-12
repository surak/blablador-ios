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
    static let defaultEndpoint = "https://api.blablador.fz-juelich.de/v1"
    /// The OpenAI-compatible endpoint, Blablador unless changed in Settings.
    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: "apiEndpoint") ?? defaultEndpoint }
        set { UserDefaults.standard.set(newValue, forKey: "apiEndpoint") }
    }
    static var baseURL: URL {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: defaultEndpoint)!
    }
    static let defaultModel = "deepseek-v4.1-flash-at-hzdr"
    /// Blablador's quick model for small jobs: chat titles, picking out memories.
    static let fastModel = "alias-fast"

    /// The model for small jobs: alias-fast on Blablador, the chat's own model on other endpoints.
    static func helperModel(else chatModel: String) -> String {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return endpoint == defaultEndpoint ? fastModel : chatModel
    }

    /// One reply without tools, as plain text (thinking included; see ChatStore.splitThinking).
    func complete(model: String, system: String, user: String) async throws -> String {
        var text = ""
        for try await event in streamChat(model: model, messages: [["role": "system", "content": system], ["role": "user", "content": user]]) {
            if case let .content(delta) = event { text += delta }
        }
        return text
    }

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
    static let ocrModel = "alias-ocr"
    /// Used for a new knowledge base when the default embedding model doesn't respond.
    static let fallbackEmbeddingModel = "alias-embeddings"
    static let rerankModel = "alias-qwen3-4b-reranker"
    /// MiniMax-H3: text to video with sound, at 24 fps. A 4-second clip takes about 3–4 minutes.
    static let videoModel = "alias-video"
    /// VGGT-Ω (VGGT-Omega-1B): photos of a place in, a top-down map and a coloured point cloud out.
    static let visualGeometryModel = "alias-visual-geometry"
    static let videoDurations = [4, 6, 8, 10]
    static let videoAspects: [(id: String, name: String)] = [("16:9", "Landscape"), ("9:16", "Portrait"), ("1:1", "Square")]

    var apiKey: String

    /// Endpoints that refused `stream_options.include_usage` (token counts), so it isn't sent to them again.
    static var usageRejected: Bool {
        get { (UserDefaults.standard.stringArray(forKey: "usageRejected") ?? []).contains(endpoint) }
        set {
            var list = Set(UserDefaults.standard.stringArray(forKey: "usageRejected") ?? [])
            if newValue { list.insert(endpoint) } else { list.remove(endpoint) }
            UserDefaults.standard.set(Array(list), forKey: "usageRejected")
        }
    }

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

    /// Makes a video with sound from a text prompt and returns the MP4.
    /// With `firstFrame`, the clip opens on that image (continuing a video or animating a picture)
    /// and takes its shape from it.
    func generateVideo(prompt: String, seconds: Int, aspect: String, firstFrame: Data? = nil) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try request(path: "videos/sync")
        request.httpMethod = "POST"
        request.timeoutInterval = 2 * 60 * 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let size = switch aspect {
        case "9:16": (768, 1344)
        case "1:1": (768, 768)
        default: (1344, 768)
        }
        var body = Data()
        var fields = [("model", Self.videoModel), ("prompt", prompt), ("extra_params", "{\"duration\":\(seconds)}")]
        if firstFrame == nil {
            fields += [("aspect_ratio", aspect), ("width", "\(size.0)"), ("height", "\(size.1)")]
        }
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let firstFrame {
            let isPNG = firstFrame.starts(with: [0x89, 0x50, 0x4E, 0x47])
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"first_frame\"; filename=\"frame.\(isPNG ? "png" : "jpg")\"\r\nContent-Type: image/\(isPNG ? "png" : "jpeg")\r\n\r\n".utf8))
            body.append(firstFrame)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return data
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

    /// Reads a page image with LightOnOCR; returns Markdown (tables come back as HTML).
    func ocr(jpeg: Data) async throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        var request = try request(path: "chat/completions")
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        let content: [[String: Any]] = [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.ocrModel, "messages": [["role": "user", "content": content]], "max_tokens": 4096, "temperature": 0
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        return try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
    }

    /// Sends a command (`step`, `finish`, `download`, `queue`) with JPEG photos to `alias-visual-geometry`; the reply is JSON.
    func visualGeometry(_ command: String, photos: [Data] = []) async throws -> [String: Any] {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        var request = try request(path: "chat/completions")
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        let content: [[String: Any]] = [["type": "text", "text": command]]
            + photos.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.visualGeometryModel, "messages": [["role": "user", "content": content]]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
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
    /// `language` is an ISO 639-1 code such as "pt"; without it Whisper guesses.
    func transcribe(audio: Data, fileName: String = "sample.wav", language: String? = nil, timeout: TimeInterval = 300) async throws -> String {
        struct Response: Decodable { let text: String }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try request(path: "audio/transcriptions")
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Self.transcriptionModel)\r\n".utf8)
        if let language, !language.isEmpty {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
        }
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
        case reasoning(String)
        case toolCalls([ToolCall])
        /// Tokens the request used, sent at the end when the server reports them.
        case usage(prompt: Int, completion: Int)
    }

    struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""

        var wire: [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
    }

    /// Minutes to wait for a reply to start or continue; 0 waits as long as it takes. Set in Settings → Model.
    static var responseTimeoutMinutes: Int {
        get { UserDefaults.standard.object(forKey: "responseTimeoutMinutes") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "responseTimeoutMinutes") }
    }

    static let responseTimeoutChoices = [2, 5, 10, 30, 0]

    static func timeoutLabel(_ minutes: Int) -> String {
        minutes == 0 ? "No limit" : "\(minutes) minutes"
    }

    /// Streams a chat completion. `messages` are OpenAI wire-format dictionaries.
    /// With `effort`, asks the model to think that hard, trying the ways of saying it the model may understand
    /// (see ReasoningEffort.candidates) until one is accepted.
    func streamChat(model: String, messages: [[String: Any]], tools: [[String: Any]] = [], effort: ReasoningEffort? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try request(path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Slow models can take minutes before the first token; the default is 60 s.
                    let minutes = Self.responseTimeoutMinutes
                    request.timeoutInterval = minutes == 0 ? 7 * 24 * 3600 : TimeInterval(minutes * 60)
                    var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
                    if !tools.isEmpty { body["tools"] = tools }
                    let candidates = effort.map { ReasoningEffort.candidates(for: model, $0) } ?? [[:]]
                    // Ask for token counts at the end of the stream; a server that rejects the option gets every
                    // candidate again without it, and is remembered so later replies don't ask.
                    let usage = !Self.usageRejected
                    let attempts = (usage ? candidates.map { ($0, true) } : []) + candidates.map { ($0, false) }
                    var bytes: URLSession.AsyncBytes!
                    for (attempt, (extra, withUsage)) in attempts.enumerated() {
                        let index = attempt % candidates.count
                        var sent = body.merging(extra) { $1 }
                        if withUsage { sent["stream_options"] = ["include_usage": true] }
                        request.httpBody = try JSONSerialization.data(withJSONObject: sent)
                        let (stream, response) = try await URLSession.shared.bytes(for: request)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            var text = ""
                            for try await line in stream.lines { text += line }
                            // A way of setting the effort the model doesn't take: try the next.
                            if [400, 422].contains(http.statusCode), attempt + 1 < attempts.count { continue }
                            throw BlabladorAPIError.http(status: http.statusCode, body: text)
                        }
                        if usage && !withUsage { Self.usageRejected = true }
                        if let effort { ReasoningEffort.remember(index, for: model, effort) }
                        bytes = stream
                        break
                    }

                    var toolCalls: [Int: ToolCall] = [:]
                    var lastUsage: ChatChunk.Usage?
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else { continue }
                        // Some servers repeat running totals in many chunks: only the last one counts.
                        if let usage = chunk.usage { lastUsage = usage }
                        guard let delta = chunk.choices?.first?.delta else { continue }
                        if let thinking = delta.reasoning_content ?? delta.reasoning, !thinking.isEmpty {
                            continuation.yield(.reasoning(thinking))
                        }
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
                    if let lastUsage {
                        continuation.yield(.usage(prompt: lastUsage.prompt_tokens ?? 0, completion: lastUsage.completion_tokens ?? 0))
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

/// How hard a model thinks before it answers. The app uses these names for every model; `candidates` turns
/// them into the request fields each kind of model understands.
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case off, low, medium, high, max

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    private enum Family { case openAI, deepSeek, toggle }

    private static func family(_ model: String) -> Family? {
        let id = model.lowercased()
        if id.contains("gpt-oss") || id.contains("gpt-5") || id.range(of: #"(^|[^a-z0-9])o[134](-|$)"#, options: .regularExpression) != nil { return .openAI }
        if id.contains("deepseek"), ["v3.1", "v3.2", "v4"].contains(where: id.contains) { return .deepSeek }
        // Qwen3 and GLM switch thinking on or off; their instruct and coder versions don't think.
        if (id.contains("qwen3") || id.contains("glm-4.5") || id.contains("glm-4.6") || id.contains("glm-4.7") || id.contains("glm-5")),
           !["instruct", "coder", "thinking", "-vl"].contains(where: id.contains) { return .toggle }
        return nil
    }

    /// The levels a model takes, or none when its thinking can't be set.
    static func levels(for model: String) -> [ReasoningEffort] {
        switch family(model) {
        case .openAI: [.low, .medium, .high, .max]
        case .deepSeek: [.off, .low, .medium, .high, .max]
        case .toggle: [.off, .high]
        case nil: []
        }
    }

    /// Medium unless chosen otherwise: models left to themselves think long, which is slow for everyday questions.
    static func defaultLevel(for model: String) -> ReasoningEffort? {
        let levels = levels(for: model)
        return levels.contains(.medium) ? .medium : levels.last
    }

    private static let key = "reasoningEffort"

    /// The level chosen for a model (per model, in UserDefaults), or its default.
    static func level(for model: String) -> ReasoningEffort? {
        let levels = levels(for: model)
        let saved = (UserDefaults.standard.dictionary(forKey: key)?[model] as? String).flatMap(ReasoningEffort.init)
        if let saved, levels.contains(saved) { return saved }
        return defaultLevel(for: model)
    }

    static func setLevel(_ level: ReasoningEffort, for model: String) {
        var saved = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        saved[model] = level.rawValue
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// Request fields to try, best first. Models name the levels differently: "max" may be "xhigh" or only
    /// "high", and some switch thinking with chat template options. The last candidate sends nothing extra.
    /// The way that was accepted last time comes first.
    static func candidates(for model: String, _ level: ReasoningEffort) -> [[String: Any]] {
        var result = allCandidates(for: model, level)
        if let worked = worked(for: model, level), worked > 0, result.indices.contains(worked) {
            result.insert(result.remove(at: worked), at: 0)
        }
        return result
    }

    /// Notes which candidate (an index into `candidates`) the server accepted.
    static func remember(_ index: Int, for model: String, _ level: ReasoningEffort) {
        let all = allCandidates(for: model, level)
        let tried = candidates(for: model, level)
        guard tried.indices.contains(index),
              let position = all.firstIndex(where: { NSDictionary(dictionary: $0).isEqual(to: tried[index]) }),
              position != worked(for: model, level) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: workedKey) ?? [:]
        saved["\(model)|\(level.rawValue)"] = position
        UserDefaults.standard.set(saved, forKey: workedKey)
    }

    private static let workedKey = "reasoningEffortWorked"

    private static func worked(for model: String, _ level: ReasoningEffort) -> Int? {
        UserDefaults.standard.dictionary(forKey: workedKey)?["\(model)|\(level.rawValue)"] as? Int
    }

    private static func allCandidates(for model: String, _ level: ReasoningEffort) -> [[String: Any]] {
        var result: [[String: Any]]
        switch family(model) {
        case .openAI:
            let names = level == .max ? ["max", "xhigh", "high"] : level == .off ? ["minimal", "low"] : [level.rawValue]
            result = names.map { ["reasoning_effort": $0] }
        case .deepSeek:
            if level == .off {
                result = [["chat_template_kwargs": ["thinking": false], "thinking": ["type": "disabled"]],
                          ["chat_template_kwargs": ["thinking": false]]]
            } else {
                let names = level == .max ? ["max", "xhigh", "high"] : [level.rawValue]
                result = names.map { ["reasoning_effort": $0, "chat_template_kwargs": ["thinking": true, "reasoning_effort": $0]] }
                    + names.map { ["reasoning_effort": $0] }
            }
        case .toggle:
            result = [["chat_template_kwargs": ["enable_thinking": level != .off]]]
        case nil:
            return [[:]]
        }
        return result + [[:]]
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
            /// Thinking trace: vLLM and DeepSeek send `reasoning_content`, others `reasoning`.
            let reasoning_content: String?
            let reasoning: String?
            let tool_calls: [ToolCallDelta]?
        }
        let delta: Delta
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }

    let choices: [Choice]?
    let usage: Usage?
}
