import XCTest
@testable import BlabladorCore

/// A disappearing chat: saved nowhere, indexed never, and not to be found by searching the history.
final class EphemeralTests: XCTestCase {
    func testStoredWithoutDisappearingChats() {
        var kept = Conversation(title: "Cluster notes", model: "m")
        kept.messages = [ChatMessage(role: .user, content: "How busy is JUPITER today, roughly?")]
        var going = Conversation(title: "Disappearing chat", model: "m", ephemeral: true)
        going.messages = [ChatMessage(role: .user, content: "A secret I don't want kept anywhere at all")]

        let stored = ConversationLibrary.stored([going, kept])
        XCTAssertEqual(stored.map(\.id), [kept.id])
    }

    func testDisappearingChatsAreNotSearched() {
        var kept = Conversation(title: "Cluster notes", model: "m")
        kept.messages = [ChatMessage(role: .user, content: "The JUPITER quota is nearly used up.")]
        var going = Conversation(title: "Disappearing chat", model: "m", ephemeral: true)
        going.messages = [ChatMessage(role: .user, content: "The JUPITER quota is 100 hours a week.")]

        let found = ChatSearch.search("JUPITER quota", in: [going, kept], excluding: nil)
        XCTAssertTrue(found.contains("nearly used up"))
        XCTAssertFalse(found.contains("100 hours"))
    }

    func testOnlyAFlagMakesAChatDisappear() {
        XCTAssertFalse(Conversation(title: "x", model: "m").isEphemeral)
        XCTAssertFalse(Conversation(title: "x", model: "m", ephemeral: false).isEphemeral)
        XCTAssertTrue(Conversation(title: "x", model: "m", ephemeral: true).isEphemeral)
    }
}
