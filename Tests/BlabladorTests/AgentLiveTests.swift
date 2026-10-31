import XCTest
@testable import BlabladorCore

/// Real requests to Blablador through the chat engine (BLABLADOR_NETWORK_TESTS=1 and HELMHOLTZ_BLABLADOR_TOKEN).
@MainActor
final class AgentLiveTests: XCTestCase {
    func testPlanTraceAndMention() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLABLADOR_NETWORK_TESTS"] == "1", let token = environment["HELMHOLTZ_BLABLADOR_TOKEN"] else { throw XCTSkip("network") }
        let store = ChatStore()
        store.apiKey = token
        store.newChat()
        store.send("Compute the first 15 Fibonacci numbers with Python, then compute their sum with Python in a second run, then tell me both. Make a plan first.",
                   mentions: [Mention(kind: .tool, value: "python", name: "Python", icon: "x")])
        let chat = try XCTUnwrap(store.currentID)
        let deadline = Date().addingTimeInterval(300)
        while store.isBusy, Date() < deadline { try await Task.sleep(for: .seconds(1)) }
        let reply = try XCTUnwrap(store.conversations.first { $0.id == chat }?.messages.last)
        print("REPLY:", reply.content.prefix(400))
        print("PLAN:", reply.plan.map { "\($0.status) \($0.text)" })
        print("TRACE:", reply.trace.map { TraceLine.summary($0) } ?? "none", reply.trace?.calls.map(\.tool) ?? [])
        print("SKILL:", reply.suggestedSkills.map(\.name))
        XCTAssertFalse(reply.isError)
        XCTAssertNotNil(reply.trace)
        XCTAssertGreaterThan(reply.trace?.promptTokens ?? 0, 0)
        XCTAssertTrue(reply.trace?.calls.contains { $0.tool == "run_python" } == true)
        // Give the skill draft a moment.
        try await Task.sleep(for: .seconds(20))
        print("SKILL AFTER:", store.conversations.first { $0.id == chat }?.messages.last?.suggestedSkills.map(\.name) ?? [])
        store.delete(store.conversations.first { $0.id == chat }!)
    }
}
