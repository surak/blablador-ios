import XCTest
@testable import BlabladorCore

@MainActor
final class AgentChangesTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDiffShowsChangedLinesWithContext() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 10", with: "line ten") + "\nline 21"
        let lines = UnifiedDiff.lines(before, after)
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["line 10"])
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["line ten", "line 21"])
        XCTAssertEqual(lines.first { $0.kind == .removed }?.old, 10)
        XCTAssertTrue(lines.contains { $0.kind == .gap })
        XCTAssertFalse(lines.contains { $0.text == "line 1" })
        XCTAssertEqual(FileChange(path: "a", before: before, after: after).stats.added, 2)
        XCTAssertTrue(UnifiedDiff.text(FileChange(path: "new.txt", before: nil, after: "hi")).contains("--- /dev/null"))
    }

    func testUndoAndRedoRestoreFiles() throws {
        let root = try folder()
        let url = root.appendingPathComponent("a.txt")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        try "new".write(to: url, atomically: true, encoding: .utf8)
        let change = FileChange(path: "a.txt", before: "old", after: "new")
        try ChatStore.apply(change, undo: true, in: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        try ChatStore.apply(change, undo: false, in: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        // Changed since: refuse.
        try "edited by hand".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChatStore.apply(change, undo: true, in: root))
        // A created file is removed on undo.
        let created = FileChange(path: "b.txt", before: nil, after: "x")
        try "x".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try ChatStore.apply(created, undo: true, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        XCTAssertThrowsError(try ChatStore.apply(FileChange(path: "../x", before: nil, after: ""), undo: true, in: root))
    }

    func testProjectOverviewOfThisRepository() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overview = ProjectOverview.make(for: root)
        print(overview.prefix(1500))
        XCTAssertTrue(overview.contains("Git: ## main"))
        XCTAssertTrue(overview.contains("Swift package: swift build, swift test"))
        XCTAssertTrue(overview.contains("AGENTS.md (the project's instructions"))
        XCTAssertTrue(overview.contains("Blablador/"))
        XCTAssertLessThanOrEqual(overview.count, ProjectOverview.maxLength + 2)
    }
}
