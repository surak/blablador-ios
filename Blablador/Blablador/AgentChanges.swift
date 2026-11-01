import SwiftUI

/// A file the agent wrote or edited, with its text before and after, so it can be reviewed and undone.
struct FileChange: Codable, Hashable {
    /// Relative to the workspace.
    var path: String
    /// nil when the agent created the file.
    var before: String?
    var after: String
    var undone = false

    /// Files up to this size keep both versions; bigger ones show no diff and can't be undone.
    static let maxSize = 400_000

    var stats: (added: Int, removed: Int) {
        let lines = UnifiedDiff.lines(before ?? "", after)
        return (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }
}

/// Line diff with context, like `git diff`.
enum UnifiedDiff {
    struct Line: Hashable {
        enum Kind { case context, added, removed, gap }
        var kind: Kind
        var text: String
        /// Line numbers in the old and new file.
        var old: Int?
        var new: Int?
    }

    static func lines(_ before: String, _ after: String, context: Int = 3) -> [Line] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both files together.
        var all: [Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                all.append(Line(kind: .removed, text: old[i], old: i + 1))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                all.append(Line(kind: .added, text: new[j], new: j + 1))
                j += 1
            } else {
                if i < old.count { all.append(Line(kind: .context, text: old[i], old: i + 1, new: j + 1)) }
                i += 1
                j += 1
            }
        }
        // Keep `context` lines around changes, a gap marker between hunks.
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(all.count - 1, index + context) { keep.insert(k) }
        }
        var result: [Line] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 { result.append(Line(kind: .gap, text: "")) }
            result.append(all[index])
            previous = index
        }
        if let first = keep.min(), first > 0 { result.insert(Line(kind: .gap, text: ""), at: 0) }
        return result
    }

    /// Plain-text form for the model and copying.
    static func text(_ change: FileChange) -> String {
        let body = lines(change.before ?? "", change.after).map { line -> String in
            switch line.kind {
            case .context: " " + line.text
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .gap: "@@"
            }
        }
        return (["--- \(change.before == nil ? "/dev/null" : "a/" + change.path)", "+++ b/\(change.path)"] + body).joined(separator: "\n")
    }
}

/// A file's diff with line numbers and Undo / Redo.
struct FileChangeView: View {
    let change: FileChange
    var onUndo: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: change.before == nil ? "doc.badge.plus" : "pencil")
                    .foregroundStyle(Theme.gradient)
                Text(change.path)
                    .scaledFont(.caption, weight: .semibold, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let stats = change.stats
                Text("+\(stats.added)").foregroundStyle(.green).scaledFont(.caption2, design: .monospaced)
                Text("−\(stats.removed)").foregroundStyle(.red).scaledFont(.caption2, design: .monospaced)
                Spacer(minLength: 4)
                if let onUndo {
                    Button(change.undone ? "Redo" : "Undo", action: onUndo)
                        .scaledFont(.caption, weight: .medium)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if change.undone {
                Text("Undone")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(UnifiedDiff.lines(change.before ?? "", change.after).prefix(800).enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ line: UnifiedDiff.Line) -> some View {
        if line.kind == .gap {
            Text("⋯")
                .scaledFont(.caption2, design: .monospaced)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 70)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: 32, alignment: .trailing)
                Text(line.new.map(String.init) ?? "").frame(width: 32, alignment: .trailing)
                Text(line.kind == .added ? " + " : line.kind == .removed ? " − " : "   ")
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.primary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .scaledFont(.caption2, design: .monospaced)
            .foregroundStyle(.secondary)
            .background(line.kind == .added ? Color.green.opacity(0.14) : line.kind == .removed ? Color.red.opacity(0.14) : .clear)
        }
    }
}

/// Under an agent reply: files changed with +/− counts, Review and Undo all.
struct ChangesSummary: View {
    @EnvironmentObject private var store: ChatStore
    let message: ChatMessage
    @State private var reviewing = false

    var body: some View {
        let changes = message.steps.compactMap(\.change)
        let active = changes.filter { !$0.undone }
        if !changes.isEmpty {
            let files = Set(active.map(\.path)).count
            let stats = active.reduce((0, 0)) { ($0.0 + $1.stats.added, $0.1 + $1.stats.removed) }
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.gradient)
                if active.isEmpty {
                    Text("All changes undone").foregroundStyle(.secondary)
                } else {
                    Text("\(files) file\(files == 1 ? "" : "s") changed")
                    Text("+\(stats.0)").foregroundStyle(.green)
                    Text("−\(stats.1)").foregroundStyle(.red)
                }
                Spacer(minLength: 8)
                Button("Review") { reviewing = true }
                if !active.isEmpty {
                    Button("Undo all") { store.undoAllChanges(in: message.id) }
                }
            }
            .scaledFont(.caption, weight: .medium)
            .buttonStyle(.borderless)
            .padding(10)
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .sheet(isPresented: $reviewing) {
                NavigationStack { ChangesReview(messageID: message.id) }
#if os(macOS)
                    .frame(minWidth: 720, minHeight: 560)
#endif
            }
        }
    }
}

/// Every change of a reply, file by file.
struct ChangesReview: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let messageID: UUID

    var body: some View {
        let steps = store.message(messageID)?.steps.filter { $0.change != nil } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    if let change = step.change {
                        FileChangeView(change: change) { store.toggleChange(step.id, in: messageID) }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Changes")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Undo All") { store.undoAllChanges(in: messageID) }
                    .disabled(!steps.contains { $0.change?.undone == false })
            }
        }
        .alert("Can't undo", isPresented: Binding(get: { store.changeError != nil }, set: { if !$0 { store.changeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.changeError ?? "")
        }
    }
}

/// What the agent learns about a folder before each reply: git state, files, README, agent instructions, how to build and test.
enum ProjectOverview {
    static let maxLength = 14_000

    static func make(for root: URL) -> String {
        var parts: [String] = []
        let manager = FileManager.default
        let isGit = manager.fileExists(atPath: root.appendingPathComponent(".git").path)
        if isGit {
            let status = AgentTools.git(["status", "--short", "--branch"], in: root)
            let lines = status.split(separator: "\n")
            parts.append("Git: " + lines.prefix(30).joined(separator: "\n") + (lines.count > 30 ? "\n… (\(lines.count - 30) more)" : ""))
            let log = AgentTools.git(["log", "--oneline", "-8"], in: root)
            if !log.isEmpty { parts.append("Recent commits:\n" + log) }
        }
        let files = isGit ? AgentTools.git(["ls-files"], in: root).split(separator: "\n").map(String.init) : AgentTools.files(in: root, limit: 3_000)
        if !files.isEmpty { parts.append("Files (\(files.count)):\n" + tree(files)) }

        let build = buildSystems(root, files: Set(files))
        if !build.isEmpty { parts.append("Build and test:\n" + build.joined(separator: "\n")) }

        for name in ["AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md", "CONTRIBUTING.md"] {
            if let text = read(root, name, limit: 3_000) {
                parts.append("\(name) (the project's instructions; follow them):\n" + text)
            }
        }
        if let readme = ["README.md", "README", "README.txt", "readme.md"].lazy.compactMap({ read(root, $0, limit: 2_500) }).first {
            parts.append("README:\n" + readme)
        }
        let text = parts.joined(separator: "\n\n")
        return text.count > maxLength ? String(text.prefix(maxLength)) + "\n…" : text
    }

    /// Folders with file counts, and the files of shallow folders.
    static func tree(_ files: [String], limit: Int = 120) -> String {
        var counts: [String: Int] = [:]
        for file in files {
            let parts = file.split(separator: "/")
            for depth in 1..<max(1, min(parts.count, 3)) {
                counts[parts.prefix(depth).joined(separator: "/") + "/", default: 0] += 1
            }
        }
        let topFiles = files.filter { $0.split(separator: "/").count <= 2 }
        var lines = counts.keys.sorted().map { "\($0) (\(counts[$0]!) files)" }
        lines += topFiles.sorted()
        lines.sort()
        if lines.count > limit { return lines.prefix(limit).joined(separator: "\n") + "\n… (\(lines.count - limit) more)" }
        return lines.joined(separator: "\n")
    }

    private static func buildSystems(_ root: URL, files: Set<String>) -> [String] {
        var found: [String] = []
        let top = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if top.contains("Package.swift") { found.append("Swift package: swift build, swift test") }
        for project in top where project.hasSuffix(".xcodeproj") || project.hasSuffix(".xcworkspace") {
            found.append("Xcode: \(project) (xcodebuild -list shows schemes)")
        }
        if top.contains(where: { $0.hasPrefix("build.gradle") || $0 == "gradlew" }) { found.append("Gradle: ./gradlew build, ./gradlew test") }
        if top.contains("package.json"), let data = FileManager.default.contents(atPath: root.appendingPathComponent("package.json").path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = (json["scripts"] as? [String: Any])?.keys.sorted() ?? []
            found.append("npm: scripts " + (scripts.isEmpty ? "none" : scripts.joined(separator: ", ")) + " (npm run <name>)")
        }
        if top.contains("pyproject.toml") || top.contains("setup.py") { found.append("Python: pyproject.toml/setup.py" + (files.contains { $0.hasPrefix("tests/") || $0.contains("/test_") } ? ", tests with pytest" : "")) }
        if top.contains("Cargo.toml") { found.append("Rust: cargo build, cargo test") }
        if top.contains("go.mod") { found.append("Go: go build ./..., go test ./...") }
        if top.contains("Makefile"), let make = read(root, "Makefile", limit: 4_000) {
            let targets = make.split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."), !line.contains("=") else { return nil }
                return String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            }
            found.append("Make: targets " + targets.prefix(15).joined(separator: ", "))
        }
        if top.contains("CMakeLists.txt") { found.append("CMake: cmake -B build && cmake --build build") }
        return found
    }

    private static func read(_ root: URL, _ name: String, limit: Int) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…" : trimmed
    }
}

/// The overview the agent sees, from the folder chip.
struct ProjectOverviewView: View {
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Reading the folder…" : text)
                .scaledFont(.caption, design: .monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("What the agent knows")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            let folder = folder
            text = await Task.detached { ProjectOverview.make(for: folder) }.value
        }
    }
}
