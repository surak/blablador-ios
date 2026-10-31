import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 16.0, *)
struct BlabladorCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Blablador"
    static var description = IntentDescription("Send a command to Blablador.")
    static var openAppWhenRun = true

    @Parameter(title: "Command", description: "What you want Blablador to do", requestValueDialog: "What should Blablador do?")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Blablador to \(\.$command)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriCommandCenter.shared.handle(command: command)
        return .result(dialog: "Sending \"\(command)\" to Blablador.")
    }
}

/// Answers without opening the app, so Shortcuts can use the reply: in automations, from the share sheet
/// (with a web page, PDF or data file), or chained with other actions. The exchange is saved as a chat.
struct AskBlabladorIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Blablador"
    static var description = IntentDescription("Ask Blablador a question and get the answer as text, optionally about a file or web page. The chat is saved in Blablador.")

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    @Parameter(title: "File", description: "A PDF, text or data file to ask about")
    var file: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Blablador \(\.$question)") { \.$file }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await ShortcutRunner.ask(question, file: file)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Runs one of the user's skills on some text, e.g. "Meeting notes" on a transcript from the share sheet.
struct RunSkillIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Blablador Skill"
    static var description = IntentDescription("Run one of your Blablador skills on text and get the result.")

    @Parameter(title: "Skill", optionsProvider: SkillOptions())
    var skill: String

    @Parameter(title: "Text", requestValueDialog: "What should the skill work on?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$skill) on \(\.$text)")
    }

    struct SkillOptions: DynamicOptionsProvider {
        @MainActor
        func results() async throws -> [String] { SkillLibrary.shared.skills.map(\.name) }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let found = SkillLibrary.shared.skill(named: skill) else {
            throw ShortcutRunner.ShortcutError.message("There is no skill called \(skill).")
        }
        let answer = try await ShortcutRunner.ask(text, skill: found)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Adds a fact to Blablador's memory.
struct AddMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Blablador Memory"
    static var description = IntentDescription("Save a fact that Blablador remembers in every chat.")

    @Parameter(title: "Fact", requestValueDialog: "What should Blablador remember?")
    var fact: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MemoryStore.shared.add(fact) else { return .result(dialog: "Blablador already remembers that.") }
        if let key = KeychainHelper.read("apiKey"), !key.isEmpty {
            await MemoryStore.shared.embedMissing(api: BlabladorAPI(apiKey: key))
            await MemoryStore.shared.linkMissing(api: BlabladorAPI(apiKey: key))
        }
        return .result(dialog: "Blablador will remember that.")
    }
}

/// One question and answer without the chat window: memories, custom instructions, a skill, a file or the
/// web page a link points to, then the answer saved as a chat.
@MainActor
enum ShortcutRunner {
    enum ShortcutError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
    }

    static func ask(_ question: String, file: IntentFile? = nil, skill: Skill? = nil) async throws -> String {
        guard let key = KeychainHelper.read("apiKey"), !key.isEmpty else {
            throw ShortcutError.message("Open Blablador and enter your API key in Settings first.")
        }
        let api = BlabladorAPI(apiKey: key)
        let model = UserDefaults.standard.string(forKey: "selectedModel") ?? BlabladorAPI.defaultModel

        var system = CustomInstructions.text
        system += "\n\nToday is \(Date().formatted(date: .complete, time: .omitted)). Answer for use in a shortcut: plain and to the point."
        let memory = MemoryStore.shared
        if memory.enabled { system += "\n\n" + (await memory.systemPrompt(for: question, api: api)) }
        if let skill { system += "\n\nFollow these instructions (the user's skill \"\(skill.name)\"):\n" + skill.instructions }

        var prompt = question
        var document: DocumentAttachment?
        if let file {
            document = try await attachment(from: file, api: api)
            if let document { prompt = "<document name=\"\(document.name)\">\n\(document.text.prefix(60_000))\n</document>\n\n" + question }
        } else if let link = question.range(of: #"https?://\S+"#, options: .regularExpression),
                  let page = try? await WebPage.read(String(question[link])) {
            prompt = "<page url=\"\(page.url.absoluteString)\" title=\"\(page.title)\">\n\(page.text)\n</page>\n\n" + question
        }

        let reply = try await api.complete(model: model, system: system.trimmingCharacters(in: .whitespacesAndNewlines), user: prompt)
        let answer = ChatStore.splitThinking(reply).answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ShortcutError.message("No response from the model.") }

        // Keep it in the history like any chat.
        let title = String((skill.map { "\($0.name): " } ?? "") + question.prefix(40))
        var conversation = Conversation(title: title, model: model)
        conversation.messages = [ChatMessage(role: .user, content: question, documents: document.map { [$0] } ?? []),
                                 ChatMessage(role: .assistant, content: answer)]
        ConversationLibrary.shared.conversations.insert(conversation, at: 0)
        ConversationLibrary.shared.persist()
        return answer
    }

    private static func attachment(from file: IntentFile, api: BlabladorAPI) async throws -> DocumentAttachment {
        let name = file.filename
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if file.type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return try await PDFExtractor.extract(from: url, api: api)
        }
        if DataFiles.supports(url) { return try DataFiles.attach(url) }
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw ShortcutError.message("\(name) isn't a PDF, text or data file.")
        }
        return DocumentAttachment(name: name, text: text, pageCount: 1)
    }
}

@available(iOS 16.0, *)
struct BlabladorShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BlabladorCommandIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Tell Blablador",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: AskBlabladorIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Blablador",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: AddMemoryIntent(),
            phrases: [
                "Add to \(.applicationName) memory",
                "Tell \(.applicationName) to remember"
            ],
            shortTitle: "Add to Memory",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: RunSkillIntent(),
            phrases: ["Run a \(.applicationName) skill"],
            shortTitle: "Run Skill",
            systemImageName: "wand.and.stars"
        )
    }
}
