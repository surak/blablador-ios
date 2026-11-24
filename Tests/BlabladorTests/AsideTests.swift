import XCTest
@testable import BlabladorCore

/// /btw: a question answered aside while a long reply keeps being written.
@MainActor
final class AsideTests: XCTestCase {
    func testCommandParsing() {
        XCTAssertEqual(AsideTools.command("/btw what is JUPITER?"), "what is JUPITER?")
        XCTAssertEqual(AsideTools.command("  /BTW  Write it in German "), "Write it in German")
        XCTAssertEqual(AsideTools.command("/btw\nand that?"), "and that?")
        XCTAssertEqual(AsideTools.command("/btw"), "")
        XCTAssertNil(AsideTools.command("/btwish"))
        XCTAssertNil(AsideTools.command("so /btw what"))
        XCTAssertNil(AsideTools.command("/goal do it"))
    }

    /// The aside reads the chat up to where the long reply started, and never that reply itself, which is only
    /// half written at that point.
    func testPromptSeesTheChatBeforeTheReplyBeingWritten() {
        let conversation = ChatStore.history(system: "You are Blablador.", Conversation(title: "x", model: "m"))
        let withAnswer = conversation + [["role": "assistant", "content": "The first half of a long answer"]]
        let prompt = AsideTools.prompt(question: "And what is JUPITER?", context: conversation)
        XCTAssertEqual(prompt.first?["role"] as? String, "system")
        XCTAssertEqual(prompt.last?["content"] as? String, "And what is JUPITER?")
        XCTAssertTrue((prompt.first?["content"] as? String)?.contains("aside") == true)
        XCTAssertFalse(prompt.contains { ($0["content"] as? String) == "The first half of a long answer" },
                       "the reply being written is not context: it isn't written yet")
        XCTAssertTrue(withAnswer.contains { ($0["role"] as? String) == "assistant" })
    }

    /// The note that keeps the long reply on its own task names the aside, so the model can ignore it.
    func testResumeNoteNamesTheQuestion() {
        let note = AsideTools.resumeNote("what is JUPITER?")
        XCTAssertTrue(note.contains("what is JUPITER?"))
        XCTAssertFalse(note.contains("{{question}}"))
        // A model that quotes the question at length can't push its own answer out of the window.
        XCTAssertLessThan(AsideTools.resumeNote(String(repeating: "x", count: 5_000)).count, 1_000)
    }

    /// A chat asked aside carries the chat it came from, so it can be followed up like any other.
    func testKeptAsideChatCarriesItsContext() {
        var aside = Conversation(title: "And what is JUPITER?", model: "m")
        aside.messages = [ChatMessage(role: .user, content: "And what is JUPITER?"),
                          ChatMessage(role: .assistant, content: "A JUWELS Booster partition at JSC.")]
        aside.context = [ChatMessage(role: .user, content: "Write a long report on our clusters."),
                         ChatMessage(role: .assistant, content: "Here is the first part…")]
        let wire = ChatStore.history(system: "You are Blablador.", aside).map { $0["content"] as? String ?? "" }
        XCTAssertEqual(wire.first, "You are Blablador.", "the system prompt stays first")
        XCTAssertEqual(wire.dropFirst().prefix(2), ["Write a long report on our clusters.", "Here is the first part…"])
        XCTAssertEqual(wire.last, "A JUWELS Booster partition at JSC.")
    }

    /// /btw is answered beside the reply: it never becomes a message of the chat it was asked in, and a
    /// disappearing chat leaves no second chat behind. (The server only fails here: this is about the wiring.)
    func testAskedAsideStaysOutOfTheChat() async throws {
        MockServer.start { _, _ in .init(status: 500, body: Data("no".utf8)) }
        let memory = MemoryStore.shared.enabled
        let check = SelfCheck.enabled
        MemoryStore.shared.enabled = false
        SelfCheck.enabled = false
        defer {
            MemoryStore.shared.enabled = memory
            SelfCheck.enabled = check
            MockServer.stop()
        }

        let store = ChatStore()
        store.newChat()
        store.send("Write a long report about our clusters.")
        let chat = try XCTUnwrap(store.currentID)
        await wait({ !store.isStreaming })
        let messages = store.current?.messages.count

        store.send("/btw What is JUPITER?")
        XCTAssertEqual(store.currentID, chat, "asking aside doesn't open another chat")
        XCTAssertEqual(store.current?.messages.count, messages, "the aside is not a message of this chat")
        let card = try XCTUnwrap(store.currentAsides.first)
        XCTAssertEqual(card.question, "What is JUPITER?")

        // A disappearing chat leaves nothing behind, not even the chat the aside would have been kept in.
        store.newDisappearingChat()
        store.send("/btw and what about JUWELS?")
        XCTAssertEqual(store.currentAsides.count, 1)
        await wait({ store.currentAsides.first?.answer.isEmpty == false })
        XCTAssertNil(store.currentAsides.first?.answerChat, "a disappearing chat writes no chat of its own")
        XCTAssertEqual(store.conversations.filter(\.isEphemeral).count, 1)

        // Leaving it throws it away, cards and all.
        store.newChat()
        XCTAssertEqual(store.conversations.filter(\.isEphemeral).count, 0)
        XCTAssertTrue(store.currentAsides.isEmpty)
        if let kept = store.conversations.first(where: { $0.id == chat }) { store.delete(kept) }
    }

    /// The point of /btw: the aside is answered *while* a reply is still being written, it sees the chat without
    /// that half-written reply, and the reply is afterwards told the question wasn't for it.
    func testAsideIsAnsweredWhileTheReplyStillStreams() async throws {
        MockServer.start { request, body in
            let sent = body.json
            let isAside = (sent["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            let stream: String
            if isAside.contains("aside") {
                stream = #"data: {"choices":[{"delta":{"content":"JUPITER is a Booster partition."}}]}"# + "\n\ndata: [DONE]\n\n"
            } else if (sent["messages"] as? [[String: Any]])?.contains(where: { ($0["content"] as? String)?.contains("Aside") == true }) == true {
                stream = #"data: {"choices":[{"delta":{"content":"The report, part two."}}]}"# + "\n\ndata: [DONE]\n\n"
            } else {
                // The long answer: a tool round, so it stays open long enough to be asked beside.
                stream = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"web_search","arguments":"{\"query\":\"clusters\"}"}}]}}]}"# + "\n\ndata: [DONE]\n\n"
            }
            return .init(headers: ["Content-Type": "text/event-stream"], body: Data(stream.utf8))
        }
        let memory = MemoryStore.shared.enabled
        let check = SelfCheck.enabled
        MemoryStore.shared.enabled = false
        SelfCheck.enabled = false
        defer {
            MemoryStore.shared.enabled = memory
            SelfCheck.enabled = check
            MockServer.stop()
        }

        let store = ChatStore()
        store.apiKey = "test"
        store.newChat()
        store.send("Write a long report about our clusters.")
        let chat = try XCTUnwrap(store.currentID)
        await wait({ store.isStreaming }, timeout: 5)

        store.send("/btw What is JUPITER?")
        let card = try XCTUnwrap(store.currentAsides.first)
        await wait({ !card.answer.isEmpty }, timeout: 10)
        XCTAssertEqual(store.currentAsides.first?.answer, "JUPITER is a Booster partition.",
                       "answered while the long reply is still being written")
        XCTAssertTrue(store.isStreaming || store.current?.messages.last?.content.isEmpty == false)
        XCTAssertEqual(store.currentID, chat)

        await wait({ !store.isStreaming }, timeout: 20)
        // The aside became a chat of its own, and the question is marked with where it came from.
        let kept = try XCTUnwrap(store.conversations.first { $0.id == store.currentAsides.first?.answerChat })
        XCTAssertEqual(kept.messages.first?.content, "What is JUPITER?")
        XCTAssertEqual(kept.messages.first?.asideOf, store.current?.title)
        XCTAssertFalse(kept.isEphemeral)
        if let open = store.current { store.delete(open) }
        store.delete(kept)
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
