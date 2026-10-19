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
            Task { await loadModels() }
        }
    }

    @AppStorage("selectedModel") var selectedModel: String = BlabladorAPI.defaultModel {
        willSet { objectWillChange.send() }
    }

    @AppStorage("systemPrompt") var systemPrompt: String = "" {
        willSet { objectWillChange.send() }
    }

    @AppStorage("webSearchEnabled") var webSearchEnabled = true {
        willSet { objectWillChange.send() }
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

    // MARK: - Conversations

    func newChat() {
        stop()
        currentID = nil
    }

    func select(_ conversation: Conversation) {
        stop()
        currentID = conversation.id
        selectedModel = conversation.model
    }

    func delete(_ conversation: Conversation) {
        if conversation.id == currentID { newChat() }
        conversations.removeAll { $0.id == conversation.id }
        persist()
    }

    func deleteAll() {
        newChat()
        conversations.removeAll()
        persist()
    }

    // MARK: - Messaging

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        if currentID == nil {
            let conversation = Conversation(title: Self.title(for: trimmed), model: selectedModel)
            conversations.insert(conversation, at: 0)
            currentID = conversation.id
        }
        update { $0.messages.append(ChatMessage(role: .user, content: trimmed)) }
        respond()
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
        if webSearchEnabled {
            let today = Date().formatted(date: .complete, time: .omitted)
            system += "\n\nToday is \(today). You can use the web_search tool for current or uncertain information. Cite sources inline as [1], [2] matching the search results."
        }
        system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { wire.append(["role": "system", "content": system]) }
        wire += conversation.messages.filter { !$0.isError }.map { ["role": $0.role.rawValue, "content": $0.content] }

        let reply = ChatMessage(role: .assistant, content: "")
        let model = selectedModel
        update {
            $0.model = model
            $0.messages.append(reply)
        }

        isStreaming = true
        let tools = webSearchEnabled ? [WebSearch.tool] : []
        streamTask = Task {
            do {
                try await runTurn(model: model, messages: wire, tools: tools, replyID: reply.id)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { message in
                message.status = nil
                if message.content.isEmpty, !Task.isCancelled {
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
            // Offer tools only while rounds remain, so the model has to answer eventually.
            let offered = round < Self.maxToolRounds ? tools : []
            var text = ""
            var calls: [BlabladorAPI.ToolCall] = []
            do {
                for try await event in api.streamChat(model: model, messages: messages, tools: offered) {
                    switch event {
                    case let .content(delta):
                        text += delta
                        updateMessage(replyID) {
                            $0.status = nil
                            $0.content += delta
                        }
                    case let .toolCalls(toolCalls):
                        calls = toolCalls
                    }
                }
            } catch BlabladorAPIError.http(let status, _) where status == 400 && !offered.isEmpty && round == 0 {
                // Model without tool support: answer without web search.
                tools = []
                continue
            }

            guard !calls.isEmpty else { return }

            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls.map(\.wire)]
            assistant["content"] = text.isEmpty ? NSNull() : text
            messages.append(assistant)
            if !text.isEmpty {
                updateMessage(replyID) { $0.content += "\n\n" }
            }

            for call in calls {
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                let query = arguments?["query"] as? String ?? ""
                updateMessage(replyID) { $0.status = "Searching “\(query)”" }

                let output: String
                if call.name == "web_search", !query.isEmpty {
                    do {
                        let results = try await WebSearch.search(query)
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
            updateMessage(replyID) { $0.status = "Reading results…" }
        }
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
