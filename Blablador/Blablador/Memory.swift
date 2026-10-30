import SwiftUI

/// Something the assistant remembers about the user across chats.
struct Memory: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
}

/// Long-term memory: facts saved on the device with the remember tool and sent with every chat.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    /// Most memories kept; the oldest are dropped first.
    static let maxMemories = 500

    @Published private(set) var memories: [Memory] = []

    @AppStorage("memoryEnabled") var enabled = true {
        willSet { objectWillChange.send() }
    }
    /// After each reply, save what's worth keeping from the exchange without being asked.
    @AppStorage("memoryLearnsAutomatically") var learnsAutomatically = true {
        willSet { objectWillChange.send() }
    }

    private init() {
        if let data = EncryptedStorage.read(Self.fileURL),
           let memories = try? JSONDecoder().decode([Memory].self, from: data) {
            self.memories = memories
        }
    }

    /// Saves a fact; returns false for an empty text or one already remembered.
    @discardableResult
    func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !memories.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return false }
        memories.append(Memory(text: text))
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        persist()
        return true
    }

    func update(_ memory: Memory, text: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[index].text = text
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        memories.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Deletes memory number `number` as listed in the system prompt (1-based).
    func forget(number: Int) -> Memory? {
        guard memories.indices.contains(number - 1) else { return nil }
        let memory = memories.remove(at: number - 1)
        persist()
        return memory
    }

    func deleteAll() {
        memories = []
        persist()
    }

    /// Up to this many memories are always sent; beyond it only the relevant ones.
    nonisolated static let alwaysSent = 30

    /// Added to the system prompt when memory is on. With many memories, only those sharing words with the
    /// question plus the newest are sent, keeping their numbers so forget still works.
    func systemPrompt(for question: String) -> String {
        Self.systemPrompt(memories: memories, question: question)
    }

    nonisolated static func systemPrompt(memories: [Memory], question: String) -> String {
        var prompt = "You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets."
        let numbered = Array(memories.enumerated())
        guard !numbered.isEmpty else { return prompt + " You don't remember anything yet." }
        var shown = numbered
        if numbered.count > alwaysSent {
            let words = Self.words(question)
            let relevant = numbered
                .map { ($0, Self.words($0.element.text).intersection(words).count) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(20).map(\.0.offset)
            let keep = Set(relevant).union(numbered.suffix(10).map(\.offset))
            shown = numbered.filter { keep.contains($0.offset) }
        }
        prompt += " What you remember:\n" + shown.map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        if shown.count < numbered.count {
            prompt += "\n(\(numbered.count - shown.count) other memories aren't shown because they don't seem related to this message.)"
        }
        return prompt
    }

    /// Asks the model which facts from one exchange are worth keeping and saves them; returns the new ones.
    /// With `reply` nil (the reply read web pages or documents) only what the user wrote is used, so text planted
    /// there can't write itself into memory.
    func learn(question: String, reply: String?, api: BlabladorAPI, model: String) async throws -> [String] {
        let today = Date().formatted(date: .complete, time: .omitted)
        var system = """
        You keep the long-term memory of an assistant. From the exchange below, pick out what is worth remembering \
        in future conversations: facts the user stated about themselves, their work, projects, people, plans and \
        preferences, and decisions, results and conclusions about the topics discussed that they are likely to come \
        back to. Skip general knowledge, small talk, one-off requests and anything already remembered. Never include \
        passwords, keys or other secrets. Write each fact as one short sentence that makes sense on its own, naming \
        things explicitly and giving dates where they matter (today is \(today)). Reply with only a JSON array of \
        strings, or [] if there is nothing worth keeping.
        """
        let known = memories.suffix(60).map(\.text)
        if !known.isEmpty { system += "\n\nAlready remembered:\n" + known.map { "- " + $0 }.joined(separator: "\n") }
        var exchange = "User: " + question.prefix(8000)
        if let reply { exchange += "\n\nAssistant: " + reply.prefix(8000) }
        else { system += "\n\nOnly use what the user wrote." }

        let text = try await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: exchange)
        let answer = ChatStore.splitThinking(text).answer
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let facts = try? JSONDecoder().decode([String].self, from: Data(answer[start...end].utf8)) else { return [] }
        return facts.prefix(5).filter { add($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Lowercased words of three letters or more, for matching memories and chats to a question.
    nonisolated static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memories) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
    }

    private static var fileURL: URL {
        let url = AppFolder.url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("memories.json")
    }
}

enum MemoryTools {
    static let remember: [String: Any] = [
        "type": "function",
        "function": [
            "name": "remember",
            "description": "Save a lasting fact about the user to long-term memory, available in future chats.",
            "parameters": [
                "type": "object",
                "properties": [
                    "fact": ["type": "string", "description": "One short fact in the third person, e.g. \"Works as a chemist in Jülich.\""]
                ],
                "required": ["fact"]
            ]
        ]
    ]

    static let forget: [String: Any] = [
        "type": "function",
        "function": [
            "name": "forget",
            "description": "Delete a memory that is wrong or that the user wants forgotten.",
            "parameters": [
                "type": "object",
                "properties": [
                    "number": ["type": "integer", "description": "The memory's number in the list of what you remember."]
                ],
                "required": ["number"]
            ]
        ]
    ]
}

/// Keyword search over earlier chats, for the search_chats tool.
enum ChatSearch {
    static let maxResults = 6

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "search_chats",
            "description": "Search the user's earlier chats in this app, e.g. when they refer to something discussed before (\"what did we say about…\", \"like last time\").",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords to look for."]
                ],
                "required": ["query"]
            ]
        ]
    ]

    /// The best matching messages, with chat title, date and an excerpt around the first match.
    static func search(_ query: String, in conversations: [Conversation], excluding current: UUID?) -> String {
        let words = MemoryStore.words(query)
        guard !words.isEmpty else { return "No keywords to search for." }
        var hits: [(score: Int, conversation: Conversation, message: ChatMessage)] = []
        for conversation in conversations where conversation.id != current {
            for message in conversation.messages where !message.isError && !message.content.isEmpty {
                let score = MemoryStore.words(message.content).intersection(words).count
                    + MemoryStore.words(conversation.title).intersection(words).count
                if score > 0 { hits.append((score, conversation, message)) }
            }
        }
        let best = hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.message.date > $1.message.date }.prefix(maxResults)
        guard !best.isEmpty else { return "No earlier chats mention \"\(query)\"." }
        return best.map { hit in
            let who = hit.message.role == .user ? "User" : "Assistant"
            let date = hit.message.date.formatted(date: .abbreviated, time: .omitted)
            return "[\(hit.conversation.title), \(date)] \(who): \(excerpt(hit.message.content, around: words))"
        }.joined(separator: "\n\n")
    }

    private static func excerpt(_ text: String, around words: Set<String>) -> String {
        let lower = text.lowercased()
        let start = words.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? lower.startIndex
        let offset = max(0, lower.distance(from: lower.startIndex, to: start) - 200)
        let slice = text.dropFirst(offset).prefix(600)
        return (offset > 0 ? "…" : "") + slice + (slice.count == 600 ? "…" : "")
    }
}

/// Settings screen listing what the assistant remembers.
struct MemoryView: View {
    @ObservedObject private var memory = MemoryStore.shared
    @State private var newFact = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Use memory", isOn: $memory.enabled)
                Toggle("Learn from every chat", isOn: $memory.learnsAutomatically)
                    .disabled(!memory.enabled)
            } footer: {
                Text("The assistant remembers what's worth keeping from your chats, such as facts about you, your projects, decisions and conclusions, and uses it in every chat. With Learn from every chat off, it only saves what you ask it to remember. After each reply, the exchange is sent once more to the model to pick out what to remember. Memories are encrypted on this device and sent to the model with each message.")
            }

            Section("Memories") {
                if memory.memories.isEmpty {
                    Text("Nothing remembered yet.").foregroundStyle(.secondary)
                }
                ForEach(memory.memories) { item in
                    MemoryRow(memory: item)
                }
                .onDelete { offsets in
                    memory.delete(Set(offsets.map { memory.memories[$0].id }))
                }
                HStack {
                    TextField("Add a memory", text: $newFact)
                        .onSubmit(addFact)
                    Button("Add", action: addFact)
                        .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !memory.memories.isEmpty {
                Section {
                    Button("Forget everything", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory")
        .confirmationDialog("Forget all memories?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { memory.deleteAll() }
        }
    }

    private func addFact() {
        if memory.add(newFact) { newFact = "" }
    }
}

private struct MemoryRow: View {
    let memory: Memory
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Memory", text: $text, axis: .vertical)
                .onSubmit { save() }
                .onChange(of: text) { save() }
#if os(macOS)
            Button {
                MemoryStore.shared.delete([memory.id])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget")
#endif
        }
        .onAppear { text = memory.text }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != memory.text { MemoryStore.shared.update(memory, text: trimmed) }
    }
}
