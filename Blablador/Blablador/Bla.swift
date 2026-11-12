#if os(macOS)
import Foundation
import Security

/// `bla`, Blablador on the command line. The app's own binary answers when started with `--cli`; the `bla`
/// script installed from Settings runs it that way, so it uses the app's API key, endpoint, model and effort.
enum BlaCommand {
    static let usage = """
    Usage: bla [options] [question…]

    Asks Blablador and writes the answer as it arrives. Text piped in is added to the question:
      git diff | bla "write a commit message"
    Without a question in a terminal, starts a chat (Ctrl-D ends it).

    Options:
      -m, --model ID       model to use (default: the app's model)
      -e, --effort LEVEL   thinking effort: off, low, medium, high or max
      -s, --system TEXT    instructions for the model (default: the app's custom instructions)
      -t, --thinking       also show the model's thinking (on stderr)
      -l, --models         list the chat models
      -h, --help           show this help
    """

    @MainActor
    struct Options {
        var model = UserDefaults.standard.string(forKey: "selectedModel") ?? BlabladorAPI.defaultModel
        var effort: ReasoningEffort?
        var system = CustomInstructions.text
        var showThinking = false
        var listModels = false
        var words: [String] = []
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
    }

    @MainActor
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let next = rest.popFirst() else { throw Failure.message("\(flag) needs a value.") }
            return next
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "-m", "--model": options.model = try value(argument)
            case "-e", "--effort":
                let name = try value(argument).lowercased()
                guard let level = ReasoningEffort(rawValue: name == "xhigh" ? "max" : name) else {
                    throw Failure.message("Unknown effort \(name). Use off, low, medium, high or max.")
                }
                options.effort = level
            case "-s", "--system": options.system = try value(argument)
            case "-t", "--thinking": options.showThinking = true
            case "-l", "--models": options.listModels = true
            case "-h", "--help": throw Failure.message(usage)
            case "--": options.words += rest; rest = []
            default:
                if argument.hasPrefix("-"), argument.count > 1 { throw Failure.message("Unknown option \(argument).\n\n\(usage)") }
                options.words.append(argument)
            }
        }
        return options
    }

    /// Runs the command and exits.
    @MainActor
    static func run(_ arguments: [String]) async -> Never {
        do {
            let options = try parse(arguments)
            let key = ProcessInfo.processInfo.environment["BLABLADOR_API_KEY"] ?? KeychainHelper.read("apiKey") ?? ""
            guard !key.isEmpty else { throw Failure.message("No API key. Add one in Blablador's Settings or set BLABLADOR_API_KEY.") }
            let api = BlabladorAPI(apiKey: key)
            if options.listModels {
                let models = try await api.models().filter(\.isChatCapable).map(\.id).sorted()
                print(models.joined(separator: "\n"))
                exit(0)
            }
            let effort = options.effort.flatMap { ReasoningEffort.levels(for: options.model).contains($0) ? $0 : nil }
                ?? ReasoningEffort.level(for: options.model)
            var messages: [[String: Any]] = []
            let system = options.system.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty { messages.append(["role": "system", "content": system]) }

            var question = options.words.joined(separator: " ")
            let interactive = isatty(STDIN_FILENO) != 0
            if !interactive, let piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
               !piped.isEmpty {
                question = question.isEmpty ? piped : question + "\n\n" + piped
            }
            if !question.isEmpty {
                messages.append(["role": "user", "content": question])
                _ = try await answer(messages, api: api, model: options.model, effort: effort, showThinking: options.showThinking)
                exit(0)
            }
            guard interactive else { throw Failure.message(usage) }
            // A chat in the terminal.
            FileHandle.standardError.write(Data("\(RemoteModel(id: options.model).displayName)\(effort.map { " · \($0.name)" } ?? ""). Ctrl-D ends the chat.\n".utf8))
            while true {
                FileHandle.standardError.write(Data("\n› ".utf8))
                guard let line = readLine() else { print(); exit(0) }
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                messages.append(["role": "user", "content": line])
                let reply = try await answer(messages, api: api, model: options.model, effort: effort, showThinking: options.showThinking)
                messages.append(["role": "assistant", "content": reply])
            }
        } catch Failure.message(usage) {
            print(usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Streams one answer to stdout (thinking to stderr when asked) and returns it.
    @MainActor
    private static func answer(_ messages: [[String: Any]], api: BlabladorAPI, model: String, effort: ReasoningEffort?, showThinking: Bool) async throws -> String {
        let dim = isatty(STDERR_FILENO) != 0 ? ("\u{1B}[2m", "\u{1B}[0m") : ("", "")
        var text = ""
        var printed = 0
        var thought = 0
        var reasoning = false
        func write(thinking: String) {
            guard showThinking, !thinking.isEmpty else { return }
            FileHandle.standardError.write(Data((dim.0 + thinking + dim.1).utf8))
            reasoning = true
        }
        for try await event in api.streamChat(model: model, messages: messages, effort: effort) {
            switch event {
            case let .reasoning(delta):
                write(thinking: delta)
            case let .content(delta):
                text += delta
                // Some models put their thinking in <think> tags at the start of the answer.
                let (thinking, answer) = ChatStore.splitThinking(text)
                if thinking.count > thought {
                    write(thinking: String(thinking.dropFirst(thought)))
                    thought = thinking.count
                }
                guard answer.count > printed else { continue }
                if reasoning {
                    FileHandle.standardError.write(Data("\n\n".utf8))
                    reasoning = false
                }
                FileHandle.standardOutput.write(Data(String(answer.dropFirst(printed)).utf8))
                printed = answer.count
            default:
                break
            }
        }
        let answer = ChatStore.splitThinking(text).answer
        if !answer.hasSuffix("\n") { print() }
        return answer
    }

    /// Where `bla` goes: the first of these folders that can be written to, so no password is needed.
    static var installFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/usr/local/bin", "/opt/homebrew/bin"].map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent(".local/bin")]
    }

    /// The installed script, if there is one.
    static var installed: URL? {
        installFolders.map { $0.appendingPathComponent("bla") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Links `bla` to the script in the app's Resources (older builds: writes a script that starts this app's
    /// binary in command-line mode). Returns where it went.
    @discardableResult
    /// The Rust bla reads the key from the login keychain, like the desktop app; this app keeps its own in the data
    /// protection keychain, which only it can open. Installing the command puts a copy where bla looks.
    static func shareKey() {
        guard let key = KeychainHelper.read("apiKey"), !key.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "de.fz-juelich.blablador",
            kSecAttrAccount as String: "apiKey"
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = "Blablador API key (for bla and the desktop app)"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func install(executable: String = Bundle.main.executablePath ?? "/Applications/Blablador.app/Contents/MacOS/Blablador") throws -> URL {
        let script = "#!/bin/sh\n# Blablador on the command line; installed by the Blablador app.\nexec '\(executable.replacingOccurrences(of: "'", with: "'\\''"))' --cli \"$@\"\n"
        let manager = FileManager.default
        let folder = installFolders.first { manager.isWritableFile(atPath: $0.path) } ?? installFolders.last!
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("bla")
        shareKey()
        if let bundled = Bundle.main.url(forResource: "bla", withExtension: nil) {
            // A link to the script inside the app (as Homebrew makes), so it keeps working after updates.
            try? manager.removeItem(at: url)
            try manager.createSymbolicLink(at: url, withDestinationURL: bundled)
            return url
        }
        try Data(script.utf8).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
#endif
