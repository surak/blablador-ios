import SwiftUI

/// Something the assistant remembers about the user across chats.
struct Memory: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
    /// Embedding of the text (see Embeddings), for finding the memories that matter to a question.
    var vector: Data?
    /// The chat the memory was saved in.
    var sourceChat: UUID?
    var sourceTitle: String?
    /// People, projects, places, tools and other named things the fact is about, lowercased. Memories sharing
    /// one are linked, so recall can follow a chain of facts. nil until the helper model has named them.
    var entities: [String]?
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
    func add(_ text: String, from chat: Conversation? = nil, entities: [String]? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !memories.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return false }
        memories.append(Memory(text: text, sourceChat: chat?.id, sourceTitle: chat?.title, entities: entities.map(Self.normalized)))
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        persist()
        return true
    }

    func update(_ memory: Memory, text: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[index].text = text
        memories[index].vector = nil
        memories[index].entities = nil
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

    /// Like `systemPrompt(for:)`, but with many memories picks the relevant ones by meaning when embeddings are available.
    func systemPrompt(for question: String, api: BlabladorAPI) async -> String {
        guard memories.count > Self.alwaysSent, Embeddings.available else { return systemPrompt(for: question) }
        await embedMissing(api: api)
        await linkMissing(api: api)
        let questionVector = try? await Embeddings.embed([question], api: api).first
        return Self.systemPrompt(memories: memories, question: question, questionVector: questionVector)
    }

    /// Embeds memories saved without a vector (new, edited, or from before 3.1).
    func embedMissing(api: BlabladorAPI) async {
        let missing = memories.filter { $0.vector == nil }
        guard Embeddings.available, !missing.isEmpty,
              let vectors = try? await Embeddings.embed(missing.map(\.text), api: api) else { return }
        for (memory, vector) in zip(missing, vectors) {
            if let index = memories.firstIndex(where: { $0.id == memory.id && $0.text == memory.text }) {
                memories[index].vector = Embeddings.data(vector)
            }
        }
        persist()
    }

    nonisolated static func systemPrompt(memories: [Memory], question: String, questionVector: [Float]? = nil) -> String {
        var prompt = "You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets."
        let numbered = Array(memories.enumerated())
        guard !numbered.isEmpty else { return prompt + " You don't remember anything yet." }
        var shown = numbered
        if numbered.count > alwaysSent {
            let words = Self.words(question)
            // Meaning (when embedded) plus a little for shared words; keywords alone otherwise. Unrelated texts
            // still score 0.3 to 0.5 with Qwen3 embeddings, so only those close to the best match count.
            let meanings = numbered.map { item in
                questionVector.flatMap { question in item.element.vector.map { Embeddings.similarity(Embeddings.vector($0), question) } }
            }
            let cutoff = max(0.5, (meanings.compactMap { $0 }.max() ?? 0) - 0.2)
            let relevant = numbered
                .map { item -> (offset: Int, score: Float) in
                    let keywords = Float(Self.words(item.element.text).intersection(words).count)
                    guard let meaning = meanings[item.offset] else { return (item.offset, keywords) }
                    return (item.offset, meaning >= cutoff || keywords >= 2 ? meaning + 0.05 * keywords : 0)
                }
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .prefix(20).map(\.offset)
            let linked = Self.linked(to: relevant, in: memories, limit: 10)
            let keep = Set(relevant).union(linked).union(numbered.suffix(10).map(\.offset))
            shown = numbered.filter { keep.contains($0.offset) }
        }
        prompt += " What you remember:\n" + shown.map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        if shown.count < numbered.count {
            prompt += "\n(\(numbered.count - shown.count) other memories aren't shown because they don't seem related to this message.)"
        }
        return prompt
    }

    /// Memories reached from `start` (indices) through shared entities, up to two steps away, nearest first.
    /// "Maria leads the benchmark project" leads to "The benchmark project uses vLLM" and on to "Tom fixed vLLM".
    nonisolated static func linked(to start: [Int], in memories: [Memory], limit: Int) -> [Int] {
        var byEntity: [String: [Int]] = [:]
        for (index, memory) in memories.enumerated() {
            for entity in memory.entities ?? [] { byEntity[entity, default: []].append(index) }
        }
        // Entities on most memories (usually the user) link everything to everything; leave them out.
        let common = max(5, memories.count / 10)
        var seen = Set(start), frontier = start, found: [Int] = []
        for _ in 0..<2 {
            var next: [Int] = []
            for index in frontier {
                for entity in memories[index].entities ?? [] {
                    guard let others = byEntity[entity], others.count <= common else { continue }
                    for other in others.reversed() where seen.insert(other).inserted { next.append(other) }
                }
            }
            found += next
            frontier = next
        }
        return Array(found.prefix(limit))
    }

    nonisolated static func normalized(_ entities: [String]) -> [String] {
        var seen = Set<String>()
        return entities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !["user", "the user", "assistant"].contains($0) && seen.insert($0).inserted }
    }

    /// Names the entities of memories saved without them (remember tool, edits, before 3.2), 40 at a time.
    func linkMissing(api: BlabladorAPI) async {
        let missing = Array(memories.filter { $0.entities == nil }.prefix(40))
        guard !missing.isEmpty else { return }
        let system = """
        For each numbered fact, list the people, organisations, projects, places, products, tools and other specific \
        things it is about, by their usual name (not "the user"). Reply with only a JSON array with one array of \
        strings per fact, in order, e.g. [["Maria", "JUWELS"], []].
        """
        let list = missing.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        guard let text = try? await api.complete(model: BlabladorAPI.helperModel(else: BlabladorAPI.defaultModel), system: system, user: list),
              let lists = Self.jsonArray(ChatStore.splitThinking(text).answer, as: [[String]].self),
              lists.count == missing.count else { return }
        for (memory, entities) in zip(missing, lists) {
            if let index = memories.firstIndex(where: { $0.id == memory.id && $0.text == memory.text }) {
                memories[index].entities = Self.normalized(entities)
            }
        }
        persist()
    }

    /// The outermost JSON array in a model's answer.
    nonisolated static func jsonArray<T: Decodable>(_ answer: String, as type: T.Type) -> T? {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end else { return nil }
        return try? JSONDecoder().decode(type, from: Data(answer[start...end].utf8))
    }

    /// A fact from `learn`: a plain string or {"fact": …, "about": […]}.
    struct LearnedFact: Decodable {
        var fact: String
        var about: [String]?

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                fact = text
            } else {
                let object = try decoder.container(keyedBy: CodingKeys.self)
                fact = try object.decode(String.self, forKey: .fact)
                about = try object.decodeIfPresent([String].self, forKey: .about)
            }
        }
        private enum CodingKeys: String, CodingKey { case fact, about }
    }

    /// Asks the model which facts from one exchange are worth keeping and saves them; returns the new ones.
    /// With `reply` nil (the reply read web pages or documents) only what the user wrote is used, so text planted
    /// there can't write itself into memory.
    func learn(question: String, reply: String?, api: BlabladorAPI, model: String, from chat: Conversation? = nil) async throws -> [String] {
        let today = Date().formatted(date: .complete, time: .omitted)
        var system = """
        You keep the long-term memory of an assistant. From the exchange below, pick out what is worth remembering \
        in future conversations: facts the user stated about themselves, their work, projects, people, plans and \
        preferences, and decisions, results and conclusions about the topics discussed that they are likely to come \
        back to. Skip general knowledge, small talk, one-off requests and anything already remembered. Never include \
        passwords, keys or other secrets. Write each fact as one short sentence that makes sense on its own, naming \
        things explicitly and giving dates where they matter (today is \(today)). Reply with only a JSON array of \
        objects like {"fact": "Maria leads the JUWELS benchmark project.", "about": ["Maria", "JUWELS benchmark \
        project"]}, where "about" lists the people, projects, places, tools and other specific things the fact is \
        about, by their usual name and spelled the same way as in earlier facts; or [] if there is nothing worth keeping.
        """
        let known = memories.suffix(60).map(\.text)
        if !known.isEmpty { system += "\n\nAlready remembered:\n" + known.map { "- " + $0 }.joined(separator: "\n") }
        let names = Set(memories.flatMap { $0.entities ?? [] }).sorted().prefix(150)
        if !names.isEmpty { system += "\n\nNames used so far: " + names.joined(separator: ", ") }
        var exchange = "User: " + question.prefix(8000)
        if let reply { exchange += "\n\nAssistant: " + reply.prefix(8000) }
        else { system += "\n\nOnly use what the user wrote." }

        let text = try await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: exchange)
        let answer = ChatStore.splitThinking(text).answer
        guard let facts = Self.jsonArray(answer, as: [LearnedFact].self) else { return [] }
        let added = facts.prefix(5).filter { add($0.fact, from: chat, entities: $0.about) }.map { $0.fact.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !added.isEmpty {
            await embedMissing(api: api)
            await linkMissing(api: api)
        }
        return added
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
    /// Opens the chat a memory was saved in; nil when that isn't possible here.
    var onOpenChat: ((UUID) -> Void)?
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
                    MemoryRow(memory: item, onOpenChat: onOpenChat)
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
    var onOpenChat: ((UUID) -> Void)?
    @State private var text = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Memory", text: $text, axis: .vertical)
                    .onSubmit { save() }
                    .onChange(of: text) { save() }
                source
            }
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

    /// Where the memory came from: a link to its chat, or the date it was added.
    @ViewBuilder
    private var source: some View {
        let date = memory.date.formatted(date: .abbreviated, time: .omitted)
        if let chat = memory.sourceChat, let title = memory.sourceTitle, let onOpenChat {
            Button { onOpenChat(chat) } label: {
                Label("\(title) · \(date)", systemImage: "bubble.left")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(memory.sourceTitle.map { "\($0) · \(date)" } ?? "Added \(date)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
