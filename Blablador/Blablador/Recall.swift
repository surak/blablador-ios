import Accelerate
import Foundation

/// Text embeddings for finding memories and earlier chats by meaning. Vectors are cut to their first 512
/// dimensions (Qwen3 embeddings keep most of their quality when shortened) and normalised, so a dot product is
/// the cosine similarity.
enum Embeddings {
    static let dimension = 512
    private static let batchSize = 32

    /// Only Blablador is known to offer the embedding model; other endpoints fall back to keywords.
    static var available: Bool {
        BlabladorAPI.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == BlabladorAPI.defaultEndpoint
    }

    static func embed(_ texts: [String], api: BlabladorAPI) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: batchSize) {
            let batch = texts[start..<min(start + batchSize, texts.count)].map { String($0.prefix(2_000)) }
            vectors += try await api.embeddings(batch).map(shortened)
        }
        return vectors
    }

    static func shortened(_ vector: [Float]) -> [Float] {
        var short = Array(vector.prefix(dimension))
        var norm: Float = 0
        vDSP_svesq(short, 1, &norm, vDSP_Length(short.count))
        norm = norm.squareRoot()
        if norm > 0 { vDSP_vsdiv(short, 1, &norm, &short, 1, vDSP_Length(short.count)) }
        return short
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    static func data(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Embeddings of earlier chat messages, kept encrypted and filled in the background after replies.
@MainActor
final class ChatIndex {
    static let shared = ChatIndex()
    /// Messages embedded per update, so a long history is filled in over several replies.
    private static let perUpdate = 256

    private var vectors: [UUID: [Float]]?
    private var updating = false

    private static var fileURL: URL { AppFolder.url.appendingPathComponent("chat-index.json") }

    private func load() -> [UUID: [Float]] {
        if let vectors { return vectors }
        var loaded: [UUID: [Float]] = [:]
        if let data = EncryptedStorage.read(Self.fileURL),
           let stored = try? JSONDecoder().decode([UUID: Data].self, from: data) {
            loaded = stored.mapValues(Embeddings.vector)
        }
        vectors = loaded
        return loaded
    }

    private func save() {
        guard let vectors, let data = try? JSONEncoder().encode(vectors.mapValues(Embeddings.data)) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
    }

    static func indexable(_ message: ChatMessage) -> Bool {
        !message.isError && message.role != .system && message.content.count >= 20
    }

    /// Embeds messages not indexed yet and forgets deleted ones.
    func update(_ conversations: [Conversation], api: BlabladorAPI) async {
        guard Embeddings.available, !updating else { return }
        updating = true
        defer { updating = false }
        var vectors = load()
        let messages = conversations.flatMap(\.messages).filter(Self.indexable)
        let present = Set(messages.map(\.id))
        let removed = vectors.keys.filter { !present.contains($0) }
        removed.forEach { vectors.removeValue(forKey: $0) }
        let missing = Array(messages.filter { vectors[$0.id] == nil }.suffix(Self.perUpdate))
        if !missing.isEmpty, let embedded = try? await Embeddings.embed(missing.map(\.content), api: api) {
            for (message, vector) in zip(missing, embedded) { vectors[message.id] = vector }
        }
        if !missing.isEmpty || !removed.isEmpty {
            self.vectors = vectors
            save()
        }
    }

    func vector(for id: UUID) -> [Float]? { load()[id] }
}

extension ChatSearch {
    /// Finds earlier messages by meaning and keywords, reranked; falls back to keywords without embeddings.
    @MainActor
    static func find(_ query: String, in conversations: [Conversation], excluding current: UUID?, api: BlabladorAPI) async -> String {
        guard Embeddings.available, let queryVector = try? await Embeddings.embed([query], api: api).first else {
            return search(query, in: conversations, excluding: current)
        }
        await ChatIndex.shared.update(conversations, api: api)
        let words = MemoryStore.words(query)
        var candidates: [(score: Float, conversation: Conversation, message: ChatMessage)] = []
        for conversation in conversations where conversation.id != current {
            for message in conversation.messages where ChatIndex.indexable(message) {
                let vector = ChatIndex.shared.vector(for: message.id)
                let meaning = vector.map { Embeddings.similarity($0, queryVector) } ?? 0
                let keywords = Float(MemoryStore.words(message.content).intersection(words).count)
                // One shared common word ("how", "the") isn't enough when the message's meaning is known.
                // Unrelated texts still score 0.3 to 0.5; the reranker orders what's left.
                let matches = vector == nil ? keywords > 0 : meaning > 0.5 || keywords >= 2
                if matches { candidates.append((meaning + 0.05 * keywords, conversation, message)) }
            }
        }
        var best = Array(candidates.sorted { $0.score > $1.score }.prefix(20))
        guard !best.isEmpty else { return "No earlier chats mention \"\(query)\"." }
        if best.count > 1, let order = try? await api.rerank(query: query, documents: best.map { String($0.message.content.prefix(1_500)) }) {
            best = order.compactMap { best.indices.contains($0) ? best[$0] : nil }
        }
        return best.prefix(maxResults).map { hit in
            let who = hit.message.role == .user ? "User" : "Assistant"
            let date = hit.message.date.formatted(date: .abbreviated, time: .omitted)
            return "[\(hit.conversation.title), \(date)] \(who): \(String(hit.message.content.prefix(600)))"
        }.joined(separator: "\n\n")
    }
}
