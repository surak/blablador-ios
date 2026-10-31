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
            conversations = saved.map(Self.markingInterrupted)
        }
    }

    /// Replies left empty when the app quit or was stopped in the background are marked, so they don't look like
    /// they are still being written.
    static func markingInterrupted(_ conversation: Conversation) -> Conversation {
        var conversation = conversation
        // Titles that are a refusal of the title helper become the first words of the chat again.
        if ChatStore.isRefusal(conversation.title), let first = conversation.messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            let line = first.split(separator: "\n").first.map(String.init) ?? first
            conversation.title = line.count > 40 ? String(line.prefix(40)) + "…" : line
        }
        for index in conversation.messages.indices {
            let message = conversation.messages[index]
            if message.role == .assistant, message.content.isEmpty, !message.isError, message.images.isEmpty, message.audio.isEmpty,
               message.videos.isEmpty, message.steps.isEmpty {
                conversation.messages[index].content = "The reply was interrupted. Tap Regenerate to try again."
                conversation.messages[index].isError = true
            }
        }
        return conversation
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
    /// Replies being written, per chat; they keep going when the user switches chats.
    @Published private var running: [UUID: Task<Void, Never>] = [:]
    /// The open chat is writing a reply.
    var isStreaming: Bool { currentID.map { running[$0] != nil } ?? false }
    /// Some chat is writing a reply.
    var isBusy: Bool { !running.isEmpty }
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

    /// Tool rounds per reply; a reply with a plan may take more.
    private static let maxToolRounds = 8
    private static let maxPlanRounds = 25

    /// Runs the work of a reply for a chat. On iOS it asks for time to finish when the app goes to the background.
    private func start(_ chat: UUID?, _ work: @escaping @MainActor () async -> Void) {
        guard let chat else { return }
#if os(iOS)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Reply")
#endif
        var task: Task<Void, Never>!
        task = Task {
            await work()
            if running[chat] == task { running[chat] = nil }
#if os(iOS)
            UIApplication.shared.endBackgroundTask(background)
#endif
            TaskScheduler.shared.check()
        }
        running[chat] = task
    }

    /// The message with this id, in any chat.
    func message(_ id: UUID) -> ChatMessage? {
        for conversation in conversations {
            if let message = conversation.messages.first(where: { $0.id == id }) { return message }
        }
        return nil
    }

    private func chat(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    private func chat(containing messageID: UUID) -> Conversation? {
        conversations.first { $0.messages.contains { $0.id == messageID } }
    }

    private static var appIsActive: Bool {
#if os(iOS)
        UIApplication.shared.applicationState == .active
#else
        NSApplication.shared.isActive
#endif
    }

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
        currentID = conversation.id
        selectedModel = conversation.model
    }

    func delete(_ conversation: Conversation) {
        running[conversation.id]?.cancel()
        if conversation.id == currentID { newChat() }
        ImageStore.delete(conversation.allMessages.flatMap(\.images))
        DataFiles.delete(conversation.allMessages.flatMap(\.documents).compactMap(\.dataFile))
        AudioStore.delete(conversation.allMessages.flatMap(\.audio))
        VideoStore.delete(conversation.allMessages.flatMap(\.videos))
        conversations.removeAll { $0.id == conversation.id }
        persist()
    }

    func deleteAll() {
        running.values.forEach { $0.cancel() }
        newChat()
        ImageStore.delete(conversations.flatMap { $0.allMessages.flatMap(\.images) })
        DataFiles.delete(conversations.flatMap { $0.allMessages.flatMap(\.documents).compactMap(\.dataFile) })
        AudioStore.delete(conversations.flatMap { $0.allMessages.flatMap(\.audio) })
        VideoStore.delete(conversations.flatMap { $0.allMessages.flatMap(\.videos) })
        conversations.removeAll()
        persist()
    }

    // MARK: - Messaging

    /// Sends a chat message. With `createImage`, the text is used directly as an image prompt;
    /// with `speak`, it is read aloud with Drama 3.
    func send(_ text: String, attachments: [Data] = [], documents: [DocumentAttachment] = [], mentions: [Mention] = [], createImage: Bool = false, createVideo: Bool = false, speak: Bool = false) {
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
        var message = ChatMessage(role: .user, content: trimmed, images: images, documents: documents)
        message.mentions = mentions
        update { $0.messages.append(message) }
        // A mentioned knowledge base stays on for the chat, like one picked with #.
        for mention in mentions where mention.kind == .knowledge {
            if let id = UUID(uuidString: mention.value), !activeKnowledge.contains(id) { toggleKnowledge(id) }
        }

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
        start(currentID) { [self] in
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
        let seconds = videoSeconds, aspect = videoAspect
        start(currentID) { [self] in
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
            persist()
        }
    }

    /// Speech mode: speak the user's text with the selected voice and delivery settings.
    private func makeSpeech(script: String) {
        let reply = ChatMessage(role: .assistant, content: "")
        update { $0.messages.append(reply) }
        start(currentID) { [self] in
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

    /// Most recent image in the conversation of a reply, used as the source for edits.
    private func latestImage(for replyID: UUID) -> String? {
        chat(containing: replyID)?.messages.last { !$0.images.isEmpty }?.images.last
    }

    /// Drops the last assistant reply and asks again.
    /// Answers the last message again; the previous answer stays as an earlier version. With `model`, that model
    /// becomes the chat's model first.
    func regenerate(with model: String? = nil) {
        guard !isStreaming, let messages = current?.messages, let last = messages.last, last.role == .assistant else { return }
        if let model { selectedModel = model }
        let (alternatives, version) = Self.versions(replacing: Array(messages[(messages.count - 1)...]))
        update { conversation in
            conversation.messages.removeLast()
            Self.dropSummary(of: &conversation, from: conversation.messages.count)
        }
        respond(alternatives: alternatives, version: version)
    }

    // MARK: - Edit and versions

    /// Sends a changed version of an earlier message of the user; the old one and everything after it stay as an
    /// earlier version, reachable with the arrows under the message.
    func edit(_ messageID: UUID, to text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !text.isEmpty, let messages = current?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].role == .user else { return }
        var edited = ChatMessage(role: .user, content: text, images: messages[index].images, documents: messages[index].documents)
        edited.mentions = messages[index].mentions
        (edited.alternatives, edited.version) = Self.versions(replacing: Array(messages[index...]))
        update { conversation in
            conversation.messages = Array(conversation.messages[..<index]) + [edited]
            Self.dropSummary(of: &conversation, from: index)
        }
        respond()
    }

    /// Shows the previous (-1) or next (+1) version of the chat from this message on.
    func showVersion(of messageID: UUID, offset: Int) {
        guard !isStreaming, let messages = current?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              let switched = Self.messages(messages, showingVersion: offset, at: index) else { return }
        update { conversation in
            conversation.messages = switched
            Self.dropSummary(of: &conversation, from: index)
        }
    }

    /// The chat with the version `offset` steps away shown from `index` on, or nil when there is none.
    static func messages(_ messages: [ChatMessage], showingVersion offset: Int, at index: Int) -> [ChatMessage]? {
        var currentTail = Array(messages[index...])
        let others = currentTail[0].alternatives
        currentTail[0].alternatives = []
        let all = (others + [currentTail]).sorted { $0[0].version < $1[0].version }
        guard let position = all.firstIndex(where: { $0[0].id == messages[index].id }), all.indices.contains(position + offset) else { return nil }
        var shown = all[position + offset]
        shown[0].alternatives = all.enumerated().filter { $0.offset != position + offset }.map(\.element)
        return Array(messages[..<index]) + shown
    }

    /// Versions to keep when `tail` is replaced: its own earlier versions plus itself, and the next version number.
    static func versions(replacing tail: [ChatMessage]) -> (alternatives: [[ChatMessage]], version: Int) {
        var old = tail
        let earlier = old[0].alternatives
        old[0].alternatives = []
        let all = earlier + [old]
        return (all, (all.map { $0[0].version }.max() ?? 0) + 1)
    }

    /// A summary of messages that changed no longer fits; long chats are summarised again when needed.
    private static func dropSummary(of conversation: inout Conversation, from index: Int) {
        if let count = conversation.summaryCount, count > index {
            conversation.summary = nil
            conversation.summaryCount = nil
        }
    }

    /// Stops the open chat's reply.
    func stop() {
        guard let currentID else { return }
        running[currentID]?.cancel()
        running[currentID] = nil
        for approval in approvals where approval.chat == currentID { answer(approval.id, .deny) }
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
                if let currentID { chatAllowed = chatAllowed.filter { !$0.hasPrefix("\(currentID)|") } }
                update {
                    $0.workspace = newValue?.path
                    $0.allowsCommands = nil
                }
            }
        }
    }

    /// Kinds of tools the user allowed for one chat ("<chat>|<kind>"), until the app quits.
    @Published private var chatAllowed: Set<String> = []

    /// Shell commands run without asking in the open chat.
    var allowsCommands: Bool {
        get { currentID.map { chatAllowed.contains("\($0)|command") } ?? false || ToolPermissions.shared.rule("command") == .allow }
        set {
            guard let currentID else { return }
            if newValue { chatAllowed.insert("\(currentID)|command") } else { chatAllowed.remove("\(currentID)|command") }
        }
    }

    /// A tool call waiting for the user's OK.
    struct CommandApproval: Identifiable {
        let id = UUID()
        let chat: UUID
        let kind: String
        let title: String
        let detail: String
        var icon = "terminal"
        var confirm = "Run"
    }

    enum ApprovalChoice { case once, chat, always, deny }

    /// Tool calls waiting for the user's OK, from any chat; the open chat shows its first one.
    @Published private(set) var approvals: [CommandApproval] = []
    private var approvalContinuations: [UUID: CheckedContinuation<ApprovalChoice, Never>] = [:]

    var commandApproval: CommandApproval? { approvals.first { $0.chat == currentID } }

    func answerApproval(_ choice: ApprovalChoice) {
        if let approval = commandApproval { answer(approval.id, choice) }
    }

    private func answer(_ id: UUID, _ choice: ApprovalChoice) {
        approvals.removeAll { $0.id == id }
        approvalContinuations.removeValue(forKey: id)?.resume(returning: choice)
    }

    /// Whether a tool of this kind may run: by its rule in Settings → Permissions, the user's earlier "Allow for this
    /// chat", or by asking now.
    private func authorize(_ kind: String, chat: UUID, title: String, detail: String, icon: String, confirm: String = "Allow") async -> Bool {
        let permissions = ToolPermissions.shared
        switch permissions.rule(kind) {
        case .never: return false
        case .allow: return true
        case .ask: break
        }
        if chatAllowed.contains("\(chat)|\(kind)") { return true }
        if chat != currentID || !Self.appIsActive {
            Notifier.notify(title: "Blablador needs your OK", body: title, chat: chat)
        }
        let approval = CommandApproval(chat: chat, kind: kind, title: title, detail: String(detail.prefix(2_000)), icon: icon, confirm: confirm)
        let choice = await withCheckedContinuation { continuation in
            approvalContinuations[approval.id] = continuation
            approvals.append(approval)
        }
        switch choice {
        case .chat: chatAllowed.insert("\(chat)|\(kind)")
        case .always: permissions.set(kind, .allow)
        default: break
        }
        return choice != .deny
    }

    /// Runs Python with Pyodide, recording it as a step; figures are added to the reply as images.
    private func runPython(_ code: String, replyID: UUID) async -> (String, AgentStep.State) {
        var step = AgentStep(tool: "python", title: "Ran Python", detail: code)
        updateMessage(replyID) { $0.steps.append(step) }
        updateMessage(replyID) { $0.status = "Running Python…" }
        // Attached documents, as text files in /data.
        var files: [String: Data] = [:]
        for document in chat(containing: replyID)?.messages.flatMap(\.documents) ?? [] {
            let name = document.name.replacingOccurrences(of: "/", with: "_")
            if let stored = document.dataFile, let data = DataFiles.data(for: stored) {
                files[name] = data
            } else {
                files[name.hasSuffix(".txt") ? name : name + ".txt"] = Data(document.text.utf8)
            }
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
            let state: AgentStep.State = result.error == nil ? .done : .failed
            finish(state, output.isEmpty ? "(No output)" : output)
            return (output.isEmpty ? "The code ran without output." : String(output.suffix(20_000)), state)
        } catch {
            finish(.failed, error.localizedDescription)
            return ("Python failed: \(error.localizedDescription)", .failed)
        }
    }

    /// Runs a tool of a connected MCP server after the user's OK, recording it as a step.
    private func runMCPTool(_ tool: MCPTool, _ arguments: [String: Any], replyID: UUID, chatID: UUID) async -> (String, AgentStep.State) {
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
        let shown = (try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if ToolPermissions.shared.rule("mcp:\(tool.server)") != .allow { updateMessage(replyID) { $0.status = "Waiting for approval…" } }
        guard await authorize("mcp:\(tool.server)", chat: chatID, title: "Let \(server?.name ?? "this server") use \(tool.name)?", detail: shown, icon: "puzzlepiece.extension") else {
            finish(.denied, "Not run.")
            return ("The user declined this tool call. Ask what to do instead or continue without it.", .denied)
        }
        updateMessage(replyID) { $0.status = "Using \(tool.name)…" }
        do {
            let result = try await MCPLibrary.shared.call(tool, arguments: arguments)
            finish(result.isError ? .failed : .done, result.text)
            return (result.text.isEmpty ? "(The tool returned nothing.)" : String(result.text.prefix(30_000)), result.isError ? .failed : .done)
        } catch {
            finish(.failed, error.localizedDescription)
            return ("Tool failed: \(error.localizedDescription)", .failed)
        }
    }

    /// Runs one agent tool, recording it as a step, and returns the output for the model.
    private func runAgentTool(_ name: String, _ arguments: [String: Any], in folder: URL, replyID: UUID, chatID: UUID) async -> (String, AgentStep.State) {
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
                if !allowsCommands { updateMessage(replyID) { $0.status = "Waiting for approval…" } }
                guard await authorize("command", chat: chatID, title: "Run this command in \(folder.lastPathComponent)?", detail: command, icon: "terminal", confirm: "Run") else {
                    finish(.denied, "Not run.")
                    return ("The user declined to run this command. Ask what to do instead or continue without it.", .denied)
                }
                updateMessage(replyID) { $0.status = "Running \(command.prefix(60))…" }
                let output = try await AgentTools.runCommand(command, in: folder, timeout: arguments["timeout"] as? Int ?? 120)
                let state: AgentStep.State = output.hasSuffix("Exit code: 0") ? .done : .failed
                finish(state, output)
                return (output, state)
            }
            if name == "write_file" || name == "edit_file" {
                let path = arguments["path"] as? String ?? ""
                guard await authorize("files", chat: chatID, title: "\(name == "write_file" ? "Write" : "Edit") \(path)?", detail: String((arguments["content"] as? String ?? arguments["new_text"] as? String ?? "").prefix(2_000)), icon: "doc.badge.gearshape") else {
                    finish(.denied, "Not changed.")
                    return ("The user declined this change. Ask what to do instead or continue without it.", .denied)
                }
            }
            let output = try AgentTools.run(name, arguments, in: folder)
            finish(.done, output)
            return (output, .done)
        } catch {
            finish(.failed, error.localizedDescription)
            return ("Error: \(error.localizedDescription)", .failed)
        }
    }

    private func respond(alternatives: [[ChatMessage]] = [], version: Int = 1, in chatID: UUID? = nil, task: ScheduledTask? = nil) {
        guard let chatID = chatID ?? currentID, let conversation = chat(chatID) else { return }
        let lastUser = conversation.messages.last { $0.role == .user }
        let question = lastUser?.content ?? ""
        let mentions = lastUser?.mentions ?? []
        let mentioned = Set(mentions.filter { $0.kind == .tool }.map(\.value))
        let useWeb = webSearchEnabled || mentioned.contains("web")
        let usePython = pythonEnabled || mentioned.contains("python")
        let useDevice = DeviceTools.enabled || mentioned.contains("device")
        let useImages = imageToolsEnabled || mentioned.contains("image")

        var system = systemPrompt
        system += "\n\nToday is \(Date().formatted(date: .complete, time: .omitted)), local time \(Date().formatted(date: .omitted, time: .shortened))."
        if useWeb {
            system += WebSearch.systemPrompt
        }
        if usePython { system += " " + PythonRunner.systemPrompt }
        if useImages {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        if VoiceLibrary.shared.toolsEnabled {
            system += " You can speak aloud with generate_speech when the user asks you to say, read or voice something. Never claim you spoke unless the tool succeeded."
        }
        if useDevice { system += " " + DeviceTools.systemPrompt }
        system += " " + PlanTools.systemPrompt
        system += " Use schedule_task when the user wants something done later or regularly."
        let memory = MemoryStore.shared
        let skills = SkillLibrary.shared
        if let skillPrompt = skills.systemPrompt { system += "\n\n" + skillPrompt }
        system += "\n\n" + SkillTools.systemPrompt + " Use search_chats when the user refers to an earlier conversation."
        let folder = conversation.workspace.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { system += "\n\n" + AgentTools.systemPrompt(workspace: folder) }
        if let hint = Self.mentionPrompt(mentions) { system += "\n\n" + hint }
        if let task {
            system += "\n\nThis message is a scheduled task the user set up earlier (\"\(task.title)\", \(task.scheduleText.lowercased())); it runs now while they aren't watching, and your answer is shown as a notification. Do all of it without asking questions. If it is a reminder, reply with the reminder itself, addressed to the user, e.g. \"Time to call Maria.\" Write the result so it reads well on its own."
        }
        system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemText = system

        let model = selectedModel
        var reply = ChatMessage(role: .assistant, content: "")
        reply.alternatives = alternatives
        reply.version = version
        reply.trace = Trace(model: model)
        reply.skillsUsed = mentions.filter { $0.kind == .skill }.compactMap { skills.skill(named: $0.value)?.name }
        let knowledge = (conversation.knowledge ?? []).filter { KnowledgeLibrary.shared.base($0) != nil }
        updateChat(chatID) {
            $0.model = model
            $0.messages.append(reply)
        }

        var tools: [[String: Any]] = []
        if useWeb { tools += [WebSearch.tool, WebSearch.imageTool, WebPage.tool] }
        if useImages { tools += [ImageTools.generate, ImageTools.edit] }
        if VoiceLibrary.shared.toolsEnabled { tools.append(SpeechTools.generate) }
        if memory.enabled { tools += [MemoryTools.remember, MemoryTools.forget] }
        tools += [ChatSearch.tool, SkillTools.suggest, PlanTools.tool, TaskScheduler.tool]
        if usePython { tools.append(PythonRunner.tool) }
        if useDevice { tools += DeviceTools.definitions }
        if !skills.skills.isEmpty { tools.append(SkillTools.use) }
        if folder != nil { tools += AgentTools.definitions }
        tools = ToolPermissions.shared.filter(tools)
        let api = api
        start(chatID) { [self] in
            let started = Date()
            var readOutside = false
            do {
                // Memories go last in the system prompt; with many, picking the relevant ones may need an embedding.
                var systemText = systemText
                if memory.enabled { systemText += "\n\n" + (await memory.systemPrompt(for: question, api: api)) }
                var wire = Self.history(system: systemText, conversation)
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
                    || message(reply.id)?.citations.isEmpty == false
                var tools = tools
                let mcpTools = await MCPLibrary.shared.availableTools().filter { ToolPermissions.shared.rule("mcp:\($0.server)") != .never }
                if !mcpTools.isEmpty {
                    tools += mcpTools.map(\.definition)
                    wire[0]["content"] = (wire[0]["content"] as? String ?? "") + "\n\nTools named <service>__<tool> belong to services the user connected (MCP). Use them when they fit the request."
                }
                readOutside = try await runTurn(model: model, messages: wire, tools: tools, replyID: reply.id, chatID: chatID, workspace: folder, outsideContent: outsideContent, mcp: mcpTools)
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
            let cancelled = Task.isCancelled
            updateMessage(reply.id) { message in
                message.status = nil
                message.trace?.seconds = Date().timeIntervalSince(started)
                for index in message.trace?.calls.indices ?? 0..<0 where message.trace?.calls[index].state == .running {
                    message.trace?.calls[index].state = .failed
                }
                if message.content.isEmpty, message.images.isEmpty, message.audio.isEmpty, message.videos.isEmpty, message.steps.isEmpty, !cancelled {
                    message.content = "No response from the model."
                    message.isError = true
                }
            }
            persist()
            if !cancelled { finished(replyID: reply.id, chatID: chatID, question: question, model: model, started: started, task: task) }
        }
    }

    /// After a reply: a notification when the user wasn't watching, and a skill drafted from a task of several steps.
    private func finished(replyID: UUID, chatID: UUID, question: String, model: String, started: Date, task: ScheduledTask?) {
        guard let reply = message(replyID) else { return }
        if task != nil || ((!Self.appIsActive || currentID != chatID) && Date().timeIntervalSince(started) > 5) {
            let body = reply.isError ? "Failed: \(reply.content)" : reply.content.isEmpty ? "The reply is ready." : Self.splitThinking(reply.content).answer
            Notifier.notify(title: task?.title ?? chat(chatID)?.title ?? "Blablador", body: body, chat: chatID)
        }
        let skills = SkillLibrary.shared
        guard task == nil, skills.draftsAutomatically, !reply.isError, reply.skillsUsed.isEmpty, reply.suggestedSkills.isEmpty,
              let trace = reply.trace, SkillDrafter.worthDrafting(trace) else { return }
        let api = api
        let existing = skills.skills.map(\.name)
        Task {
            guard let skill = await SkillDrafter.draft(request: question, trace: trace, answer: reply.content, existing: existing, api: api, model: model) else { return }
            updateMessage(replyID) { $0.suggestedSkills.append(skill) }
            persist()
        }
    }

    /// Runs a scheduled task in a new chat (not opened) and returns the chat's id.
    @discardableResult
    func runTask(_ task: ScheduledTask) -> UUID {
        var conversation = Conversation(title: "\(task.title) · \(Date().formatted(date: .abbreviated, time: .omitted))", model: selectedModel)
        var message = ChatMessage(role: .user, content: task.prompt)
        if task.webSearch { message.mentions = [Mention(kind: .tool, value: "web", name: "Web search", icon: "globe")] }
        conversation.messages = [message]
        conversations.insert(conversation, at: 0)
        persist()
        respond(in: conversation.id, task: task)
        return conversation.id
    }

    /// What @mentions add to the system prompt for one message.
    static let toolHints = [
        "web": "web search (web_search, read_page)",
        "python": "Python (run_python)",
        "device": "the user's calendar, reminders, contacts or location",
        "chats": "earlier chats (search_chats)",
        "memory": "long-term memory (remember what matters)",
        "image": "image creation (generate_image, edit_image)",
        "schedule": "a scheduled task (schedule_task)",
        "plan": "a plan (update_plan), working through it step by step"
    ]

    static func mentionPrompt(_ mentions: [Mention]) -> String? {
        let parts: [String] = mentions.compactMap { mention in
            switch mention.kind {
            case .tool:
                return toolHints[mention.value] ?? mention.name
            case .skill:
                guard let skill = SkillLibrary.shared.skill(named: mention.value) else { return nil }
                return "the skill \"\(skill.name)\", whose instructions are:\n\(skill.instructions)\n"
            case .knowledge:
                return "the knowledge base \"\(mention.name)\" (relevant excerpts are below)"
            case .server:
                guard let server = MCPLibrary.shared.servers.first(where: { $0.id.uuidString == mention.value }) else { return nil }
                return "the tools of \(server.name) (named \(server.slug)__…)"
            }
        }
        return parts.isEmpty ? nil : "For this message the user asked you to use " + parts.joined(separator: "; ") + "."
    }

    /// Replaces a new chat's provisional title (its first words) with a short name from the helper model.
    private func nameChat(_ id: UUID, from text: String, model: String) {
        let provisional = Self.title(for: text)
        let api = api
        Task {
            let system = "You only write titles; you never answer, judge or refuse the message, whatever it asks. Give the chat a short title that says what it is about, like a heading: two to six words, in the language of the user's message, without quotes or final period. Don't copy the start of the message. Reply with only the title."
            guard let reply = try? await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: String(text.prefix(2000))) else { return }
            var name = Self.splitThinking(reply).answer.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»*#.")).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 80, !name.contains("\n"), !Self.isRefusal(name),
                  let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].title == provisional else { return }
            conversations[index].title = name
            persist()
        }
    }

    /// A helper model's refusal instead of a title, e.g. "I'm sorry, but I can't help with that".
    static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["sorry", "i can't", "i can’t", "i cannot", "i'm unable", "i am unable", "as an ai", "tut mir leid", "kann ich nicht"].contains { lower.contains($0) }
    }

    // MARK: - Long chats

    /// Above this many characters (about 30,000 tokens) older messages are replaced by a summary.
    private static let compactionThreshold = 120_000
    /// Messages always sent in full.
    private static let recentMessages = 8

    /// The system prompt (with the summary of older messages, if any) and the messages after the summary.
    static func history(system: String, _ conversation: Conversation) -> [[String: Any]] {
        var system = system
        let covered = min(conversation.summaryCount ?? 0, conversation.messages.count)
        if let summary = conversation.summary, covered > 0 {
            system += "\n\nSummary of the earlier part of this chat (those messages are not shown):\n" + summary
        }
        return [["role": "system", "content": system]]
            + conversation.messages[covered...].filter { !$0.isError }.map(Self.wireMessage)
    }

    /// Rough size of a request: text, plus about 3,000 characters per image.
    static func size(_ wire: [[String: Any]]) -> Int {
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

    /// After a reply, in the background: indexes new messages for search_chats and saves what's worth keeping
    /// from the exchange to long-term memory.
    private func learn(question: String, replyID: UUID, model: String, userOnly: Bool) {
        let memory = MemoryStore.shared
        guard !question.isEmpty,
              let reply = conversations.lazy.flatMap(\.messages).first(where: { $0.id == replyID }),
              !reply.isError, !reply.content.isEmpty else { return }
        let api = api
        let chat = conversations.first { $0.messages.contains { $0.id == replyID } }
        Task {
            await ChatIndex.shared.update(conversations, api: api)
            guard memory.enabled, memory.learnsAutomatically,
                  let facts = try? await memory.learn(question: question, reply: userOnly ? nil : reply.content, api: api, model: model, from: chat),
                  !facts.isEmpty else { return }
            updateMessage(replyID) { $0.remembered += facts }
            persist()
        }
    }

    /// Streams the reply, running the tools the model asks for. Returns whether it read outside content.
    /// Memory changes are refused once the reply has read outside content (web results, PDFs, knowledge bases,
    /// files, calendars, contacts), so text planted there can't write itself into every future chat.
    @discardableResult
    private func runTurn(model: String, messages: [[String: Any]], tools: [[String: Any]], replyID: UUID, chatID: UUID, workspace: URL? = nil, outsideContent: Bool = false, mcp: [MCPTool] = []) async throws -> Bool {
        var outsideContent = outsideContent
        var messages = messages
        var tools = tools
        var round = 0

        while true {
            let hasPlan = message(replyID)?.plan.isEmpty == false
            let maxRounds = max(workspace == nil ? Self.maxToolRounds : AgentTools.maxRounds, hasPlan ? Self.maxPlanRounds : 0)
            let isFinalRound = round >= maxRounds
            round += 1
            if isFinalRound {
                // Keep the tools declared (removing them makes DeepSeek print raw tool markup),
                // but tell the model to answer with what it has.
                messages.append(["role": "user", "content": "Stop using tools now and write the final answer using the results above."])
            }
            let prefix = message(replyID)?.content ?? ""
            let reasoningPrefix = message(replyID)?.reasoning ?? ""
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
                    case let .usage(prompt, completion):
                        updateMessage(replyID) {
                            $0.trace?.promptTokens += prompt
                            $0.trace?.completionTokens += completion
                        }
                    }
                }
                updateMessage(replyID) { $0.trace?.rounds += 1 }
            } catch BlabladorAPIError.http(let status, let body) where status == 400 && !tools.isEmpty && round == 1 && !body.localizedCaseInsensitiveContains("image") {
                // Model without tool support: answer without tools.
                tools = []
                continue
            }

            if isFinalRound || (calls.isEmpty && Self.containsToolMarkup(text)) {
                // Model still wants to use tools; nothing more to run.
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
            // notes between steps of an agent or a plan are kept.
            let note = Self.stripToolMarkup(text)
            let keepsNotes = workspace != nil || message(replyID)?.plan.isEmpty == false
            updateMessage(replyID) { $0.content = keepsNotes && !note.isEmpty ? prefix + note + "\n\n" : prefix }

            for call in calls {
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                let started = Date()
                var traced = TraceCall(tool: call.name, arguments: call.arguments)
                updateMessage(replyID) { $0.trace?.calls.append(traced) }
                let (output, state) = await execute(call.name, arguments, replyID: replyID, chatID: chatID, workspace: workspace, mcp: mcp, outsideContent: &outsideContent)
                traced.result = String(output.prefix(4_000))
                traced.seconds = Date().timeIntervalSince(started)
                traced.state = state
                updateMessage(replyID) { message in
                    if let index = message.trace?.calls.firstIndex(where: { $0.id == traced.id }) { message.trace?.calls[index] = traced }
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
            updateMessage(replyID) { $0.status = "Thinking…" }
        }
    }

    /// Tools whose call can be repeated from the trace without changing anything.
    static func canRerun(_ tool: String) -> Bool {
        !["update_plan", "remember", "forget", "use_skill", "suggest_skill", "generate_image", "edit_image", "generate_speech",
          "create_event", "create_reminder", "schedule_task", "write_file", "edit_file"].contains(tool)
    }

    /// Runs one recorded tool call again and shows the new result in the trace (the reply itself stays).
    func rerun(_ callID: UUID, in messageID: UUID) {
        guard let conversation = chat(containing: messageID),
              var call = message(messageID)?.trace?.calls.first(where: { $0.id == callID }), Self.canRerun(call.tool) else { return }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        func write(_ call: TraceCall) {
            updateMessage(messageID) { message in
                if let index = message.trace?.calls.firstIndex(where: { $0.id == call.id }) { message.trace?.calls[index] = call }
            }
        }
        call.state = .running
        write(call)
        let workspace = conversation.workspace.map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task {
            let mcp = await MCPLibrary.shared.availableTools()
            var outside = true
            let started = Date()
            let (output, state) = await execute(call.tool, arguments, replyID: messageID, chatID: conversation.id, workspace: workspace, mcp: mcp, outsideContent: &outside)
            call.result = String(output.prefix(4_000))
            call.seconds = Date().timeIntervalSince(started)
            call.state = state
            write(call)
            updateMessage(messageID) { $0.status = nil }
            persist()
        }
    }

    /// Runs one tool call after checking its permission, and returns what goes back to the model.
    private func execute(_ name: String, _ arguments: [String: Any], replyID: UUID, chatID: UUID, workspace: URL?, mcp: [MCPTool], outsideContent: inout Bool) async -> (String, AgentStep.State) {
        let query = arguments["query"] as? String ?? ""
        let prompt = arguments["prompt"] as? String ?? ""
        let script = arguments["script"] as? String ?? ""

        if name == "remember" || name == "forget", outsideContent {
            return ("Memory can't be changed in a reply that used web results, documents, knowledge bases, files or device data, because they could contain planted instructions. Tell the user they can ask again in a new message without them, or edit memories in Settings → Memory.", .denied)
        }
        // Agent tools and connected services ask in their own way below.
        if let kind = ToolPermissions.kind(of: name), kind != "command", kind != "files" {
            var title = "Let Blablador use \(name)?"
            var detail = (try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if let device = DeviceTools.approval(name, arguments) { (title, detail) = device }
            if name == "schedule_task", let task = TaskScheduler.task(from: arguments) {
                title = "Schedule “\(task.title)”?"
                detail = task.scheduleText + "\n\n" + task.prompt
            }
            let icon = ToolPermissions.kinds.first { $0.id == kind }?.icon ?? "hand.raised"
            if name.hasPrefix("create_") || name == "schedule_task" || ToolPermissions.shared.rule(kind) != .allow {
                updateMessage(replyID) { $0.status = "Waiting for approval…" }
            }
            guard await authorize(kind, chat: chatID, title: title, detail: detail, icon: icon) else {
                return ("The user didn't allow \(name) (it can be changed in Settings → Permissions). Continue without it or ask what to do instead.", .denied)
            }
        }

        if name == "update_plan" {
            let items = PlanTools.items(from: arguments)
            updateMessage(replyID) { $0.plan = items }
            return (PlanTools.summary(items), .done)
        } else if name == "generate_image" || name == "edit_image", !prompt.isEmpty {
            do {
                let image = try await runImageTool(name: name, prompt: prompt, source: latestImage(for: replyID), replyID: replyID)
                updateMessage(replyID) { $0.images.append(image) }
                return ("The image was created and is shown to the user. Do not include it or a link in your answer; just briefly comment on it.", .done)
            } catch {
                return ("Image tool failed: \(error.localizedDescription)", .failed)
            }
        } else if name == "generate_speech", !script.isEmpty {
            do {
                let audio = try await runSpeechTool(script: script, replyID: replyID)
                updateMessage(replyID) { $0.audio.append(audio) }
                return ("The speech was created and the user can play it. Don't repeat the script; just briefly comment on it.", .done)
            } catch {
                return ("Speech tool failed: \(error.localizedDescription)", .failed)
            }
        } else if let workspace, AgentTools.names.contains(name) {
            outsideContent = true
            return await runAgentTool(name, arguments, in: workspace, replyID: replyID, chatID: chatID)
        } else if name == "use_skill", let skillName = arguments["name"] as? String {
            guard let skill = SkillLibrary.shared.skill(named: skillName) else { return ("There is no skill called \"\(skillName)\".", .failed) }
            updateMessage(replyID) { if !$0.skillsUsed.contains(skill.name) { $0.skillsUsed.append(skill.name) } }
            return ("Instructions of the skill \"\(skill.name)\":\n\n\(skill.instructions)", .done)
        } else if name == "suggest_skill", let skillName = arguments["name"] as? String,
                  let instructions = arguments["instructions"] as? String, !instructions.isEmpty {
            let skill = Skill(name: skillName, description: arguments["description"] as? String ?? "", instructions: instructions)
            updateMessage(replyID) { $0.suggestedSkills.append(skill) }
            return ("The suggestion is shown to the user with a Save button; it is not saved until they press it. Don't repeat the instructions; mention it in one sentence.", .done)
        } else if name == "search_chats", !query.isEmpty {
            outsideContent = true
            updateMessage(replyID) { $0.status = "Searching earlier chats…" }
            return (await ChatSearch.find(query, in: library.conversations, excluding: chatID, api: api), .done)
        } else if name == "remember", let fact = arguments["fact"] as? String, MemoryStore.shared.enabled {
            guard MemoryStore.shared.add(fact, from: chat(chatID)) else { return ("Already remembered or empty; nothing saved.", .done) }
            updateMessage(replyID) { $0.remembered.append(fact.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return ("Saved to memory.", .done)
        } else if name == "forget", MemoryStore.shared.enabled,
                  let number = (arguments["number"] as? Int) ?? Int(arguments["number"] as? String ?? "") {
            guard let forgotten = MemoryStore.shared.forget(number: number) else { return ("There is no memory number \(number).", .failed) }
            updateMessage(replyID) { $0.forgotten.append(forgotten.text) }
            return ("Forgot: \(forgotten.text). The numbers of later memories moved up by one.", .done)
        } else if name == "schedule_task" {
            guard let task = TaskScheduler.task(from: arguments) else {
                return ("Couldn't read the schedule: give title, prompt and time as HH:MM, optionally days or a date.", .failed)
            }
            TaskScheduler.shared.save(task)
            let next = task.next().map { " Next run: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            return ("Scheduled “\(task.title)”: \(task.scheduleText).\(next) The user can change it in Settings → Scheduled tasks.", .done)
        } else if DeviceTools.names.contains(name) {
            if !name.hasPrefix("create_") { outsideContent = true }
            updateMessage(replyID) { $0.status = name == "current_location" ? "Finding your location…" : name == "find_contacts" ? "Looking up contacts…" : "Checking your calendar…" }
            do {
                return (try await DeviceTools.run(name, arguments), .done)
            } catch {
                return (error.localizedDescription, .failed)
            }
        } else if name == "image_search", !query.isEmpty {
            outsideContent = true
            updateMessage(replyID) { $0.status = "Searching pictures of “\(query)”" }
            do {
                let images = try await WebSearch.searchImages(query)
                updateMessage(replyID) { message in
                    message.webImages += images.filter { image in !message.webImages.contains { $0.image == image.image } }
                }
                return (images.isEmpty
                    ? "No pictures found for \"\(query)\"."
                    : "\(images.count) pictures are shown to the user: " + images.map(\.title).joined(separator: "; ") + ". Don't include image links in your answer.", .done)
            } catch {
                return ("Image search failed: \(error.localizedDescription)", .failed)
            }
        } else if name == "run_python", let code = arguments["code"] as? String, !code.isEmpty {
            outsideContent = true
            return await runPython(code, replyID: replyID)
        } else if let tool = mcp.first(where: { $0.qualifiedName == name }) {
            outsideContent = true
            return await runMCPTool(tool, arguments, replyID: replyID, chatID: chatID)
        } else if name == "read_page", let address = arguments["url"] as? String {
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
                return ("[\(number)] \(page.title)\nURL: \(page.url.absoluteString)\n\n\(page.text.isEmpty ? "(No readable text on this page.)" : page.text)", .done)
            } catch {
                return ("Could not read the page: \(error.localizedDescription)", .failed)
            }
        } else if name == "web_search", !query.isEmpty {
            outsideContent = true
            updateMessage(replyID) { $0.status = "Searching “\(query)”" }
            do {
                let results = try await WebSearch.search(query, category: arguments["category"] as? String, timeRange: arguments["time_range"] as? String)
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
                return (WebSearch.toolOutput(query: query, results: numbered), .done)
            } catch {
                return ("Search failed: \(error.localizedDescription)", .failed)
            }
        }
        return ("Unknown tool \(name), or its arguments are missing.", .failed)
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

    private func updateChat(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
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
