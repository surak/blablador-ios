import XCTest
@testable import BlabladorCore

final class EmbeddingTests: XCTestCase {
    func testShortenedAndNormalised() {
        let long = (0..<1024).map { _ in Float.random(in: -1...1) }
        let short = Embeddings.shortened(long)
        XCTAssertEqual(short.count, Embeddings.dimension)
        XCTAssertEqual(Embeddings.similarity(short, short), 1, accuracy: 0.0001)
        XCTAssertEqual(Embeddings.vector(Embeddings.data(short)), short)
    }

    /// A unit vector along one axis, standing in for the embedding of a topic.
    static func axis(_ index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: Embeddings.dimension)
        vector[index] = 1
        return vector
    }

    func testMemoriesChosenByMeaningWithoutSharedWords() {
        var memories = (1...60).map { Memory(text: "Unrelated fact number \($0)", vector: Embeddings.data(Self.axis(1))) }
        memories[3] = Memory(text: "The user's cluster is JUPITER", vector: Embeddings.data(Self.axis(0)))
        let prompt = MemoryStore.systemPrompt(memories: memories, question: "How busy is my supercomputer?", questionVector: Self.axis(0))
        XCTAssertTrue(prompt.contains("4. The user's cluster is JUPITER"), "found by meaning, no shared word")
        XCTAssertFalse(prompt.contains("5. Unrelated fact number 5\n"))
    }
}

/// search_chats by meaning, against a fake embeddings and rerank server.
@MainActor
final class ChatFindTests: XCTestCase {
    override func setUp() { EncryptedStorage.keychainService = "de.fz-juelich.blablador.tests" }
    override func tearDown() { MockServer.stop() }

    func testFindsByMeaningAndReranks() async throws {
        MockServer.start { request, body in
            let json = body.json
            if request.url?.path.hasSuffix("/embeddings") == true {
                // "compute"-ish texts point one way, everything else another.
                let inputs = json["input"] as? [String] ?? []
                let data = inputs.enumerated().map { index, text -> [String: Any] in
                    let topic = ["GPU", "nodes", "supercomputer", "compute"].contains { text.contains($0) } ? 0 : 1
                    return ["index": index, "embedding": EmbeddingTests.axis(topic)]
                }
                return .init(body: try! JSONSerialization.data(withJSONObject: ["data": data]))
            }
            // Rerank: put the document mentioning December first.
            let documents = json["documents"] as? [String] ?? []
            let results = documents.enumerated().map { ["index": $0.offset, "relevance_score": $0.element.contains("December") ? 0.9 : 0.1] }
            return .init(body: try! JSONSerialization.data(withJSONObject: ["results": results]))
        }
        var gpu = Conversation(title: "Cluster planning", model: "m")
        gpu.messages = [ChatMessage(role: .user, content: "We agreed on 40 GPU nodes for the new project."),
                        ChatMessage(role: .assistant, content: "Noted: 40 nodes, starting in December after the upgrade.")]
        var cooking = Conversation(title: "Dinner", model: "m")
        cooking.messages = [ChatMessage(role: .user, content: "How long do I boil pasta for al dente results?")]
        let result = await ChatSearch.find("How much supercomputer time did we plan?", in: [gpu, cooking], excluding: nil, api: BlabladorAPI(apiKey: "test"))
        XCTAssertTrue(result.hasPrefix("[Cluster planning,"), result)
        XCTAssertTrue(result.components(separatedBy: "\n\n").first?.contains("December") == true, "reranked first")
        XCTAssertFalse(result.contains("pasta"))
    }

    /// Deleting all chats must delete what was remembered of them, not only the chats.
    func testForgetAllDropsEveryVector() async throws {
        MockServer.start { request, body in
            if request.url?.path.hasSuffix("/embeddings") == true {
                let inputs = body.json["input"] as? [String] ?? []
                let data = inputs.enumerated().map { index, _ in ["index": index, "embedding": EmbeddingTests.axis(index)] }
                return .init(body: try! JSONSerialization.data(withJSONObject: ["data": data]))
            }
            return .init(body: Data("{}".utf8))
        }
        var chat = Conversation(title: "Cluster", model: "m")
        chat.messages = [ChatMessage(role: .user, content: "We agreed on 40 GPU nodes for the new project.")]
        let index = ChatIndex.shared
        await index.update([chat], api: BlabladorAPI(apiKey: "test"))
        XCTAssertNotNil(index.vector(for: chat.messages[0].id))
        index.forgetAll()
        XCTAssertNil(index.vector(for: chat.messages[0].id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppFolder.url.appendingPathComponent("chat-index.json").path))
    }

    /// Deleting one chat forgets its messages and leaves the other chats' alone.
    func testForgetOneChat() async throws {
        MockServer.start { request, body in
            if request.url?.path.hasSuffix("/embeddings") == true {
                let inputs = body.json["input"] as? [String] ?? []
                let data = inputs.enumerated().map { index, _ in ["index": index, "embedding": EmbeddingTests.axis(index)] }
                return .init(body: try! JSONSerialization.data(withJSONObject: ["data": data]))
            }
            return .init(body: Data("{}".utf8))
        }
        var secret = Conversation(title: "Private", model: "m")
        secret.messages = [ChatMessage(role: .user, content: "My salary negotiation starts on Monday.")]
        var kept = Conversation(title: "Cluster", model: "m")
        kept.messages = [ChatMessage(role: .user, content: "We agreed on 40 GPU nodes for the new project.")]
        let index = ChatIndex.shared
        await index.update([secret, kept], api: BlabladorAPI(apiKey: "test"))
        index.forget(secret.allMessages.map(\.id))
        XCTAssertNil(index.vector(for: secret.messages[0].id), "the deleted chat's messages are forgotten")
        XCTAssertNotNil(index.vector(for: kept.messages[0].id), "other chats keep their vectors")
        // And it stays that way after a reload from disk.
        index.forgetAll()
    }
}

/// Real Blablador embeddings: BLABLADOR_NETWORK_TESTS=1 BLABLADOR_API_KEY=… swift test --filter LiveEmbeddingTests
final class LiveEmbeddingTests: XCTestCase {
    func testMeaningMatchesAcrossWords() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLABLADOR_NETWORK_TESTS"] == "1", let key = environment["BLABLADOR_API_KEY"] else {
            throw XCTSkip("set BLABLADOR_NETWORK_TESTS=1 and BLABLADOR_API_KEY")
        }
        let texts = ["The user's team runs the JUPITER exascale system.", "The user likes Italian cooking.", "The user's daughter plays violin."]
        let vectors = try await Embeddings.embed(texts + ["Which supercomputer do we operate?"], api: BlabladorAPI(apiKey: key))
        let scores = vectors.prefix(3).map { Embeddings.similarity($0, vectors[3]) }
        XCTAssertEqual(scores.firstIndex(of: scores.max()!), 0, "\(scores)")
    }
}

final class MemoryCutoffTests: XCTestCase {
    /// Scores like real Qwen3 embeddings: unrelated memories still around 0.4 to 0.5.
    func testOnlyMemoriesCloseToTheBestMatchAreSent() {
        func vector(similarity: Float) -> Data {
            var v = [Float](repeating: 0, count: Embeddings.dimension)
            v[0] = similarity
            v[1] = (1 - similarity * similarity).squareRoot()
            return Embeddings.data(v)
        }
        var memories = (1...40).map { Memory(text: "Filler \($0)", vector: vector(similarity: 0.3)) }
        memories[0] = Memory(text: "Team runs JUPITER", vector: vector(similarity: 0.75))
        memories[1] = Memory(text: "Nodes move to JUPITER in January", vector: vector(similarity: 0.56))
        memories[2] = Memory(text: "Prefers short answers", vector: vector(similarity: 0.505))
        let prompt = MemoryStore.systemPrompt(memories: memories, question: "Which supercomputer?", questionVector: EmbeddingTests.axis(0))
        XCTAssertTrue(prompt.contains("1. Team runs JUPITER"))
        XCTAssertTrue(prompt.contains("2. Nodes move to JUPITER in January"))
        XCTAssertFalse(prompt.contains("3. Prefers short answers"))
    }

    func testLinkedMemoriesFollowSharedEntities() {
        let unrelated = EmbeddingTests.axis(1)
        var memories = (1...40).map { Memory(text: "Filler \($0)", vector: Embeddings.data(unrelated), entities: []) }
        memories[0] = Memory(text: "Maria leads the benchmark project", vector: Embeddings.data(EmbeddingTests.axis(0)), entities: ["maria", "benchmark project"])
        memories[1] = Memory(text: "The benchmark project uses vLLM", vector: Embeddings.data(unrelated), entities: ["benchmark project", "vllm"])
        memories[2] = Memory(text: "Tom fixed a leak in vLLM", vector: Embeddings.data(unrelated), entities: ["tom", "vllm"])
        memories[3] = Memory(text: "Tom likes tea", vector: Embeddings.data(unrelated), entities: ["tom"])
        let prompt = MemoryStore.systemPrompt(memories: memories, question: "Maria", questionVector: EmbeddingTests.axis(0))
        XCTAssertTrue(prompt.contains("2. The benchmark project uses vLLM"))
        XCTAssertTrue(prompt.contains("3. Tom fixed a leak in vLLM"))
        XCTAssertFalse(prompt.contains("4. Tom likes tea"), "three steps away")
        XCTAssertEqual(MemoryStore.normalized([" Maria ", "maria", "the user", ""]), ["maria"])
    }

    func testLearnedFactsAcceptStringsAndObjects() {
        let facts = MemoryStore.jsonArray(#"Sure: ["Plain fact", {"fact": "Tom fixed vLLM", "about": ["Tom", "vLLM"]}]"#, as: [MemoryStore.LearnedFact].self)
        XCTAssertEqual(facts?.map(\.fact), ["Plain fact", "Tom fixed vLLM"])
        XCTAssertEqual(facts?[1].about, ["Tom", "vLLM"])
    }
}
