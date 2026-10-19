import Accelerate
import Foundation

/// A document indexed in a knowledge base.
struct KnowledgeDocument: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var pageCount: Int
    var ocrPageCount = 0
    var chunkCount = 0
    var addedAt = Date()
}

/// A named collection of documents that chats can search, like Open WebUI's knowledge.
struct KnowledgeBase: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var documents: [KnowledgeDocument] = []
    var embeddingModel = BlabladorAPI.embeddingModel
    var createdAt = Date()
}

/// An excerpt used to answer, shown under the reply.
struct KnowledgeCitation: Codable, Hashable {
    var document: String
    var page: Int?
    var text: String
}

/// A passage of a document with its embedding position in the vector file.
private struct Chunk: Codable {
    var document: UUID
    var page: Int?
    var text: String
}

@MainActor
final class KnowledgeLibrary: ObservableObject {
    static let shared = KnowledgeLibrary()

    @Published private(set) var bases: [KnowledgeBase] = []
    /// Indexing progress per base, e.g. "report.pdf · 3/12".
    @Published private(set) var progress: [UUID: String] = [:]
    @Published var lastError: String?

    /// Passages retrieved per question, before and after re-ranking.
    static let candidateCount = 24
    static let resultCount = 6
    static let chunkLength = 1_200
    static let chunkOverlap = 200

    private var cache: [UUID: (chunks: [Chunk], vectors: [Float], dimension: Int)] = [:]

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let bases = try? JSONDecoder().decode([KnowledgeBase].self, from: data) {
            self.bases = bases
        }
    }

    func base(_ id: UUID) -> KnowledgeBase? { bases.first { $0.id == id } }

    @discardableResult
    func create(name: String) -> KnowledgeBase {
        let base = KnowledgeBase(name: name)
        bases.append(base)
        persist()
        return base
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = bases.firstIndex(where: { $0.id == id }) else { return }
        bases[index].name = name
        persist()
    }

    func delete(_ id: UUID) {
        bases.removeAll { $0.id == id }
        cache[id] = nil
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        persist()
    }

    func remove(_ document: KnowledgeDocument, from baseID: UUID) {
        guard let index = bases.firstIndex(where: { $0.id == baseID }) else { return }
        var store = load(baseID)
        let dimension = store.dimension
        var chunks: [Chunk] = [], vectors: [Float] = []
        for (position, chunk) in store.chunks.enumerated() where chunk.document != document.id {
            chunks.append(chunk)
            vectors += store.vectors[position * dimension ..< (position + 1) * dimension]
        }
        store = (chunks, vectors, dimension)
        save(store, for: baseID)
        bases[index].documents.removeAll { $0.id == document.id }
        persist()
    }

    // MARK: - Indexing

    /// Extracts, chunks and embeds files one after another.
    func add(_ urls: [URL], to baseID: UUID, api: BlabladorAPI) {
        Task {
            for (number, url) in urls.enumerated() {
                let label = urls.count > 1 ? "\(url.lastPathComponent) · \(number + 1)/\(urls.count)" : url.lastPathComponent
                progress[baseID] = "Reading \(label)…"
                do {
                    try await index(url, into: baseID, api: api, label: label)
                } catch {
                    lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            progress[baseID] = nil
        }
    }

    private func index(_ url: URL, into baseID: UUID, api: BlabladorAPI, label: String) async throws {
        let pages: [(page: Int?, text: String)]
        var document: KnowledgeDocument
        if url.pathExtension.lowercased() == "pdf" {
            let extracted = try await PDFExtractor.extract(from: url)
            pages = Self.pages(of: extracted.text)
            document = KnowledgeDocument(name: extracted.name, pageCount: extracted.pageCount, ocrPageCount: extracted.ocrPageCount)
        } else {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            pages = [(nil, text)]
            document = KnowledgeDocument(name: url.lastPathComponent, pageCount: 1)
        }

        let chunks = pages.flatMap { page in Self.split(page.text).map { Chunk(document: document.id, page: page.page, text: $0) } }
        guard !chunks.isEmpty else { throw PDFExtractor.ExtractionError.empty }
        let model = base(baseID)?.embeddingModel ?? BlabladorAPI.embeddingModel

        var vectors: [Float] = []
        var dimension = 0
        let batch = 4
        for start in stride(from: 0, to: chunks.count, by: batch) {
            progress[baseID] = "Indexing \(label) · \(Int(Double(start) / Double(chunks.count) * 100))%"
            let texts = chunks[start ..< min(start + batch, chunks.count)].map { "\(document.name)\n\($0.text)" }
            let embeddings = try await Self.embed(texts, model: model, api: api)
            for embedding in embeddings {
                dimension = embedding.count
                vectors += Self.normalized(embedding)
            }
        }

        var store = load(baseID)
        if store.dimension != 0 && store.dimension != dimension {
            throw BlabladorAPIError.http(status: 0, body: "Embedding size changed; create a new knowledge base.")
        }
        store.chunks += chunks
        store.vectors += vectors
        store.dimension = dimension
        save(store, for: baseID)

        document.chunkCount = chunks.count
        if let index = bases.firstIndex(where: { $0.id == baseID }) {
            bases[index].documents.append(document)
            persist()
        }
    }

    /// Undoes PDFExtractor's "[Page n]" markers.
    private static func pages(of text: String) -> [(page: Int?, text: String)] {
        let pattern = try! NSRegularExpression(pattern: #"^\[Page (\d+)\]\n"#, options: .anchorsMatchLines)
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [(nil, text)] }
        return matches.enumerated().map { index, match in
            let start = match.range.upperBound
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return (Int(ns.substring(with: match.range(at: 1))), ns.substring(with: NSRange(location: start, length: end - start)))
        }
    }

    /// Splits text into overlapping chunks, preferring paragraph and sentence boundaries.
    static func split(_ text: String) -> [String] {
        let clean = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var chunks: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex {
            var end = clean.index(start, offsetBy: chunkLength, limitedBy: clean.endIndex) ?? clean.endIndex
            if end < clean.endIndex {
                let window = clean[clean.index(start, offsetBy: chunkLength / 2) ..< end]
                if let cut = window.range(of: "\n\n", options: .backwards) ?? window.range(of: ". ", options: .backwards)
                    ?? window.range(of: "\n", options: .backwards) {
                    end = cut.upperBound
                }
            }
            let chunk = clean[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            if chunk.count > 20 { chunks.append(chunk) }
            guard end < clean.endIndex else { break }
            let next = clean.index(end, offsetBy: -chunkOverlap, limitedBy: start) ?? start
            start = next > start ? next : end
        }
        return chunks
    }

    // MARK: - Retrieval

    /// Finds the passages most relevant to `query` across the given bases.
    func search(_ query: String, in baseIDs: [UUID], api: BlabladorAPI) async throws -> [KnowledgeCitation] {
        var candidates: [(score: Float, citation: KnowledgeCitation)] = []
        for (model, ids) in Dictionary(grouping: baseIDs.compactMap(base), by: \.embeddingModel) {
            // Qwen3 embeddings expect an instruction on the query side only.
            let instruction = "Instruct: Given a question, retrieve passages from documents that answer it\nQuery: \(query)"
            guard let embedding = try await Self.retrying({ try await api.embeddings([instruction], model: model) }).first else { continue }
            let vector = Self.normalized(embedding)
            for base in ids {
                let store = load(base.id)
                guard store.dimension == vector.count, !store.chunks.isEmpty else { continue }
                let names = Dictionary(uniqueKeysWithValues: base.documents.map { ($0.id, $0.name) })
                var scores = [Float](repeating: 0, count: store.chunks.count)
                // Vectors are normalized, so a matrix-vector product gives cosine similarity.
                vDSP_mmul(store.vectors, 1, vector, 1, &scores, 1, vDSP_Length(store.chunks.count), 1, vDSP_Length(store.dimension))
                for (position, score) in scores.enumerated() {
                    let chunk = store.chunks[position]
                    candidates.append((score, KnowledgeCitation(document: names[chunk.document] ?? "Document", page: chunk.page, text: chunk.text)))
                }
            }
        }
        let top = candidates.sorted { $0.score > $1.score }.prefix(Self.candidateCount).map(\.citation)
        guard top.count > Self.resultCount else { return top }
        do {
            let order = try await Self.retrying { try await api.rerank(query: query, documents: top.map(\.text)) }
            return order.prefix(Self.resultCount).map { top[$0] }
        } catch {
            return Array(top.prefix(Self.resultCount))
        }
    }

    /// Context block for the system prompt, numbered [K1], [K2]… to match the citations.
    static func context(for citations: [KnowledgeCitation]) -> String {
        let passages = citations.enumerated().map { index, citation in
            let page = citation.page.map { ", page \($0)" } ?? ""
            return "[K\(index + 1)] \(citation.document)\(page):\n\(citation.text)"
        }
        return """
        Excerpts from the user's knowledge base that may be relevant to the latest message. \
        Use them to answer and cite them inline as [K1], [K2]. If they don't contain the answer, say so instead of guessing.

        \(passages.joined(separator: "\n\n"))
        """
    }

    // MARK: - Storage

    private static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Blablador answers 500 when a request carries too many tokens, so halve the batch until it fits.
    private static func embed(_ texts: [String], model: String, api: BlabladorAPI) async throws -> [[Float]] {
        do {
            return try await retrying { try await api.embeddings(texts, model: model) }
        } catch BlabladorAPIError.http(let status, _) where status >= 500 && texts.count > 1 {
            let middle = texts.count / 2
            return try await embed(Array(texts[..<middle]), model: model, api: api)
                + embed(Array(texts[middle...]), model: model, api: api)
        }
    }

    /// The network is flaky; retry API calls a few times.
    private static func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                if attempt >= 3 || error is CancellationError { throw error }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    private func load(_ id: UUID) -> (chunks: [Chunk], vectors: [Float], dimension: Int) {
        if let cached = cache[id] { return cached }
        let directory = Self.directory(for: id)
        let chunks = (try? Data(contentsOf: directory.appendingPathComponent("chunks.json")))
            .flatMap { try? JSONDecoder().decode([Chunk].self, from: $0) } ?? []
        let data = (try? Data(contentsOf: directory.appendingPathComponent("vectors.bin"))) ?? Data()
        let vectors = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let store = (chunks, vectors, chunks.isEmpty ? 0 : vectors.count / chunks.count)
        cache[id] = store
        return store
    }

    private func save(_ store: (chunks: [Chunk], vectors: [Float], dimension: Int), for id: UUID) {
        cache[id] = store
        let directory = Self.directory(for: id)
        try? JSONEncoder().encode(store.chunks).write(to: directory.appendingPathComponent("chunks.json"), options: .atomic)
        let data = store.vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: directory.appendingPathComponent("vectors.bin"), options: .atomic)
    }

    private func persist() {
        try? JSONEncoder().encode(bases).write(to: Self.indexURL, options: .atomic)
    }

    private static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var indexURL: URL { root.appendingPathComponent("bases.json") }

    private static func directory(for id: UUID) -> URL {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
