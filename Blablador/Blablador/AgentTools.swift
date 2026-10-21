import Foundation

/// One tool call made by the agent, shown as a step under the reply.
struct AgentStep: Identifiable, Codable, Hashable {
    enum State: String, Codable { case running, done, failed, denied }

    var id = UUID()
    var tool: String
    /// One line, e.g. "Edited Sources/App.swift" or "$ swift build".
    var title: String
    /// Output, diff or error, trimmed for display.
    var detail = ""
    var state = State.running
}

/// Coding-agent tools confined to a workspace folder: list, read, search, write, edit and run commands.
enum AgentTools {
    static let maxRounds = 40
    private static let maxOutput = 30_000

    static let names: Set<String> = ["list_files", "read_file", "search_files", "write_file", "edit_file", "run_command"]

    static func systemPrompt(workspace: URL) -> String {
        """
        You are a coding agent working in the folder \(workspace.path). Use the tools to inspect and change files and run commands; \
        paths are relative to that folder. Work step by step: look at the relevant files before changing them, make focused edits \
        with edit_file (exact text replacement) and use write_file only for new files or full rewrites. After changes, build or test \
        with run_command when possible and fix what fails. The user approves each shell command. When done, summarize what you \
        changed and anything left to do. Don't claim to have changed or run something unless a tool did it.
        """
    }

    static let definitions: [[String: Any]] = [
        function("list_files", "List files and folders in a directory of the workspace (folders end with /).", [
            "path": ["type": "string", "description": "Directory relative to the workspace; \".\" for the root."],
            "recursive": ["type": "boolean", "description": "Include subfolders (up to 500 entries)."]
        ], required: ["path"]),
        function("read_file", "Read a text file with line numbers.", [
            "path": ["type": "string", "description": "File relative to the workspace."],
            "offset": ["type": "integer", "description": "First line to read, starting at 1."],
            "limit": ["type": "integer", "description": "Number of lines (default 400)."]
        ], required: ["path"]),
        function("search_files", "Search file contents with a regular expression (like grep -rn). Returns matching lines with file and line number.", [
            "pattern": ["type": "string", "description": "Extended regular expression."],
            "path": ["type": "string", "description": "Directory or file to search; default the whole workspace."]
        ], required: ["pattern"]),
        function("write_file", "Create or overwrite a file with the given content.", [
            "path": ["type": "string", "description": "File relative to the workspace."],
            "content": ["type": "string", "description": "Complete new file content."]
        ], required: ["path", "content"]),
        function("edit_file", "Replace an exact piece of text in a file. old_text must match exactly once unless replace_all is true.", [
            "path": ["type": "string", "description": "File relative to the workspace."],
            "old_text": ["type": "string", "description": "Exact text to replace, including whitespace."],
            "new_text": ["type": "string", "description": "Replacement text."],
            "replace_all": ["type": "boolean", "description": "Replace every occurrence."]
        ], required: ["path", "old_text", "new_text"]),
        function("run_command", "Run a shell command (zsh) in the workspace folder and return its output and exit code. Needs the user's approval.", [
            "command": ["type": "string", "description": "The command line."],
            "timeout": ["type": "integer", "description": "Seconds before the command is stopped (default 120, max 600)."]
        ], required: ["command"])
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required]
        ]]
    }

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A short title for the step list.
    static func title(for tool: String, _ arguments: [String: Any]) -> String {
        let path = arguments["path"] as? String ?? "."
        switch tool {
        case "list_files": return "Listed \(path)"
        case "read_file": return "Read \(path)"
        case "search_files": return "Searched “\(arguments["pattern"] as? String ?? "")”"
        case "write_file": return "Wrote \(path)"
        case "edit_file": return "Edited \(path)"
        case "run_command": return "$ \(arguments["command"] as? String ?? "")"
        default: return tool
        }
    }

    /// Runs a file tool (everything except run_command) and returns its output for the model.
    static func run(_ tool: String, _ arguments: [String: Any], in root: URL) throws -> String {
        let path = arguments["path"] as? String ?? "."
        switch tool {
        case "list_files":
            return try list(resolve(path, in: root), root: root, recursive: arguments["recursive"] as? Bool ?? false)
        case "read_file":
            return try read(resolve(path, in: root), offset: arguments["offset"] as? Int ?? 1, limit: arguments["limit"] as? Int ?? 400)
        case "search_files":
            return try search(arguments["pattern"] as? String ?? "", in: resolve(path, in: root), root: root)
        case "write_file":
            let url = try writable(resolve(path, in: root), in: root)
            let content = arguments["content"] as? String ?? ""
            let existed = FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(existed ? "Overwrote" : "Created") \(path) (\(lines) lines)."
        case "edit_file":
            return try edit(writable(resolve(path, in: root), in: root), path: path,
                            old: arguments["old_text"] as? String ?? "", new: arguments["new_text"] as? String ?? "",
                            all: arguments["replace_all"] as? Bool ?? false)
        default:
            throw ToolError(message: "Unknown tool \(tool).")
        }
    }

    /// Refuses writes into .git: hooks there run on the next git command the user approves.
    static func writable(_ url: URL, in root: URL) throws -> URL {
        if relative(url, to: root).split(separator: "/").contains(".git") {
            throw ToolError(message: "Changing files inside .git isn't allowed.")
        }
        return url
    }

    /// Resolves a workspace-relative path and refuses anything outside the workspace.
    static func resolve(_ path: String, in root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else {
            throw ToolError(message: "\(path) is outside the workspace.")
        }
        return candidate
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        return full == base ? "." : String(full.dropFirst(base.count + 1))
    }

    private static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "__pycache__", ".venv"]

    private static func list(_ url: URL, root: URL, recursive: Bool) throws -> String {
        let manager = FileManager.default
        var entries: [String] = []
        if recursive {
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
                throw ToolError(message: "Not a folder.")
            }
            for case let item as URL in enumerator {
                if skipped.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                entries.append(relative(item, to: root) + (isFolder ? "/" : ""))
                if entries.count >= 500 { entries.append("… (stopped at 500 entries)"); break }
            }
        } else {
            let items = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !skipped.contains(item.lastPathComponent) {
                let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                entries.append(relative(item, to: root) + (isFolder ? "/" : ""))
            }
        }
        return entries.isEmpty ? "(empty)" : entries.joined(separator: "\n")
    }

    private static func read(_ url: URL, offset: Int, limit: Int) throws -> String {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ToolError(message: "File not found.") }
        guard let text = String(data: data, encoding: .utf8) else { throw ToolError(message: "Not a UTF-8 text file.") }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset)
        guard start <= lines.count else { return "(the file has \(lines.count) lines)" }
        let end = min(lines.count, start + max(1, min(limit, 2_000)) - 1)
        var output = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        if end < lines.count { output += "\n… (\(lines.count - end) more lines; read on with offset \(end + 1))" }
        return truncated(output)
    }

    private static func search(_ pattern: String, in url: URL, root: URL) throws -> String {
        guard !pattern.isEmpty else { throw ToolError(message: "Empty pattern.") }
        var arguments = ["-rnIE", "--color=never"]
        arguments += skipped.map { "--exclude-dir=\($0)" }
        arguments += ["-e", pattern, relative(url, to: root)]
        let result = try execute("/usr/bin/grep", arguments, in: root, timeout: 60)
        if result.status == 1 { return "No matches." }
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true)
        let shown = lines.prefix(200).joined(separator: "\n")
        return truncated(lines.count > 200 ? shown + "\n… (\(lines.count - 200) more matches)" : shown)
    }

    private static func edit(_ url: URL, path: String, old: String, new: String, all: Bool) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError(message: "\(path) can't be read as text.") }
        guard !old.isEmpty else { throw ToolError(message: "old_text is empty.") }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else { throw ToolError(message: "old_text was not found in \(path). Read the file and copy the text exactly.") }
        guard count == 1 || all else { throw ToolError(message: "old_text occurs \(count) times in \(path); add context or set replace_all.") }
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(path) (\(all ? count : 1) replacement\(count == 1 || !all ? "" : "s")).\n" + diff(old, new)
    }

    /// Compact -/+ view of a replacement.
    static func diff(_ old: String, _ new: String) -> String {
        let removed = old.components(separatedBy: "\n").map { "- " + $0 }
        let added = new.components(separatedBy: "\n").map { "+ " + $0 }
        return truncated((removed + added).joined(separator: "\n"), limit: 6_000)
    }

    // MARK: - Shell

    /// Runs a shell command in the workspace with the user's login environment.
    static func runCommand(_ command: String, in root: URL, timeout: Int) async throws -> String {
#if os(macOS)
        let seconds = TimeInterval(min(max(timeout, 1), 600))
        let result = try await Task.detached { try execute("/bin/zsh", ["-lc", command], in: root, timeout: seconds) }.value
        var output = result.output.isEmpty ? "(no output)" : truncated(result.output)
        if result.timedOut { output += "\n(stopped after \(Int(seconds)) seconds)" }
        return output + "\nExit code: \(result.status)"
#else
        throw ToolError(message: "Shell commands are only available on the Mac.")
#endif
    }

    private struct ExecutionResult {
        var output: String
        var status: Int32
        var timedOut = false
    }

    private static func execute(_ executable: String, _ arguments: [String], in root: URL, timeout: TimeInterval) throws -> ExecutionResult {
#if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read while running so a full pipe can't block the process.
        var data = Data()
        let reader = DispatchQueue(label: "agent.output")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline || Task.isCancelled {
                timedOut = Date() > deadline
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        done.wait()
        return ExecutionResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus, timedOut: timedOut)
#else
        throw ToolError(message: "Not available on this device.")
#endif
    }

    private static func truncated(_ text: String, limit: Int = maxOutput) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return String(text.prefix(half)) + "\n… (\(text.count - limit) characters cut) …\n" + String(text.suffix(half))
    }
}
