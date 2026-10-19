import Foundation
import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var models: [RemoteModel] = []
    @Published var isStreaming = false
    @Published var modelsError: String?

    @Published var apiKey: String {
        didSet {
            KeychainHelper.save(apiKey, for: "apiKey")
            userName = ""
            Task {
                await loadModels()
                await loadUserName()
            }
        }
    }

    @AppStorage("selectedModel") var selectedModel: String = BlabladorAPI.defaultModel {
        willSet { objectWillChange.send() }
    }

    /// Name used in the welcome greeting.
    @AppStorage("userName") var userName: String = "" {
        willSet { objectWillChange.send() }
    }

    @AppStorage("systemPrompt") var systemPrompt: String = "" {
        willSet { objectWillChange.send() }
    }

    @AppStorage("webSearchEnabled") var webSearchEnabled = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("imageModel") var imageModel: String = BlabladorAPI.defaultImageModel {
        willSet { objectWillChange.send() }
    }

    @AppStorage("imageToolsEnabled") var imageToolsEnabled = true {
        willSet { objectWillChange.send() }
    }

    var imageModelName: String {
        BlabladorAPI.imageModels.first { $0.id == imageModel }?.name ?? imageModel
    }

    private static let maxToolRounds = 4

    private var streamTask: Task<Void, Never>?

    private static var storageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("conversations.json")
    }

    init() {
        apiKey = KeychainHelper.read("apiKey") ?? ""
        if let data = try? Data(contentsOf: Self.storageURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }

    var api: BlabladorAPI { BlabladorAPI(apiKey: apiKey) }

    var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    var chatModels: [RemoteModel] {
        models.filter(\.isChatCapable).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var selectedModelName: String {
        RemoteModel(id: selectedModel).displayName
    }

    // MARK: - Models

    func loadModels() async {
        guard !apiKey.isEmpty else {
            models = []
            return
        }
        do {
            models = try await api.models()
            modelsError = nil
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Greeting name of the key's owner; left empty when the lookup fails.
    func loadUserName() async {
        guard !apiKey.isEmpty, let name = try? await api.userName() else { return }
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversations

    func newChat() {
        stop()
        currentID = nil
        pendingKnowledge = []
    }

    /// Knowledge bases picked before the first message of a new chat.
    @Published private var pendingKnowledge: [UUID] = []

    /// Knowledge bases searched for the current chat.
    var activeKnowledge: [UUID] {
        get {
            let ids = currentID == nil ? pendingKnowledge : current?.knowledge ?? []
            return ids.filter { KnowledgeLibrary.shared.base($0) != nil }
        }
        set {
            if currentID == nil {
                pendingKnowledge = newValue
            } else {
                update { $0.knowledge = newValue }
            }
        }
    }

    func toggleKnowledge(_ id: UUID) {
        if activeKnowledge.contains(id) {
            activeKnowledge.removeAll { $0 == id }
        } else {
            activeKnowledge.append(id)
        }
    }

    func select(_ conversation: Conversation) {
        stop()
        currentID = conversation.id
        selectedModel = conversation.model
    }

    func delete(_ conversation: Conversation) {
        if conversation.id == currentID { newChat() }
        ImageStore.delete(conversation.messages.flatMap(\.images))
        AudioStore.delete(conversation.messages.flatMap(\.audio))
        conversations.removeAll { $0.id == conversation.id }
        persist()
    }

    func deleteAll() {
        newChat()
        ImageStore.delete(conversations.flatMap { $0.messages.flatMap(\.images) })
        AudioStore.delete(conversations.flatMap { $0.messages.flatMap(\.audio) })
        conversations.removeAll()
        persist()
    }

    // MARK: - Messaging

    /// Sends a chat message. With `createImage`, the text is used directly as an image prompt;
    /// with `speak`, it is read aloud with Drama 3.
    func send(_ text: String, attachments: [Data] = [], documents: [DocumentAttachment] = [], createImage: Bool = false, speak: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || !documents.isEmpty, !isStreaming else { return }

        if currentID == nil {
            let title = !trimmed.isEmpty ? Self.title(for: trimmed) : documents.first?.name ?? "Image"
            var conversation = Conversation(title: title, model: selectedModel)
            conversation.knowledge = pendingKnowledge
            pendingKnowledge = []
            conversations.insert(conversation, at: 0)
            currentID = conversation.id
        }
        let images = attachments.map(ImageStore.save)
        update { $0.messages.append(ChatMessage(role: .user, content: trimmed, images: images, documents: documents)) }

        if speak, !trimmed.isEmpty {
            makeSpeech(script: trimmed)
        } else if createImage {
            makeImage(prompt: trimmed, editing: images.last)
        } else {
            respond()
        }
    }

    /// Image mode: generate a new image, or edit the attached one with Qwen-Image.
    private func makeImage(prompt: String, editing source: String?) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        isStreaming = true
        streamTask = Task {
            do {
                let image = try await runImageTool(
                    name: source == nil ? "generate_image" : "edit_image",
                    prompt: prompt.isEmpty ? "Improve this image" : prompt,
                    source: source,
                    replyID: reply.id
                )
                updateMessage(reply.id) { $0.images.append(image) }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { $0.status = nil }
            isStreaming = false
            persist()
        }
    }

    /// Runs an image tool and returns the stored file name.
    private func runImageTool(name: String, prompt: String, source: String?, replyID: UUID) async throws -> String {
        let data: Data
        if name == "edit_image" {
            guard let source, let original = ImageStore.data(for: source) else {
                throw BlabladorAPIError.http(status: 400, body: "There is no image to edit.")
            }
            updateMessage(replyID) { $0.status = "Editing image with \(BlabladorAPI.imageModels.first { $0.id == BlabladorAPI.imageEditModel }?.name ?? "Qwen-Image")…" }
            data = try await api.editImage(prompt: prompt, image: ImageStore.jpeg(from: original, maxPixelSize: 1024) ?? original)
        } else {
            updateMessage(replyID) { $0.status = "Creating image with \(imageModelName)…" }
            data = try await api.generateImage(model: imageModel, prompt: prompt)
        }
        return ImageStore.save(data)
    }

    /// Speech mode: speak the user's text with the selected voice and delivery settings.
    private func makeSpeech(script: String) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        isStreaming = true
        streamTask = Task {
            do {
                let audio = try await runSpeechTool(script: script, replyID: reply.id)
                updateMessage(reply.id) { $0.audio.append(audio) }
                AudioPlayback.shared.toggle(audio)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { $0.status = nil }
            isStreaming = false
            persist()
        }
    }

    /// Speaks a script with Drama 3 and returns the stored file name.
    private func runSpeechTool(script: String, replyID: UUID) async throws -> String {
        let library = VoiceLibrary.shared
        updateMessage(replyID) { $0.status = "Speaking with \(library.selected.name)…" }
        let data = try await api.speech(text: library.styled(script), voice: library.selected)
        return AudioStore.save(data)
    }

    /// Most recent image in the current conversation, used as the source for edits.
    private var latestImage: String? {
        current?.messages.last { !$0.images.isEmpty }?.images.last
    }

    /// Drops the last assistant reply and asks again.
    func regenerate() {
        guard !isStreaming else { return }
        update { conversation in
            if conversation.messages.last?.role == .assistant {
                conversation.messages.removeLast()
            }
        }
        respond()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func respond() {
        guard let conversation = current else { return }

        var wire: [[String: Any]] = []
        var system = systemPrompt
        let today = Date().formatted(date: .complete, time: .omitted)
        system += "\n\nToday is \(today)."
        if webSearchEnabled {
            system += " You can use the web_search tool for current or uncertain information. Cite sources inline as [1], [2] matching the search results."
        }
        if imageToolsEnabled {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        if VoiceLibrary.shared.toolsEnabled {
            system += " You can speak aloud with generate_speech when the user asks you to say, read or voice something. Never claim you spoke unless the tool succeeded."
        }
        system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        wire.append(["role": "system", "content": system])
        wire += conversation.messages.filter { !$0.isError }.map(Self.wireMessage)

        let reply = ChatMessage(role: .assistant, content: "")
        let model = selectedModel
        let knowledge = activeKnowledge
        let question = conversation.messages.last { $0.role == .user }?.content ?? ""
        update {
            $0.model = model
            $0.messages.append(reply)
        }

        isStreaming = true
        var tools: [[String: Any]] = []
        if webSearchEnabled { tools.append(WebSearch.tool) }
        if imageToolsEnabled { tools += [ImageTools.generate, ImageTools.edit] }
        if VoiceLibrary.shared.toolsEnabled { tools.append(SpeechTools.generate) }
        streamTask = Task {
            do {
                var wire = wire
                if !knowledge.isEmpty, !question.isEmpty {
                    updateMessage(reply.id) { $0.status = "Searching knowledge…" }
                    do {
                        let citations = try await KnowledgeLibrary.shared.search(question, in: knowledge, api: api)
                        if !citations.isEmpty {
                            updateMessage(reply.id) { $0.citations = citations }
                            let system = (wire[0]["content"] as? String ?? "") + "\n\n" + KnowledgeLibrary.context(for: citations)
                            wire[0]["content"] = system.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } catch {
                        updateMessage(reply.id) { $0.status = "Knowledge search failed, answering without it…" }
                    }
                }
                try await runTurn(model: model, messages: wire, tools: tools, replyID: reply.id)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch BlabladorAPIError.http(let status, let body) where status == 400 && body.localizedCaseInsensitiveContains("image") {
                updateMessage(reply.id) {
                    $0.content = "\(RemoteModel(id: model).displayName) can't read images. Pick a vision model such as DeepSeek-V4.1-Flash or Qwen3.8-27B."
                    $0.isError = true
                }
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { message in
                message.status = nil
                if message.content.isEmpty, message.images.isEmpty, message.audio.isEmpty, !Task.isCancelled {
                    message.content = "No response from the model."
                    message.isError = true
                }
            }
            isStreaming = false
            persist()
        }
    }

    /// Streams the reply, running web searches whenever the model asks for them.
    private func runTurn(model: String, messages: [[String: Any]], tools: [[String: Any]], replyID: UUID) async throws {
        var messages = messages
        var tools = tools

        for round in 0...Self.maxToolRounds {
            let isFinalRound = round == Self.maxToolRounds
            if isFinalRound {
                // Keep the tools declared (removing them makes DeepSeek print raw tool markup),
                // but tell the model to answer with what it has.
                messages.append(["role": "user", "content": "Stop using tools now and write the final answer using the results above."])
            }
            let prefix = current?.messages.first { $0.id == replyID }?.content ?? ""
            var text = ""
            var calls: [BlabladorAPI.ToolCall] = []
            do {
                for try await event in api.streamChat(model: model, messages: messages, tools: tools) {
                    switch event {
                    case let .content(delta):
                        text += delta
                        let visible = Self.stripToolMarkup(text)
                        updateMessage(replyID) {
                            $0.status = nil
                            $0.content = prefix + visible
                        }
                    case let .toolCalls(toolCalls):
                        calls = toolCalls
                    }
                }
            } catch BlabladorAPIError.http(let status, let body) where status == 400 && !tools.isEmpty && round == 0 && !body.localizedCaseInsensitiveContains("image") {
                // Model without tool support: answer without web search.
                tools = []
                continue
            }

            if isFinalRound || (calls.isEmpty && Self.containsToolMarkup(text)) {
                // Model still wants to search; nothing more to run.
                if Self.stripToolMarkup(text).isEmpty {
                    updateMessage(replyID) { $0.content = prefix }
                }
                return
            }
            guard !calls.isEmpty else { return }

            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls.map(\.wire)]
            assistant["content"] = text.isEmpty ? NSNull() : text
            messages.append(assistant)
            // Preambles like "Let me look that up" are status, not part of the answer.
            updateMessage(replyID) { $0.content = prefix }

            for call in calls {
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                let query = arguments?["query"] as? String ?? ""
                let prompt = arguments?["prompt"] as? String ?? ""
                let script = arguments?["script"] as? String ?? ""

                let output: String
                if call.name == "generate_image" || call.name == "edit_image", !prompt.isEmpty {
                    do {
                        let image = try await runImageTool(name: call.name, prompt: prompt, source: latestImage, replyID: replyID)
                        updateMessage(replyID) { $0.images.append(image) }
                        output = "The image was created and is shown to the user. Do not include it or a link in your answer; just briefly comment on it."
                    } catch {
                        output = "Image tool failed: \(error.localizedDescription)"
                    }
                } else if call.name == "generate_speech", !script.isEmpty {
                    do {
                        let audio = try await runSpeechTool(script: script, replyID: replyID)
                        updateMessage(replyID) { $0.audio.append(audio) }
                        output = "The speech was created and the user can play it. Don't repeat the script; just briefly comment on it."
                    } catch {
                        output = "Speech tool failed: \(error.localizedDescription)"
                    }
                } else if call.name == "web_search", !query.isEmpty {
                    updateMessage(replyID) { $0.status = "Searching “\(query)”" }
                    do {
                        let results = try await WebSearch.search(
                            query,
                            category: arguments?["category"] as? String,
                            timeRange: arguments?["time_range"] as? String
                        )
                        var numbered: [(number: Int, result: SearchResult)] = []
                        updateMessage(replyID) { message in
                            for result in results {
                                if let index = message.sources.firstIndex(where: { $0.url == result.url }) {
                                    numbered.append((index + 1, result))
                                } else {
                                    message.sources.append(result)
                                    numbered.append((message.sources.count, result))
                                }
                            }
                        }
                        output = WebSearch.toolOutput(query: query, results: numbered)
                    } catch {
                        output = "Search failed: \(error.localizedDescription)"
                    }
                } else {
                    output = "Unknown tool \(call.name)."
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
            updateMessage(replyID) { $0.status = "Thinking…" }
        }
    }

    /// User attachments are sent as base64 images; generated images are only mentioned in text.
    /// Attached PDFs are sent as text ahead of the user's message.
    private static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        var text = message.content
        if !message.documents.isEmpty {
            let documents = message.documents.map { "<document name=\"\($0.name)\">\n\($0.text)\n</document>" }
            text = (documents + [text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        guard message.role == .user, !message.images.isEmpty else {
            var content = text
            if message.role == .assistant, !message.images.isEmpty {
                content = "[Generated image]\n" + content
            }
            if message.role == .assistant, !message.audio.isEmpty {
                content = "[Generated speech]\n" + content
            }
            return ["role": message.role.rawValue, "content": content]
        }
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for name in message.images {
            guard let data = ImageStore.data(for: name), let jpeg = ImageStore.jpeg(from: data) else { continue }
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        return ["role": "user", "content": parts]
    }

    private static let toolMarkupPattern = #"<[｜|]\s*DSML\s*[｜|][\s\S]*$"#

    private static func containsToolMarkup(_ text: String) -> Bool {
        text.range(of: toolMarkupPattern, options: .regularExpression) != nil
    }

    /// Removes raw tool-call markup some models emit as text instead of structured tool calls.
    private static func stripToolMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: toolMarkupPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func update(_ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        change(&conversations[index])
        conversations[index].updatedAt = Date()
        persist()
    }

    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        for c in conversations.indices {
            if let m = conversations[c].messages.firstIndex(where: { $0.id == id }) {
                change(&conversations[c].messages[m])
                return
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}
