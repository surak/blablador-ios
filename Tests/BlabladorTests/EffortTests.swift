import XCTest
@testable import BlabladorCore

/// Thinking effort: which models take it, how each level is sent, and falling back when a server refuses.
final class EffortTests: XCTestCase {
    private let model = "test-deepseek-v4.1-flash"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "reasoningEffort")
        UserDefaults.standard.removeObject(forKey: "reasoningEffortWorked")
    }

    override func tearDown() {
        MockServer.stop()
        setUp()
    }

    func testLevelsPerModel() {
        XCTAssertEqual(ReasoningEffort.levels(for: "deepseek-v4.1-flash-at-hzdr"), [.off, .low, .medium, .high, .max])
        XCTAssertEqual(ReasoningEffort.levels(for: "openai/gpt-oss-120b"), [.low, .medium, .high, .max])
        XCTAssertEqual(ReasoningEffort.levels(for: "Qwen3-32B"), [.off, .high])
        XCTAssertEqual(ReasoningEffort.levels(for: "Qwen3-30B-A3B-Instruct-2507"), [])
        XCTAssertEqual(ReasoningEffort.levels(for: "alias-fast"), [])
        XCTAssertNil(ReasoningEffort.level(for: "alias-fast"))
        XCTAssertEqual(ReasoningEffort.level(for: model), .medium)
        ReasoningEffort.setLevel(.low, for: model)
        XCTAssertEqual(ReasoningEffort.level(for: model), .low)
        // A level the model doesn't take falls back to its default.
        ReasoningEffort.setLevel(.off, for: "gpt-oss-20b")
        XCTAssertEqual(ReasoningEffort.level(for: "gpt-oss-20b"), .medium)
    }

    func testMaxFallsBackToXHighAndIsRemembered() async throws {
        MockServer.start { _, body in
            let effort = body.json["reasoning_effort"] as? String
            if effort == "max" { return .init(status: 400, body: Data("unsupported reasoning_effort".utf8)) }
            return .init(headers: ["Content-Type": "text/event-stream"], body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8))
        }
        var content = ""
        for try await event in BlabladorAPI(apiKey: "test").streamChat(model: "gpt-oss-120b", messages: [], effort: .max) {
            if case let .content(text) = event { content += text }
        }
        XCTAssertEqual(content, "ok")
        XCTAssertEqual(MockServer.requests.map { $0.body.json["reasoning_effort"] as? String }, ["max", "xhigh"])
        // The next request starts with the way that worked.
        XCTAssertEqual(ReasoningEffort.candidates(for: "gpt-oss-120b", .max).first?["reasoning_effort"] as? String, "xhigh")
    }

    func testOffForDeepSeekSwitchesThinkingOff() {
        let first = ReasoningEffort.candidates(for: model, .off).first
        XCTAssertEqual((first?["chat_template_kwargs"] as? [String: Any])?["thinking"] as? Bool, false)
        XCTAssertTrue(ReasoningEffort.candidates(for: model, .off).last?.isEmpty == true)
    }

    @MainActor
    func testCommandLineOptions() throws {
        let options = try BlaCommand.parse(["-m", "x", "-e", "xhigh", "-t", "why", "is", "the", "sky", "blue"])
        XCTAssertEqual(options.model, "x")
        XCTAssertEqual(options.effort, .max)
        XCTAssertTrue(options.showThinking)
        XCTAssertEqual(options.words.joined(separator: " "), "why is the sky blue")
        XCTAssertThrowsError(try BlaCommand.parse(["--nope"]))
    }
}
