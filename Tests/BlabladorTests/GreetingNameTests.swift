import XCTest
@testable import BlabladorCore

/// The name in the greeting comes from Helmholtz Codebase. It must survive a lookup that fails — offline, a
/// Codebase outage, a key not accepted yet — or the greeting loses the name until the app is reinstalled.
@MainActor
final class GreetingNameTests: XCTestCase {
    private var savedEndpoint: String!

    override func setUp() {
        super.setUp()
        savedEndpoint = BlabladorAPI.endpoint
    }

    override func tearDown() {
        BlabladorAPI.endpoint = savedEndpoint
        MockServer.stop()
        super.tearDown()
    }

    private func store(key: String, name: String) -> ChatStore {
        let store = ChatStore()
        store.apiKey = key
        store.userName = name
        return store
    }

    /// Codebase is unreachable: the name found earlier stays.
    func testAFailedLookupKeepsTheName() async {
        BlabladorAPI.endpoint = BlabladorAPI.defaultEndpoint
        let store = store(key: "glpat-test", name: "Alexandre Strube")
        MockServer.start { _, _ in MockServer.Response(status: 503, body: Data("down".utf8)) }

        await store.loadUserName()

        XCTAssertEqual(store.userName, "Alexandre Strube")
    }

    /// Codebase still answers, so the name is refreshed — a renamed user gets the new name.
    func testASuccessfulLookupUpdatesTheName() async {
        BlabladorAPI.endpoint = BlabladorAPI.defaultEndpoint
        let store = store(key: "glpat-test", name: "Alexandre Strube")
        MockServer.start { _, _ in MockServer.Response(body: Data(#"{"name":"A. Strube"}"#.utf8)) }

        await store.loadUserName()

        XCTAssertEqual(store.userName, "A. Strube")
    }

    /// An answer without a name does not blank the greeting either.
    func testAnEmptyAnswerKeepsTheName() async {
        BlabladorAPI.endpoint = BlabladorAPI.defaultEndpoint
        let store = store(key: "glpat-test", name: "Alexandre Strube")
        MockServer.start { _, _ in MockServer.Response(body: Data(#"{"name":"   "}"#.utf8)) }

        await store.loadUserName()

        XCTAssertEqual(store.userName, "Alexandre Strube")
    }

    /// The name belongs to Blablador's Codebase: another endpoint has no name to show, so the old one goes.
    func testAnotherEndpointClearsTheName() async {
        BlabladorAPI.endpoint = "https://example.org/v1"
        let store = store(key: "sk-test", name: "Alexandre Strube")

        await store.loadUserName()

        XCTAssertEqual(store.userName, "")
    }

    /// No key, no name to look up, and nothing written over what is there.
    func testNoKeyKeepsTheName() async {
        BlabladorAPI.endpoint = BlabladorAPI.defaultEndpoint
        let store = store(key: "", name: "Alexandre Strube")

        await store.loadUserName()

        XCTAssertEqual(store.userName, "Alexandre Strube")
    }
}
