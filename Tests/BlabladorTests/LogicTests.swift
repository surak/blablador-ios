import XCTest
@testable import BlabladorCore

final class SkillTests: XCTestCase {
    func testFrontMatterRoundTrip() {
        let skill = Skill(name: "Meeting notes", description: "When I paste a transcript", instructions: "1. Decisions\n2. Action items")
        let parsed = Skill(markdown: skill.markdown, fileName: "whatever.md")
        XCTAssertEqual(parsed?.name, "Meeting notes")
        XCTAssertEqual(parsed?.description, "When I paste a transcript")
        XCTAssertEqual(parsed?.instructions, "1. Decisions\n2. Action items")
    }

    func testFileWithoutFrontMatterUsesFileNameAndFirstLine() {
        let parsed = Skill(markdown: "Write short press releases.\n\nAlways add a quote.", fileName: "Press release.md")
        XCTAssertEqual(parsed?.name, "Press release")
        XCTAssertEqual(parsed?.description, "Write short press releases.")
    }

    func testEmptyFileIsRejected() {
        XCTAssertNil(Skill(markdown: "---\nname: x\n---\n", fileName: "x.md"))
    }
}

final class MemoryTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(MemoryStore.words("The GPU-quota on JUPITER, 2027!"), ["the", "gpu", "quota", "jupiter", "2027"])
    }

    func testAllMemoriesSentWhenFew() {
        let memories = (1...5).map { Memory(text: "Fact \($0)") }
        let prompt = MemoryStore.systemPrompt(memories: memories, question: "anything")
        XCTAssertTrue(prompt.contains("1. Fact 1"))
        XCTAssertTrue(prompt.contains("5. Fact 5"))
    }

    func testOnlyRelevantAndNewestSentWhenMany() {
        var memories = (1...60).map { Memory(text: "Unrelated fact number \($0)") }
        memories[3] = Memory(text: "The user's cluster is JUPITER")
        let prompt = MemoryStore.systemPrompt(memories: memories, question: "How busy is JUPITER today?")
        XCTAssertTrue(prompt.contains("4. The user's cluster is JUPITER"), "relevant memory keeps its number")
        XCTAssertTrue(prompt.contains("60. Unrelated fact number 60"), "newest are always sent")
        XCTAssertFalse(prompt.contains("10. Unrelated fact number 10\n"))
        XCTAssertTrue(prompt.contains("other memories aren't shown"))
    }

    func testEmptyMemory() {
        XCTAssertTrue(MemoryStore.systemPrompt(memories: [], question: "hi").contains("don't remember anything yet"))
    }
}

final class ChatSearchTests: XCTestCase {
    func testFindsEarlierChatButNotCurrent() {
        var gpu = Conversation(title: "GPU quota", model: "m")
        gpu.messages = [ChatMessage(role: .user, content: "We agreed to raise the GPU quota to 40 nodes in December.")]
        var current = Conversation(title: "Now", model: "m")
        current.messages = [ChatMessage(role: .user, content: "What did we decide about the GPU quota?")]
        let result = ChatSearch.search("GPU quota decision", in: [gpu, current], excluding: current.id)
        XCTAssertTrue(result.contains("[GPU quota,"))
        XCTAssertTrue(result.contains("40 nodes"))
        XCTAssertFalse(result.contains("What did we decide"))
    }

    func testNothingFound() {
        XCTAssertTrue(ChatSearch.search("zebra", in: [], excluding: nil).contains("No earlier chats"))
    }
}

final class WebPageTests: XCTestCase {
    func testOnlyPublicAddresses() {
        XCTAssertTrue(WebPage.isPublic(URL(string: "https://www.fz-juelich.de/en")!))
        for address in ["http://localhost:8080", "https://192.168.1.10/admin", "https://10.0.0.1", "https://printer.local",
                        "https://172.20.0.5", "https://169.254.169.254/latest", "https://[::1]/", "file:///etc/passwd", "https://intranet"] {
            XCTAssertFalse(WebPage.isPublic(URL(string: address)!), address)
        }
    }

    func testReadableTextSkipsScriptsAndMenus() {
        let html = """
        <html><head><title>Test &amp; page</title><script>var secret = 1;</script></head>
        <body><nav>Home | About</nav><article><h1>Heading</h1><p>First &quot;paragraph&quot; with enough words to count as the article body, \
        repeated so that it is long enough. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut \
        labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo \
        consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.</p>
        <ul><li>One</li><li>Two &#8211; three</li></ul></article><footer>Imprint</footer></body></html>
        """
        XCTAssertEqual(WebPage.title(of: html), "Test & page")
        let text = WebPage.readableText(html)
        XCTAssertTrue(text.contains("## Heading"))
        XCTAssertTrue(text.contains("First \"paragraph\""))
        XCTAssertTrue(text.contains("- One"))
        XCTAssertTrue(text.contains("- Two – three"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("Imprint"))
        XCTAssertFalse(text.contains("Home | About"))
    }
}

final class RenderingTests: XCTestCase {
    func testInlineMathButNotPrices() {
        XCTAssertTrue(MathDetection.hasInlineMath("The energy is $E = mc^2$."))
        XCTAssertTrue(MathDetection.hasInlineMath("Inline \\(a^2 + b^2\\) too"))
        XCTAssertFalse(MathDetection.hasInlineMath("It costs $5 and $10."))
        XCTAssertFalse(MathDetection.hasInlineMath("Use $HOME and $PATH in the shell"))
        XCTAssertFalse(MathDetection.hasInlineMath("No maths here."))
    }

    func testCodeFileExtensions() {
        XCTAssertEqual(CodeFile.fileExtension(for: "Python"), "py")
        XCTAssertEqual(CodeFile.fileExtension(for: "bash"), "sh")
        XCTAssertEqual(CodeFile.fileExtension(for: ""), "txt")
        XCTAssertEqual(CodeFile.fileExtension(for: "zig"), "zig")
    }
}

@MainActor
final class ChatTests: XCTestCase {
    func testSplitThinking() {
        let split = ChatStore.splitThinking("<think>pondering</think>\nThe answer.")
        XCTAssertEqual(split.thinking, "pondering")
        XCTAssertEqual(split.answer, "The answer.")
        XCTAssertEqual(ChatStore.splitThinking("Plain answer").answer, "Plain answer")
    }

    func testHistoryReplacesSummarisedMessages() {
        var conversation = Conversation(title: "Long", model: "m")
        conversation.messages = (1...12).map { ChatMessage(role: $0 % 2 == 1 ? .user : .assistant, content: "Message \($0)") }
        conversation.summary = "They discussed the JUPITER move."
        conversation.summaryCount = 4
        let wire = ChatStore.history(system: "Be brief.", conversation)
        XCTAssertEqual(wire.count, 1 + 8)
        let system = wire[0]["content"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix("Be brief."))
        XCTAssertTrue(system.contains("They discussed the JUPITER move."))
        XCTAssertEqual(wire[1]["content"] as? String, "Message 5")
        XCTAssertGreaterThan(ChatStore.size(wire), 0)
    }

    func testHistoryWithoutSummarySendsEverything() {
        var conversation = Conversation(title: "Short", model: "m")
        conversation.messages = [ChatMessage(role: .user, content: "Hi")]
        XCTAssertEqual(ChatStore.history(system: "S", conversation).count, 2)
    }
}
