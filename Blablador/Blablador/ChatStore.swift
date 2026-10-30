import Combine
import Foundation
import SwiftUI

/// Custom instructions, in an encrypted file (UserDefaults before 3.0).
@MainActor
enum CustomInstructions {
    private static let key = "systemPrompt"
    private static var cached: String?

    private static var fileURL: URL {
        let url = AppFolder.url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("instructions.json")
    }

    static var text: String {
        get {
            if let cached { return cached }
            if let old = UserDefaults.standard.string(forKey: key) {
                text = old
                UserDefaults.standard.removeObject(forKey: key)
                return old
            }
            let saved = EncryptedStorage.read(fileURL).flatMap { try? JSONDecoder().decode([String].self, from: $0).first } ?? ""
            cached = saved
            return saved
        }
        set {
            cached = newValue
            if let data = try? JSONEncoder().encode([newValue]) { EncryptedStorage.write(data, to: fileURL) }
        }
    }
}

/// Chat history shared by every window, so each window can show its own conversation.
@MainActor
final class ConversationLibrary: ObservableObject {
    static let shared = ConversationLibrary()

    @Published var conversations: [Conversation] = []

    private static var storageURL: URL {
        let directory = AppFolder.url
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("conversations.json")
    }

    private init() {
        EncryptedStorage.removeDecryptedCopies()
        Task.detached(priority: .utility) { EncryptedStorage.encryptOldFiles() }
        if let data = EncryptedStorage.read(Self.storageURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        EncryptedStorage.write(data, to: Self.storageURL)
    }
}

/// State of one window: its open conversation, streaming and settings sheet.
@MainActor
final class ChatStore: ObservableObject {
    private let library = ConversationLibrary.shared
    private var libraryObserver: AnyCancellable?

    var conversations: [Conversation] {
        get { library.conversations }
        set { library.conversations = newValue }
    }

    @Published var currentID: UUID?
    @Published var models: [RemoteModel] = []
    @Published var isStreaming = false
    @Published var modelsError: String?
    /// Set by the Settings… menu command (⌘,) to open the settings sheet.
    @Published var settingsRequested = false

    @Published var apiKey: String {
        didSet {
            KeychainHelper.save(apiKey, for: "apiKey")
            NotificationCenter.default.post(name: Self.apiKeyChanged, object: nil)
            userName = ""
            Task {
                await loadModels()
                await loadUserName()
            }
        }
    }

    @AppStorage("selectedModel") var selectedModel: String = BlabladorAPI.defaultModel {
        willSet { objectWillChange.send() }
    }

    /// Name used in the welcome greeting.
    @AppStorage("userName") var userName: String = "" {
        willSet { objectWillChange.send() }
    }

    var systemPrompt: String {
        get { CustomInstructions.text }
        set {
            objectWillChange.send()
            CustomInstructions.text = newValue
        }
    }

    @AppStorage("webSearchEnabled") var webSearchEnabled = true {
        willSet { objectWillChange.send() }
    }

    /// Lets the model run Python on the device (Pyodide) for calculations and plots.
    @AppStorage("pythonEnabled") var pythonEnabled = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("imageModel") var imageModel: String = BlabladorAPI.defaultImageModel {
        willSet { objectWillChange.send() }
    }

    @AppStorage("videoSeconds") var videoSeconds = 4
    @AppStorage("videoAspect") var videoAspect = "16:9"
    var videoAspectName: String {
        BlabladorAPI.videoAspects.first { $0.id == videoAspect }?.name ?? videoAspect
    }
    @AppStorage("imageToolsEnabled") var imageToolsEnabled = true {
        willSet { objectWillChange.send() }
    }

    var imageModelName: String {
        BlabladorAPI.imageModels.first { $0.id == imageModel }?.name ?? imageModel
    }

    private static let maxToolRounds = 4

    private var streamTask: Task<Void, Never>?

    init() {
        apiKey = KeychainHelper.read("apiKey") ?? ""
        libraryObserver = library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // Another window changed the key.
        NotificationCenter.default.addObserver(forName: Self.apiKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = KeychainHelper.read("apiKey"), key != self.apiKey else { return }
                self.apiKey = key
            }
        }
    }

    private static let apiKeyChanged = Notification.Name("BlabladorAPIKeyChanged")

    var api: BlabladorAPI { BlabladorAPI(apiKey: apiKey) }

    var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    var chatModels: [RemoteModel] {
        models.filter(\.isChatCapable).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var selectedModelName: String {
        RemoteModel(id: selectedModel).displayName
    }

    // MARK: - Models

    func loadModels() async {
        guard !apiKey.isEmpty else {
            models = []
            return
        }
        do {
            models = try await api.models()
            modelsError = nil
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Greeting name of the key's owner; left empty when the lookup fails.
    func loadUserName() async {
        // The name comes from Helmholtz Codebase; only Blablador keys belong there.
        guard !apiKey.isEmpty, BlabladorAPI.endpoint == BlabladorAPI.defaultEndpoint,
              let name = try? await api.userName() else { return }
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversations

    func newChat() {
        stop()
        currentID = nil
        pendingKnowledge = []
        pendingWorkspace = nil
    }

    /// Knowledge bases picked before the first message of a new chat.
    @Published private var pendingKnowledge: [UUID] = []

    /// Knowledge bases searched for the current chat.
    var activeKnowledge: [UUID] {
        get {
            let ids = currentID == nil ? pendingKnowledge : current?.knowledge ?? []
            return ids.filter { KnowledgeLibrary.shared.base($0) != nil }
        }
        set {
            if currentID == nil {
                pendingKnowledge = newValue
            } else {
                update { $0.knowledge = newValue }
            }
        }
    }

    func toggleKnowledge(_ id: UUID) {
        if activeKnowledge.contains(id) {
            activeKnowledge.removeAll { $0 == id }
        } else {
            activeKnowledge.append(id)
        }
    }

    func select(_ conversation: Conversation) {
        stop()
        currentID = conversation.id
        selectedModel = conversation.model
    }

    func delete(_ conversation: Conversation) {
        if conversation.id == currentID { newChat() }
        ImageStore.delete(conversation.messages.flatMap(\.images))
        AudioStore.delete(conversation.messages.flatMap(\.audio))
        VideoStore.delete(conversation.messages.flatMap(\.videos))
        conversations.removeAll { $0.id == conversation.id }
        persist()
    }

    func deleteAll() {
        newChat()
        ImageStore.delete(conversations.flatMap { $0.messages.flatMap(\.images) })
        AudioStore.delete(conversations.flatMap { $0.messages.flatMap(\.audio) })
        VideoStore.delete(conversations.flatMap { $0.messages.flatMap(\.videos) })
        conversations.removeAll()
        persist()
    }

    // MARK: - Messaging

    /// Sends a chat message. With `createImage`, the text is used directly as an image prompt;
    /// with `speak`, it is read aloud with Drama 3.
    func send(_ text: String, attachments: [Data] = [], documents: [DocumentAttachment] = [], createImage: Bool = false, createVideo: Bool = false, speak: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || !documents.isEmpty, !isStreaming else { return }

        if currentID == nil {
            let title = !trimmed.isEmpty ? Self.title(for: trimmed) : documents.first?.name ?? "Image"
            var conversation = Conversation(title: title, model: selectedModel)
            conversation.knowledge = pendingKnowledge
            conversation.workspace = pendingWorkspace
            pendingKnowledge = []
            pendingWorkspace = nil
            conversations.insert(conversation, at: 0)
            currentID = conversation.id
            if !trimmed.isEmpty { nameChat(conversation.id, from: trimmed, model: selectedModel) }
        }
        let images = attachments.map(ImageStore.save)
        update { $0.messages.append(ChatMessage(role: .user, content: trimmed, images: images, documents: documents)) }

        if speak, !trimmed.isEmpty {
            makeSpeech(script: trimmed)
        } else if createVideo, !trimmed.isEmpty || !images.isEmpty {
            makeVideo(prompt: trimmed.isEmpty ? Self.continuePrompt : trimmed, firstFrame: images.last)
        } else if createImage {
            makeImage(prompt: trimmed, editing: images.last)
        } else {
            respond()
        }
    }

    /// Image mode: generate a new image, or edit the attached one with Qwen-Image.
    private func makeImage(prompt: String, editing source: String?) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        isStreaming = true
        streamTask = Task {
            do {
                let image = try await runImageTool(
                    name: source == nil ? "generate_image" : "edit_image",
                    prompt: prompt.isEmpty ? "Improve this image" : prompt,
                    source: source,
                    replyID: reply.id
                )
                updateMessage(reply.id) { $0.images.append(image) }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { $0.status = nil }
            isStreaming = false
            persist()
        }
    }

    /// Runs an image tool and returns the stored file name.
    private func runImageTool(name: String, prompt: String, source: String?, replyID: UUID) async throws -> String {
        let data: Data
        if name == "edit_image" {
            guard let source, let original = ImageStore.data(for: source) else {
                throw BlabladorAPIError.http(status: 400, body: "There is no image to edit.")
            }
            updateMessage(replyID) { $0.status = "Editing image with \(BlabladorAPI.imageModels.first { $0.id == BlabladorAPI.imageEditModel }?.name ?? "Qwen-Image")…" }
            data = try await api.editImage(prompt: prompt, image: ImageStore.jpeg(from: original, maxPixelSize: 1024) ?? original)
        } else {
            updateMessage(replyID) { $0.status = "Creating image with \(imageModelName)…" }
            data = try await api.generateImage(model: imageModel, prompt: prompt)
        }
        return ImageStore.save(data)
    }

    static let continuePrompt = "Continue the scene naturally, with matching sound."

    /// The prompt that made a video, to start its continuation from.
    func prompt(forVideo name: String) -> String? {
        guard let messages = current?.messages,
              let index = messages.firstIndex(where: { $0.videos.contains(name) }) else { return nil }
        return messages[..<index].last { $0.role == .user }?.content
    }

    /// Video mode: make a clip with sound from the prompt.
    private func makeVideo(prompt: String, firstFrame: String?) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        isStreaming = true
        let seconds = videoSeconds, aspect = videoAspect
        streamTask = Task {
            do {
                updateMessage(reply.id) { $0.status = "Making a \(seconds)-second video with MiniMax-H3… This takes a few minutes." }
                let frame = firstFrame.flatMap(ImageStore.data(for:)).map { ImageStore.jpeg(from: $0, maxPixelSize: 1920) ?? $0 }
                let data = try await api.generateVideo(prompt: prompt, seconds: seconds, aspect: aspect, firstFrame: frame)
                let name = VideoStore.save(data)
                updateMessage(reply.id) { $0.videos.append(name) }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { $0.status = nil }
            isStreaming = false
            persist()
        }
    }

    /// Speech mode: speak the user's text with the selected voice and delivery settings.
    private func makeSpeech(script: String) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        isStreaming = true
        streamTask = Task {
            do {
                let audio = try await runSpeechTool(script: script, replyID: reply.id)
                updateMessage(reply.id) { $0.audio.append(audio) }
                AudioPlayback.shared.toggle(audio)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { $0.status = nil }
            isStreaming = false
            persist()
        }
    }

    /// Speaks a script with Drama 3 and returns the stored file name.
    private func runSpeechTool(script: String, replyID: UUID) async throws -> String {
        let library = VoiceLibrary.shared
        updateMessage(replyID) { $0.status = "Speaking with \(library.selected.name)…" }
        let data = try await api.speech(text: library.styled(script), voice: library.selected)
        return AudioStore.save(data)
    }

    /// Most recent image in the current conversation, used as the source for edits.
    private var latestImage: String? {
        current?.messages.last { !$0.images.isEmpty }?.images.last
    }

    /// Drops the last assistant reply and asks again.
    func regenerate() {
        guard !isStreaming else { return }
        update { conversation in
            if conversation.messages.last?.role == .assistant {
                conversation.messages.removeLast()
            }
        }
        respond()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        answerApproval(.deny)
    }

    // MARK: - Agent

    @Published private var pendingWorkspace: String?

    /// Folder the agent works in for the current chat.
    var workspace: URL? {
        get {
            (currentID == nil ? pendingWorkspace : current?.workspace).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            if currentID == nil {
                pendingWorkspace = newValue?.path
            } else {
                if let currentID { commandsAllowed.remove(currentID) }
                update {
                    $0.workspace = newValue?.path
                    $0.allowsCommands = nil
                }
            }
        }
    }

    /// Chats whose commands run without asking. Kept in memory only, so it ends when the app quits.
    @Published private var commandsAllowed: Set<UUID> = []

    var allowsCommands: Bool {
        get { currentID.map(commandsAllowed.contains) ?? false }
        set {
            guard let currentID else { return }
            if newValue { commandsAllowed.insert(currentID) } else { commandsAllowed.remove(currentID) }
        }
    }

    /// A shell command or connected-service tool call waiting for the user's OK.
    struct CommandApproval: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var icon = "terminal"
        var confirm = "Run"
    }

    /// Chat and server pairs where the user allowed MCP tool calls without asking.
    private var mcpAllowed: Set<String> = []

    enum ApprovalChoice { case once, always, deny }

    /// A shell command waiting for the user's OK.
    @Published private(set) var commandApproval: CommandApproval?
    private var approvalContinuation: CheckedContinuation<ApprovalChoice, Never>?

    func answerApproval(_ choice: ApprovalChoice) {
        commandApproval = nil
        approvalContinuation?.resume(returning: choice)
        approvalContinuation = nil
    }

    private func approve(_ command: String, in folder: URL) async -> Bool {
        if allowsCommands { return true }
        let choice = await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            commandApproval = CommandApproval(title: "Run this command in \(folder.lastPathComponent)?", detail: command)
        }
        if choice == .always { allowsCommands = true }
        return choice != .deny
    }

    /// Runs Python with Pyodide, recording it as a step; figures are added to the reply as images.
    private func runPython(_ code: String, replyID: UUID) async -> String {
        var step = AgentStep(tool: "python", title: "Ran Python", detail: code)
        updateMessage(replyID) { $0.steps.append(step) }
        updateMessage(replyID) { $0.status = "Running Python…" }
        // Attached documents, as text files in /data.
        var files: [String: String] = [:]
        for document in current?.messages.flatMap(\.documents) ?? [] {
            let name = document.name.replacingOccurrences(of: "/", with: "_")
            files[name.hasSuffix(".txt") ? name : name + ".txt"] = document.text
        }
        func finish(_ state: AgentStep.State, _ result: String) {
            step.state = state
            step.detail = String((code + "\n\n───\n\n" + result).prefix(8_000))
            updateMessage(replyID) { message in
                if let index = message.steps.firstIndex(where: { $0.id == step.id }) { message.steps[index] = step }
            }
        }
        do {
            let result = try await PythonRunner.shared.run(code, files: files)
            let names = result.images.map(ImageStore.save)
            updateMessage(replyID) { $0.images += names }
            var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = result.value, !value.isEmpty, value != "None" { output += (output.isEmpty ? "" : "\n") + "Result: " + value }
            if let error = result.error { output += (output.isEmpty ? "" : "\n") + error }
            if !names.isEmpty { output += "\n[\(names.count) figure(s) shown to the user]" }
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(result.error == nil ? .done : .failed, output.isEmpty ? "(No output)" : output)
            return output.isEmpty ? "The code ran without output." : String(output.suffix(20_000))
        } catch {
            finish(.failed, error.localizedDescription)
            return "Python failed: \(error.localizedDescription)"
        }
    }

    /// Runs a tool of a connected MCP server after the user's OK, recording it as a step.
    private func runMCPTool(_ tool: MCPTool, _ arguments: [String: Any], replyID: UUID) async -> String {
        let server = MCPLibrary.shared.server(tool.server)
        var step = AgentStep(tool: "mcp", title: "\(server?.name ?? "Server"): \(tool.name)")
        updateMessage(replyID) { $0.steps.append(step) }
        func finish(_ state: AgentStep.State, _ detail: String) {
            step.state = state
            step.detail = String(detail.prefix(8_000))
            updateMessage(replyID) { message in
                if let index = message.steps.firstIndex(where: { $0.id == step.id }) { message.steps[index] = step }
            }
        }
        let key = "\(currentID?.uuidString ?? "")|\(tool.server)"
        if server?.askBeforeCalls != false, !mcpAllowed.contains(key) {
            updateMessage(replyID) { $0.status = "Waiting for approval…" }
            let shown = (try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let choice = await withCheckedContinuation { continuation in
                approvalContinuation = continuation
                commandApproval = CommandApproval(title: "Let \(server?.name ?? "this server") use \(tool.name)?", detail: String(shown.prefix(2_000)),
                                                  icon: "puzzlepiece.extension", confirm: "Allow")
            }
            if choice == .always { mcpAllowed.insert(key) }
            guard choice != .deny else {
                finish(.denied, "Not run.")
                return "The user declined this tool call. Ask what to do instead or continue without it."
            }
        }
        updateMessage(replyID) { $0.status = "Using \(tool.name)…" }
        do {
            let result = try await MCPLibrary.shared.call(tool, arguments: arguments)
            finish(result.isError ? .failed : .done, result.text)
            return result.text.isEmpty ? "(The tool returned nothing.)" : String(result.text.prefix(30_000))
        } catch {
            finish(.failed, error.localizedDescription)
            return "Tool failed: \(error.localizedDescription)"
        }
    }

    /// Runs one agent tool, recording it as a step, and returns the output for the model.
    private func runAgentTool(_ name: String, _ arguments: [String: Any], in folder: URL, replyID: UUID) async -> String {
        var step = AgentStep(tool: name, title: AgentTools.title(for: name, arguments))
        updateMessage(replyID) { $0.steps.append(step) }
        func finish(_ state: AgentStep.State, _ detail: String) {
            step.state = state
            step.detail = String(detail.prefix(8_000))
            updateMessage(replyID) { message in
                if let index = message.steps.firstIndex(where: { $0.id == step.id }) { message.steps[index] = step }
            }
        }
        do {
            if name == "run_command" {
                let command = arguments["command"] as? String ?? ""
                updateMessage(replyID) { $0.status = "Waiting for approval…" }
                guard await approve(command, in: folder) else {
                    finish(.denied, "Not run.")
                    return "The user declined to run this command. Ask what to do instead or continue without it."
                }
                updateMessage(replyID) { $0.status = "Running \(command.prefix(60))…" }
                let output = try await AgentTools.runCommand(command, in: folder, timeout: arguments["timeout"] as? Int ?? 120)
                finish(output.hasSuffix("Exit code: 0") ? .done : .failed, output)
                return output
            }
            let output = try AgentTools.run(name, arguments, in: folder)
            finish(.done, output)
            return output
        } catch {
            finish(.failed, error.localizedDescription)
            return "Error: \(error.localizedDescription)"
        }
    }

    private func respond() {
        guard let conversation = current else { return }

        var wire: [[String: Any]] = []
        var system = systemPrompt
        let today = Date().formatted(date: .complete, time: .omitted)
        system += "\n\nToday is \(today)."
        if webSearchEnabled {
            system += WebSearch.systemPrompt
        }
        if pythonEnabled { system += " " + PythonRunner.systemPrompt }
        if imageToolsEnabled {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        if VoiceLibrary.shared.toolsEnabled {
            system += " You can speak aloud with generate_speech when the user asks you to say, read or voice something. Never claim you spoke unless the tool succeeded."
        }
        let memory = MemoryStore.shared
        let question = conversation.messages.last { $0.role == .user }?.content ?? ""
        if memory.enabled { system += "\n\n" + memory.systemPrompt(for: question) }
        let skills = SkillLibrary.shared
        if let skillPrompt = skills.systemPrompt { system += "\n\n" + skillPrompt }
        system += "\n\n" + SkillTools.systemPrompt + " Use search_chats when the user refers to an earlier conversation."
        let folder = workspace
        if let folder { system += "\n\n" + AgentTools.systemPrompt(workspace: folder) }
        system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemText = system
        wire = Self.history(system: systemText, conversation)

        let reply = ChatMessage(role: .assistant, content: "")
        let model = selectedModel
        let knowledge = activeKnowledge
        update {
            $0.model = model
            $0.messages.append(reply)
        }

        isStreaming = true
        var tools: [[String: Any]] = []
        if webSearchEnabled { tools += [WebSearch.tool, WebSearch.imageTool, WebPage.tool] }
        if imageToolsEnabled { tools += [ImageTools.generate, ImageTools.edit] }
        if VoiceLibrary.shared.toolsEnabled { tools.append(SpeechTools.generate) }
        if memory.enabled { tools += [MemoryTools.remember, MemoryTools.forget] }
        tools += [ChatSearch.tool, SkillTools.suggest]
        if pythonEnabled { tools.append(PythonRunner.tool) }
        if !skills.skills.isEmpty { tools.append(SkillTools.use) }
        if folder != nil { tools += AgentTools.definitions }
        streamTask = Task {
            do {
                var wire = wire
                if let compacted = await compact(conversation, model: model, wire: wire, replyID: reply.id) {
                    wire = Self.history(system: systemText, compacted)
                }
                if !knowledge.isEmpty, !question.isEmpty {
                    updateMessage(reply.id) { $0.status = "Searching knowledge…" }
                    do {
                        let citations = try await KnowledgeLibrary.shared.search(question, in: knowledge, api: api)
                        if !citations.isEmpty {
                            updateMessage(reply.id) { $0.citations = citations }
                            let system = (wire[0]["content"] as? String ?? "") + "\n\n" + KnowledgeLibrary.context(for: citations)
                            wire[0]["content"] = system.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } catch {
                        updateMessage(reply.id) { $0.status = "Knowledge search failed, answering without it…" }
                    }
                }
                // PDFs and knowledge excerpts come from outside the chat; see runTurn's memory lock.
                let outsideContent = conversation.messages.contains { !$0.documents.isEmpty }
                    || current?.messages.first { $0.id == reply.id }?.citations.isEmpty == false
                var tools = tools
                let mcpTools = await MCPLibrary.shared.availableTools()
                if !mcpTools.isEmpty {
                    tools += mcpTools.map(\.definition)
                    wire[0]["content"] = (wire[0]["content"] as? String ?? "") + "\n\nTools named <service>__<tool> belong to services the user connected (MCP). Use them when they fit the request."
                }
                let readOutside = try await runTurn(model: model, messages: wire, tools: tools, replyID: reply.id, workspace: folder, outsideContent: outsideContent, mcp: mcpTools)
                learn(question: question, replyID: reply.id, model: model, userOnly: readOutside)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch BlabladorAPIError.http(let status, let body) where status == 400 && body.localizedCaseInsensitiveContains("image") {
                updateMessage(reply.id) {
                    $0.content = "\(RemoteModel(id: model).displayName) can't read images. Pick a vision model such as DeepSeek-V4.1-Flash or Qwen3.8-27B."
                    $0.isError = true
                }
            } catch {
                updateMessage(reply.id) {
                    $0.content = error.localizedDescription
                    $0.isError = true
                }
            }
            updateMessage(reply.id) { message in
                message.status = nil
                if message.content.isEmpty, message.images.isEmpty, message.audio.isEmpty, message.videos.isEmpty, message.steps.isEmpty, !Task.isCancelled {
                    message.content = "No response from the model."
                    message.isError = true
                }
            }
            isStreaming = false
            persist()
        }
    }

    /// Replaces a new chat's provisional title (its first words) with a short name from the helper model.
    private func nameChat(_ id: UUID, from text: String, model: String) {
        let provisional = Self.title(for: text)
        let api = api
        Task {
            let system = "Give a chat a short title that says what it is about, like a heading: two to six words, in the language of the user's message, without quotes or final period. Don't copy the start of the message. Reply with only the title."
            guard let reply = try? await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: String(text.prefix(2000))) else { return }
            var name = Self.splitThinking(reply).answer.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»*#.")).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 80, !name.contains("\n"),
                  let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].title == provisional else { return }
            conversations[index].title = name
            persist()
        }
    }

    // MARK: - Long chats

    /// Above this many characters (about 30,000 tokens) older messages are replaced by a summary.
    private static let compactionThreshold = 120_000
    /// Messages always sent in full.
    private static let recentMessages = 8

    /// The system prompt (with the summary of older messages, if any) and the messages after the summary.
    private static func history(system: String, _ conversation: Conversation) -> [[String: Any]] {
        var system = system
        let covered = min(conversation.summaryCount ?? 0, conversation.messages.count)
        if let summary = conversation.summary, covered > 0 {
            system += "\n\nSummary of the earlier part of this chat (those messages are not shown):\n" + summary
        }
        return [["role": "system", "content": system]]
            + conversation.messages[covered...].filter { !$0.isError }.map(Self.wireMessage)
    }

    /// Rough size of a request: text, plus about 3,000 characters per image.
    private static func size(_ wire: [[String: Any]]) -> Int {
        wire.reduce(0) { total, message in
            if let text = message["content"] as? String { return total + text.count }
            let parts = message["content"] as? [[String: Any]] ?? []
            return total + parts.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 3_000) }
        }
    }

    /// Summarises everything but the most recent messages with the helper model when the chat got too long;
    /// returns the conversation with the new summary, or nil when nothing changed.
    private func compact(_ conversation: Conversation, model: String, wire: [[String: Any]], replyID: UUID) async -> Conversation? {
        let end = conversation.messages.count - Self.recentMessages
        let covered = conversation.summaryCount ?? 0
        guard Self.size(wire) > Self.compactionThreshold, end > covered else { return nil }
        updateMessage(replyID) { $0.status = "Summarizing earlier messages…" }
        var transcript = conversation.summary.map { "Summary so far:\n\($0)\n\n" } ?? ""
        for message in conversation.messages[covered..<end] where !message.isError {
            let who = message.role == .user ? "User" : "Assistant"
            var text = message.content
            if !message.documents.isEmpty { text = message.documents.map { "[Attached \($0.name)]" }.joined(separator: " ") + "\n" + text }
            if !message.images.isEmpty { text = "[\(message.images.count) image(s)]\n" + text }
            transcript += "\(who): \(text.prefix(6_000))\n\n"
        }
        let system = "Summarize this conversation so an assistant can continue it without the original messages. Keep facts, decisions, names, numbers, code and file names, open questions and what the user wants, in the conversation's language. At most 500 words. Reply with only the summary."
        guard let reply = try? await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: String(transcript.suffix(300_000))) else {
            return nil
        }
        let summary = Self.splitThinking(reply).answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return nil }
        conversations[index].summary = summary
        conversations[index].summaryCount = end
        persist()
        var compacted = conversation
        compacted.summary = summary
        compacted.summaryCount = end
        return compacted
    }

    /// Saves what's worth keeping from the exchange to long-term memory, in the background.
    private func learn(question: String, replyID: UUID, model: String, userOnly: Bool) {
        let memory = MemoryStore.shared
        guard memory.enabled, memory.learnsAutomatically, !question.isEmpty,
              let reply = conversations.lazy.flatMap(\.messages).first(where: { $0.id == replyID }),
              !reply.isError, !reply.content.isEmpty else { return }
        let api = api
        Task {
            guard let facts = try? await memory.learn(question: question, reply: userOnly ? nil : reply.content, api: api, model: model),
                  !facts.isEmpty else { return }
            updateMessage(replyID) { $0.remembered += facts }
            persist()
        }
    }

    /// Streams the reply, running web searches whenever the model asks for them. Returns whether it read outside content.
    /// Memory changes are refused once the reply has read outside content (web results, PDFs, knowledge bases,
    /// files), so text planted there can't write itself into every future chat.
    @discardableResult
    private func runTurn(model: String, messages: [[String: Any]], tools: [[String: Any]], replyID: UUID, workspace: URL? = nil, outsideContent: Bool = false, mcp: [MCPTool] = []) async throws -> Bool {
        var outsideContent = outsideContent
        var messages = messages
        var tools = tools
        let maxRounds = workspace == nil ? Self.maxToolRounds : AgentTools.maxRounds

        for round in 0...maxRounds {
            let isFinalRound = round == maxRounds
            if isFinalRound {
                // Keep the tools declared (removing them makes DeepSeek print raw tool markup),
                // but tell the model to answer with what it has.
                messages.append(["role": "user", "content": "Stop using tools now and write the final answer using the results above."])
            }
            let prefix = current?.messages.first { $0.id == replyID }?.content ?? ""
            let reasoningPrefix = current?.messages.first { $0.id == replyID }?.reasoning ?? ""
            var text = ""
            var reasoning = ""
            var calls: [BlabladorAPI.ToolCall] = []
            do {
                for try await event in api.streamChat(model: model, messages: messages, tools: tools) {
                    switch event {
                    case let .content(delta):
                        text += delta
                        let (thinking, answer) = Self.splitThinking(text)
                        let visible = Self.stripToolMarkup(answer)
                        updateMessage(replyID) {
                            $0.status = nil
                            $0.content = prefix + visible
                            if !thinking.isEmpty { $0.reasoning = Self.joined(reasoningPrefix, reasoning + thinking) }
                        }
                    case let .reasoning(delta):
                        reasoning += delta
                        updateMessage(replyID) {
                            $0.status = nil
                            $0.reasoning = Self.joined(reasoningPrefix, reasoning)
                        }
                    case let .toolCalls(toolCalls):
                        calls = toolCalls
                    }
                }
            } catch BlabladorAPIError.http(let status, let body) where status == 400 && !tools.isEmpty && round == 0 && !body.localizedCaseInsensitiveContains("image") {
                // Model without tool support: answer without web search.
                tools = []
                continue
            }

            if isFinalRound || (calls.isEmpty && Self.containsToolMarkup(text)) {
                // Model still wants to search; nothing more to run.
                if Self.stripToolMarkup(text).isEmpty {
                    updateMessage(replyID) { $0.content = prefix }
                }
                return outsideContent
            }
            guard !calls.isEmpty else { return outsideContent }

            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls.map(\.wire)]
            assistant["content"] = text.isEmpty ? NSNull() : text
            messages.append(assistant)
            // Preambles like "Let me look that up" are status, not part of the answer;
            // an agent's notes between steps are kept.
            let note = Self.stripToolMarkup(text)
            updateMessage(replyID) { $0.content = workspace != nil && !note.isEmpty ? prefix + note + "\n\n" : prefix }

            for call in calls {
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                let query = arguments?["query"] as? String ?? ""
                let prompt = arguments?["prompt"] as? String ?? ""
                let script = arguments?["script"] as? String ?? ""

                let output: String
                if call.name == "generate_image" || call.name == "edit_image", !prompt.isEmpty {
                    do {
                        let image = try await runImageTool(name: call.name, prompt: prompt, source: latestImage, replyID: replyID)
                        updateMessage(replyID) { $0.images.append(image) }
                        output = "The image was created and is shown to the user. Do not include it or a link in your answer; just briefly comment on it."
                    } catch {
                        output = "Image tool failed: \(error.localizedDescription)"
                    }
                } else if call.name == "generate_speech", !script.isEmpty {
                    do {
                        let audio = try await runSpeechTool(script: script, replyID: replyID)
                        updateMessage(replyID) { $0.audio.append(audio) }
                        output = "The speech was created and the user can play it. Don't repeat the script; just briefly comment on it."
                    } catch {
                        output = "Speech tool failed: \(error.localizedDescription)"
                    }
                } else if let workspace, AgentTools.names.contains(call.name) {
                    outsideContent = true
                    output = await runAgentTool(call.name, arguments ?? [:], in: workspace, replyID: replyID)
                } else if call.name == "use_skill", let name = arguments?["name"] as? String {
                    if let skill = SkillLibrary.shared.skill(named: name) {
                        updateMessage(replyID) { if !$0.skillsUsed.contains(skill.name) { $0.skillsUsed.append(skill.name) } }
                        output = "Instructions of the skill \"\(skill.name)\":\n\n\(skill.instructions)"
                    } else {
                        output = "There is no skill called \"\(name)\"."
                    }
                } else if call.name == "suggest_skill", let name = arguments?["name"] as? String,
                          let instructions = arguments?["instructions"] as? String, !instructions.isEmpty {
                    let skill = Skill(name: name, description: arguments?["description"] as? String ?? "", instructions: instructions)
                    updateMessage(replyID) { $0.suggestedSkills.append(skill) }
                    output = "The suggestion is shown to the user with a Save button; it is not saved until they press it. Don't repeat the instructions; mention it in one sentence."
                } else if call.name == "search_chats", !query.isEmpty {
                    outsideContent = true
                    updateMessage(replyID) { $0.status = "Searching earlier chats…" }
                    output = ChatSearch.search(query, in: library.conversations, excluding: currentID)
                } else if call.name == "remember" || call.name == "forget", outsideContent {
                    output = "Memory can't be changed in a reply that used web results, documents, knowledge bases or files, because they could contain planted instructions. Tell the user they can ask again in a new message without them, or edit memories in Settings → Memory."
                } else if call.name == "remember", let fact = arguments?["fact"] as? String, MemoryStore.shared.enabled {
                    if MemoryStore.shared.add(fact) {
                        updateMessage(replyID) { $0.remembered.append(fact.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        output = "Saved to memory."
                    } else {
                        output = "Already remembered or empty; nothing saved."
                    }
                } else if call.name == "forget", MemoryStore.shared.enabled,
                          let number = (arguments?["number"] as? Int) ?? Int(arguments?["number"] as? String ?? "") {
                    if let forgotten = MemoryStore.shared.forget(number: number) {
                        updateMessage(replyID) { $0.forgotten.append(forgotten.text) }
                        output = "Forgot: \(forgotten.text). The numbers of later memories moved up by one."
                    } else {
                        output = "There is no memory number \(number)."
                    }
                } else if call.name == "image_search", !query.isEmpty {
                    outsideContent = true
                    updateMessage(replyID) { $0.status = "Searching pictures of “\(query)”" }
                    do {
                        let images = try await WebSearch.searchImages(query)
                        updateMessage(replyID) { message in
                            message.webImages += images.filter { image in !message.webImages.contains { $0.image == image.image } }
                        }
                        output = images.isEmpty
                            ? "No pictures found for \"\(query)\"."
                            : "\(images.count) pictures are shown to the user: " + images.map(\.title).joined(separator: "; ") + ". Don't include image links in your answer."
                    } catch {
                        output = "Image search failed: \(error.localizedDescription)"
                    }
                } else if call.name == "run_python", let code = arguments?["code"] as? String, !code.isEmpty {
                    outsideContent = true
                    output = await runPython(code, replyID: replyID)
                } else if let tool = mcp.first(where: { $0.qualifiedName == call.name }) {
                    outsideContent = true
                    output = await runMCPTool(tool, arguments ?? [:], replyID: replyID)
                } else if call.name == "read_page", let address = arguments?["url"] as? String {
                    outsideContent = true
                    updateMessage(replyID) { $0.status = "Reading \(URL(string: address)?.host() ?? address)…" }
                    do {
                        let page = try await WebPage.read(address)
                        var number = 0
                        updateMessage(replyID) { message in
                            if let index = message.sources.firstIndex(where: { $0.url == page.url.absoluteString }) {
                                number = index + 1
                            } else {
                                message.sources.append(SearchResult(title: page.title, url: page.url.absoluteString, content: nil))
                                number = message.sources.count
                            }
                        }
                        output = "[\(number)] \(page.title)\nURL: \(page.url.absoluteString)\n\n\(page.text.isEmpty ? "(No readable text on this page.)" : page.text)"
                    } catch {
                        output = "Could not read the page: \(error.localizedDescription)"
                    }
                } else if call.name == "web_search", !query.isEmpty {
                    outsideContent = true
                    updateMessage(replyID) { $0.status = "Searching “\(query)”" }
                    do {
                        let results = try await WebSearch.search(
                            query,
                            category: arguments?["category"] as? String,
                            timeRange: arguments?["time_range"] as? String
                        )
                        var numbered: [(number: Int, result: SearchResult)] = []
                        updateMessage(replyID) { message in
                            for result in results {
                                if let index = message.sources.firstIndex(where: { $0.url == result.url }) {
                                    numbered.append((index + 1, result))
                                } else {
                                    message.sources.append(result)
                                    numbered.append((message.sources.count, result))
                                }
                            }
                        }
                        output = WebSearch.toolOutput(query: query, results: numbered)
                    } catch {
                        output = "Search failed: \(error.localizedDescription)"
                    }
                } else {
                    output = "Unknown tool \(call.name)."
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
            updateMessage(replyID) { $0.status = "Thinking…" }
        }
        return outsideContent
    }

    /// User attachments are sent as base64 images; generated images are only mentioned in text.
    /// Attached PDFs are sent as text ahead of the user's message.
    private static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        var text = message.content
        if !message.documents.isEmpty {
            let documents = message.documents.map { "<document name=\"\($0.name)\">\n\($0.text)\n</document>" }
            text = (documents + [text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        guard message.role == .user, !message.images.isEmpty else {
            var content = text
            if message.role == .assistant, !message.images.isEmpty {
                content = "[Generated image]\n" + content
            }
            if message.role == .assistant, !message.audio.isEmpty {
                content = "[Generated speech]\n" + content
            }
            if message.role == .assistant, !message.steps.isEmpty {
                // Earlier tool calls, so follow-ups know what was already done.
                content = "[Actions taken: " + message.steps.map(\.title).joined(separator: "; ") + "]\n" + content
            }
            return ["role": message.role.rawValue, "content": content]
        }
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for name in message.images {
            guard let data = ImageStore.data(for: name), let jpeg = ImageStore.jpeg(from: data) else { continue }
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        return ["role": "user", "content": parts]
    }

    private static let toolMarkupPattern = #"<[｜|]\s*DSML\s*[｜|][\s\S]*$"#

    private static func containsToolMarkup(_ text: String) -> Bool {
        text.range(of: toolMarkupPattern, options: .regularExpression) != nil
    }

    /// Splits a `<think>…</think>` block some models put at the start of their answer from the answer itself.
    static func splitThinking(_ text: String) -> (thinking: String, answer: String) {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix("<think>") else { return ("", text) }
        let body = trimmed.dropFirst("<think>".count)
        guard let end = body.range(of: "</think>") else { return (String(body), "") }
        return (String(body[..<end.lowerBound]), String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Thinking from earlier tool rounds, then this round's.
    static func joined(_ earlier: String, _ new: String) -> String {
        earlier.isEmpty ? new : earlier + "\n\n" + new
    }

    /// Removes raw tool-call markup some models emit as text instead of structured tool calls.
    private static func stripToolMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: toolMarkupPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func update(_ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        change(&conversations[index])
        conversations[index].updatedAt = Date()
        persist()
    }

    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        for c in conversations.indices {
            if let m = conversations[c].messages.firstIndex(where: { $0.id == id }) {
                change(&conversations[c].messages[m])
                return
            }
        }
    }

    private func persist() {
        library.persist()
    }

    private static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}
