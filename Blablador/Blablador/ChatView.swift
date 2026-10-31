import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var synthesizer = SpeechSynthesizer()
    @ObservedObject private var siri = SiriCommandCenter.shared
#if os(macOS)
    /// Only the front window takes shared items and Siri commands.
    @Environment(\.controlActiveState) private var windowState
#endif

    @State private var draft = ""
    @State private var attachments: [Data] = []
    @State private var documents: [DocumentAttachment] = []
    @State private var mentions: [Mention] = []
    @State private var imageMode = false
    @State private var videoMode = false
    @State private var speechMode = false
    @State private var showHistory = false
    @State private var drawerDrag: CGFloat = 0
    @State private var droppedFiles: [URL] = []
    /// When a share last filled the composer: macOS submits a text field when its text is replaced while it is
    /// being edited, which must not send the previous draft.
    @State private var shareArrived = Date.distantPast
    @State private var dropTargeted = false
    @State private var showSettings = false
    @ObservedObject private var knowledge = KnowledgeLibrary.shared
    @State private var showKnowledge = false
    @State private var openedKnowledge: UUID?
    @State private var namingKnowledge = false
    @State private var newKnowledgeName = ""
    @FocusState private var inputFocused: Bool
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var usesSidebar: Bool { sizeClass == .regular }
#else
    private let usesSidebar = true
#endif

    var body: some View {
        Group {
            if usesSidebar {
                // iPad and Mac: permanent, collapsible chat list.
                NavigationSplitView {
                    HistoryView {}
                        .navigationTitle("Chats")
#if os(macOS)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
#endif
                } detail: {
                    NavigationStack {
                        chat
#if os(macOS)
                            // Names the window and its tab.
                            .navigationTitle(store.current?.title ?? "New chat")
#endif
                    }
                }
            } else {
                NavigationStack { chat }
                    .overlay { historyDrawer }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showKnowledge) {
            NavigationStack {
                Group {
                    if let openedKnowledge {
                        KnowledgeBaseView(baseID: openedKnowledge)
                    } else {
                        KnowledgeListView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showKnowledge = false }
                    }
                }
            }
            .environmentObject(store)
#if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
#endif
        }
        .alert("New knowledge base", isPresented: $namingKnowledge) {
            TextField("Name", text: $newKnowledgeName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newKnowledgeName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                // Use it right away and open it to add documents.
                let base = knowledge.create(name: name)
                store.toggleKnowledge(base.id)
                openedKnowledge = base.id
                showKnowledge = true
            }
        } message: {
            Text("Add PDFs and text files next. It is switched on for this chat.")
        }
        .task {
            await store.loadModels()
            await store.loadUserName()
            if store.apiKey.isEmpty { showSettings = true }
        }
        .onChange(of: store.settingsRequested) { _, requested in
            if requested {
                showSettings = true
                store.settingsRequested = false
            }
            handleSiri(siri.pendingCommand)
        }
        .onChange(of: siri.pendingCommand) { _, command in handleSiri(command) }
        .onChange(of: siri.pendingShare) { _, _ in handleShare() }
        .onChange(of: siri.pendingChat) { _, id in
            guard let id, isFrontWindow, let chat = store.conversations.first(where: { $0.id == id }) else { return }
            siri.pendingChat = nil
            store.select(chat)
        }
        .onAppear { handleShare() }
#if os(macOS)
        .onChange(of: windowState) { _, _ in
            handleShare()
            handleSiri(siri.pendingCommand)
        }
#endif
        .onChange(of: speech.transcript) { _, text in
            if speech.isRecording { draft = text }
        }
        .alert("Voice input", isPresented: Binding(
            get: { speech.errorMessage != nil },
            set: { if !$0 { speech.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(speech.errorMessage ?? "")
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            if let conversation = store.current, !conversation.messages.isEmpty {
                messageList(conversation)
            } else {
                WelcomeView { prompt in
                    inputFocused = false
                    store.send(prompt)
                }
            }
            if let approval = store.commandApproval {
                CommandApprovalCard(approval: approval) { store.answerApproval($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerView(draft: $draft, attachments: $attachments, documents: $documents, mentions: $mentions, imageMode: $imageMode, videoMode: $videoMode, speechMode: $speechMode, droppedFiles: $droppedFiles, speech: speech, focused: $inputFocused, onSend: send)
        }
        // Drop images and PDFs from Finder or Files onto the chat to attach them.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            droppedFiles += files
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.gradient, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
                    .overlay { Label("Drop images or PDFs to attach", systemImage: "paperclip").scaledFont(.title3, weight: .semibold) }
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.25), value: store.commandApproval?.id)
        .background(Theme.background)
        .toolbar { toolbar }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !usesSidebar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.spring(duration: 0.3)) { showHistory = true }
                } label: {
                    Label("Chats", systemImage: "line.3.horizontal")
                }
            }
        }
#if os(macOS)
        ToolbarItem(placement: .navigation) {
            ModelMenu()
        }
        ToolbarItem(placement: .navigation) {
            knowledgeMenu
        }
#else
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                ModelMenu()
                knowledgeMenu
            }
        }
#endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.newChat()
                draft = ""
                attachments = []
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(store.currentID == nil)
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
#if os(iOS)
            .keyboardShortcut(",", modifiers: .command)
#endif
        }
    }

    /// Knowledge bases for this chat, plus creating a new one.
    private var knowledgeMenu: some View {
        Menu {
            Section("Use in this chat") {
                if knowledge.bases.isEmpty {
                    Text("No knowledge bases yet")
                }
                ForEach(knowledge.bases) { base in
                    Toggle(isOn: Binding(
                        get: { store.activeKnowledge.contains(base.id) },
                        set: { _ in store.toggleKnowledge(base.id) }
                    )) {
                        Text(base.name)
                    }
                }
            }
            Divider()
            Button {
                newKnowledgeName = ""
                namingKnowledge = true
            } label: {
                Label("New knowledge base…", systemImage: "plus")
            }
            Button {
                openedKnowledge = nil
                showKnowledge = true
            } label: {
                Label("Manage knowledge…", systemImage: "gearshape")
            }
        } label: {
            Label("Knowledge", systemImage: store.activeKnowledge.isEmpty ? "books.vertical" : "books.vertical.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(store.activeKnowledge.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.gradient))
        }
        .accessibilityLabel("Knowledge bases")
    }

    private func messageList(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(conversation.messages) { message in
                        MessageView(
                            message: message,
                            isLast: message.id == conversation.messages.last?.id,
                            isStreaming: store.isStreaming,
                            synthesizer: synthesizer,
                            models: store.chatModels,
                            onRegenerate: { store.regenerate(with: $0) },
                            onEdit: { store.edit(message.id, to: $0) },
                            onShowVersion: { store.showVersion(of: message.id, offset: $0) }
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .environment(\.editImage, ImageEditAction(edit: editImage, continueVideo: continueVideo))
            .environment(\.openURL, SafeLinks.action)
        }
    }

    /// Puts an image from the chat into the composer in edit mode.
    private func editImage(_ name: String) {
        guard let data = ImageStore.data(for: name) else { return }
        attachments = [data]
        speechMode = false
        imageMode = true
        inputFocused = true
    }

    /// Puts a video's last frame into the composer in video mode, to make the next clip.
    private func continueVideo(_ name: String) {
        Task {
            guard let frame = await VideoStore.lastFrame(of: name) else { return }
            attachments = [frame]
            if draft.isEmpty { draft = store.prompt(forVideo: name) ?? "" }
            videoMode = true
            inputFocused = true
        }
    }

    @ViewBuilder
    private var historyDrawer: some View {
        if showHistory {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { showHistory = false } }
                HistoryView(closable: true) { closeHistory() }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(Theme.background)
                .offset(x: min(0, drawerDrag))
                .transition(.move(edge: .leading))
            }
            .transition(.opacity)
            // Swipe left anywhere to go back to the chat, also while searching.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { drawerDrag = value.translation.width }
                    }
                    .onEnded { value in
                        if value.translation.width < -80 || value.predictedEndTranslation.width < -160 { closeHistory() }
                        withAnimation(.spring(duration: 0.25)) { drawerDrag = 0 }
                    }
            )
        }
    }

    private func closeHistory() {
#if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
        withAnimation(.spring(duration: 0.3)) { showHistory = false }
    }

    private func send() {
        guard Date().timeIntervalSince(shareArrived) > 1 else { return }
        if speech.isRecording { speech.stop() }
        inputFocused = false
        let text = draft
        let images = attachments
        let pdfs = documents
        let mentioned = mentions
        draft = ""
        attachments = []
        documents = []
        mentions = []
        store.send(text, attachments: images, documents: pdfs, mentions: mentioned, createImage: imageMode, createVideo: videoMode, speak: speechMode)
    }

    /// Something shared with or opened in Blablador: a new chat with it in the composer, ready to ask about.
    private func handleShare() {
        guard isFrontWindow, siri.pendingShare != nil, let share = SiriCommandCenter.shared.claimShare() else { return }
        shareArrived = Date()
        store.newChat()
        draft = share.text
        droppedFiles += share.files
        inputFocused = true
    }

    private var isFrontWindow: Bool {
#if os(macOS)
        windowState == .key
#else
        true
#endif
    }

    private func handleSiri(_ command: String?) {
        guard let command, !command.isEmpty, isFrontWindow else { return }
        SiriCommandCenter.shared.consumePendingCommand()
        store.newChat()
        store.send(command)
    }
}

private struct ModelMenu: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        Menu {
            if store.chatModels.isEmpty {
                Text(store.modelsError ?? "Loading models…")
            }
            ForEach(store.chatModels) { model in
                Button {
                    store.selectedModel = model.id
                } label: {
                    if model.id == store.selectedModel {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
#if os(macOS)
            // The window title already shows "Blablador"; use a native pop-up for the model.
            // No avatar: macOS 26 toolbars ignore the image frame and draw it full size.
            Text(store.selectedModelName)
#else
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image("Avatar")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                    Text("Blablador")
                        .scaledFont(.headline)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 2) {
                    Text(store.selectedModelName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220)
#endif
        }
#if os(macOS)
        .menuStyle(.button)
        .fixedSize()
        .help("Model")
#else
        .menuStyle(.button)
        .buttonStyle(.plain)
#endif
    }
}

private struct WelcomeView: View {
    let onPick: (String) -> Void

    private let suggestions: [(icon: String, text: String)] = [
        ("lightbulb", "Explain quantum computing in simple terms"),
        ("pencil.and.outline", "Help me write an email to my team"),
        ("chevron.left.forwardslash.chevron.right", "Write a Python script to rename files"),
        ("globe.europe.africa", "Plan a weekend trip to Jülich")
    ]

    @EnvironmentObject private var store: ChatStore

    /// "Good morning, Name" based on the device's local time.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<22: "Good evening"
        default: "Hello"
        }
        return store.userName.isEmpty ? salutation : "\(salutation), \(store.userName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .foregroundStyle(Theme.gradient)
                    Text("How can I help you today?")
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .font(.system(size: 36, weight: .semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(suggestions, id: \.text) { suggestion in
                            Button { onPick(suggestion.text) } label: {
                                VStack(alignment: .leading) {
                                    Text(suggestion.text)
                                        .scaledFont(.subheadline)
                                        .multilineTextAlignment(.leading)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: suggestion.icon)
                                        .padding(8)
                                        .background(Theme.background, in: Circle())
                                }
                                .padding(14)
                                .frame(width: 160, height: 160, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ComposerView: View {
    @Binding var draft: String
    @Binding var attachments: [Data]
    @Binding var documents: [DocumentAttachment]
    @Binding var mentions: [Mention]
    @Binding var imageMode: Bool
    @Binding var videoMode: Bool
    @Binding var speechMode: Bool
    @Binding var droppedFiles: [URL]
    @ObservedObject var speech: SpeechRecognizer
#if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
#else
    @State private var clipboardHasImage = false
    @State private var dismissedClipboard = -1
#endif
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @EnvironmentObject private var store: ChatStore
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showKnowledge = false
    @State private var showOCRPicker = false
    /// Scan text: asks where the pictures come from; the file importer and camera then read text instead of attaching.
    @State private var showScanChoice = false
    @State private var scanning = false
    @State private var showDecision = false
    @State private var ocrItems: [PhotosPickerItem] = []
    @State private var readingPDFs = 0
    @State private var pdfError: String?
    @State private var showPanel = false
    /// Something picked in the panel that opens another sheet once the panel has closed.
    @State private var pendingAction: ToolsPanel.Action?

    /// An "@name" being typed at the end of the draft.
    private static let mentionReference = #"(^|\s)@[^\s@]*$"#

    private var mentionQuery: String? {
        guard let range = draft.range(of: Self.mentionReference, options: .regularExpression) else { return nil }
        return String(draft[range].drop { $0 != "@" }.dropFirst())
    }

    /// A "#name" being typed at the end of the draft.
    private static let knowledgeReference = #"(^|\s)#[^\s#]*$"#

    private var knowledgeQuery: String? {
        guard let range = draft.range(of: Self.knowledgeReference, options: .regularExpression) else { return nil }
        return String(draft[range].drop { $0 != "#" }.dropFirst())
    }

    private var canSend: Bool {
        readingPDFs == 0 && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !documents.isEmpty)
    }

    private var placeholder: String {
        if speech.isRecording { return "Listening…" }
        if speechMode { return "What should be said?" }
        if videoMode { return attachments.isEmpty ? "Describe a video, with its sounds" : "Describe what happens next" }
        if imageMode { return attachments.isEmpty ? "Describe an image" : "Describe the change" }
        return "Ask Blablador"
    }

    /// The text field and its buttons; `body` adds pickers and sheets (split so the compiler can type-check it).
    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
#if os(iOS)
            if clipboardHasImage {
                pasteBar
            }
#endif
            if !attachments.isEmpty {
                attachmentStrip
            }
            if !documents.isEmpty || readingPDFs > 0 {
                documentStrip
            }
            WorkspaceChip()
            if !store.activeKnowledge.isEmpty {
                ActiveKnowledgeStrip()
            }
            if !mentions.isEmpty {
                MentionChips(mentions: mentions) { mention in mentions.removeAll { $0.id == mention.id } }
            }
            if let query = mentionQuery {
                MentionSuggestions(query: query) { mention in
                    if let range = draft.range(of: Self.mentionReference, options: .regularExpression) {
                        draft.replaceSubrange(range, with: draft[range].first == "@" ? "" : " ")
                    }
                    if !mentions.contains(mention) { mentions.append(mention) }
                }
            }
            if let query = knowledgeQuery {
                KnowledgeSuggestions(query: query) { base in
                    // Replace the typed #reference with the chip.
                    if let range = draft.range(of: Self.knowledgeReference, options: .regularExpression) {
                        draft.replaceSubrange(range, with: draft[range].first == "#" ? "" : " ")
                    }
                    if !store.activeKnowledge.contains(base.id) { store.toggleKnowledge(base.id) }
                }
            }
            if imageMode {
                imageModeChip
            }
            if videoMode {
                videoModeChip
            }
            if speechMode {
                HStack(spacing: 8) {
                    SpeechModeChip { speechMode = false }
                    SpeechMarkupMenu(draft: $draft)
                }
                .padding(.leading, 8)
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 4) {
                Button { showPanel = true } label: {
                    Image(systemName: "plus")
                        .scaledFont(.title3)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add and tools")
                .help("Attach files, choose tools and more")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .scaledFont(.body)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.vertical, 10)
                    .padding(.leading, 4)
                    .onSubmit { if canSend { onSend() } }

                Button {
                    speech.toggle()
                } label: {
                    Image(systemName: speech.isRecording ? "waveform" : "mic")
                        .symbolEffect(.variableColor.iterative, isActive: speech.isRecording)
                        .scaledFont(.title3)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(speech.isRecording ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate")

                if store.isStreaming {
                    Button(action: store.stop) {
                        Image(systemName: "stop.fill")
                            .scaledFont(.body)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Theme.background)
                            .background(.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop generating")
                } else if canSend {
                    Button(action: onSend) {
                        Image(systemName: speechMode ? "waveform" : imageMode ? "paintbrush.pointed.fill" : videoMode ? "film.fill" : "arrow.up")
                            .scaledFont(.body, weight: .semibold)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speechMode ? "Speak" : imageMode ? "Create image" : videoMode ? "Create video" : "Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Theme.gradient, lineWidth: speech.isRecording ? 2 + CGFloat(speech.audioLevel) * 3 : 0)
                .animation(.easeOut(duration: 0.1), value: speech.audioLevel)
        }
        .animation(.spring(duration: 0.25), value: canSend)
        .animation(.spring(duration: 0.25), value: attachments.count)
        .animation(.spring(duration: 0.25), value: documents.count)
        .onChange(of: imageMode) { _, on in if on { speechMode = false; videoMode = false } }
        .onChange(of: speechMode) { _, on in if on { imageMode = false; videoMode = false } }
        .onChange(of: videoMode) { _, on in if on { imageMode = false; speechMode = false } }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        field
        .sheet(isPresented: $showPanel, onDismiss: runPendingAction) {
            ToolsPanel(imageMode: $imageMode, videoMode: $videoMode, speechMode: $speechMode) { action in
                pendingAction = action
                showPanel = false
            }
            .environmentObject(store)
#if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#else
            .frame(minWidth: 440, minHeight: 620)
#endif
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        attachments.append(ImageStore.jpeg(from: data, maxPixelSize: 2048, quality: 0.9) ?? data)
                    }
                }
                photoItems = []
            }
        }
        .sheet(isPresented: $showDecision) {
            DecisionView().environmentObject(store)
        }
        .photosPicker(isPresented: $showOCRPicker, selection: $ocrItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: ocrItems) { _, items in
            guard !items.isEmpty else { return }
            ocrItems = []
            readingPDFs += 1
            Task {
                defer { readingPDFs -= 1 }
                for (number, item) in items.enumerated() {
                    let name = items.count > 1 ? "Photo text \(number + 1)" : "Photo text"
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                        documents.append(try await PDFExtractor.extract(photo: data, name: name, api: store.api))
                    } catch {
                        pdfError = "\(name): \(error.localizedDescription)"
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: scanning ? [.image, .pdf] : [.image, .pdf] + DataFiles.contentTypes, allowsMultipleSelection: true) { result in
            let scan = scanning
            scanning = false
            guard case .success(let urls) = result else { return }
            if scan { scanFiles(urls) } else { addFiles(urls) }
        }
        .confirmationDialog("Read text from", isPresented: $showScanChoice) {
            if CameraPicker.isAvailable {
                Button("Camera") { scanning = true; showCamera = true }
            }
            Button("Photos") { showOCRPicker = true }
            Button("Files") { scanning = true; showFileImporter = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blablador reads the text in pictures and attaches it to your message.")
        }
#if os(iOS)
        .onAppear { refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
        .animation(.spring(duration: 0.25), value: clipboardHasImage)
#endif
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .pasteAttachment)) { note in
            guard controlActiveState == .key else { return }
            if pasteImage() { (note.object as? PasteRequest)?.handled = true }
        }
#endif
        .onChange(of: droppedFiles) { _, urls in
            guard !urls.isEmpty else { return }
            droppedFiles = []
            addFiles(urls)
        }
        .sheet(isPresented: $showKnowledge) {
            NavigationStack {
                KnowledgeListView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showKnowledge = false }
                        }
                    }
            }
            .environmentObject(store)
#if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
#endif
        }
        .alert("Couldn't read text", isPresented: Binding(get: { pdfError != nil }, set: { if !$0 { pdfError = nil } })) {
            Button("OK") {}
        } message: {
            Text(pdfError ?? "")
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in cameraPicture(data) }
                .ignoresSafeArea()
        }
#else
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in cameraPicture(ImageStore.jpeg(from: data, maxPixelSize: 2048, quality: 0.9) ?? data) }
        }
#endif
    }

#if os(iOS)
    /// Offers a copied image with the system Paste button, which needs no permission prompt.
    private var pasteBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
            Text("Image on the clipboard").scaledFont(.subheadline).foregroundStyle(.secondary)
            Spacer()
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task { await attach(providers) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            Button { dismissedClipboard = UIPasteboard.general.changeCount; clipboardHasImage = false } label: {
                Image(systemName: "xmark").scaledFont(.caption, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
    }

    /// Checks the clipboard without reading it, so iOS doesn't ask for permission.
    private func refreshClipboard() {
        let board = UIPasteboard.general
        clipboardHasImage = board.hasImages && board.changeCount != dismissedClipboard
    }

    private func attach(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { continue }
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
            }
            if let data {
                attachments.append(ImageStore.jpeg(from: data, maxPixelSize: 2048, quality: 0.9) ?? data)
            }
        }
        dismissedClipboard = UIPasteboard.general.changeCount
        clipboardHasImage = false
    }
#endif

    /// Attaches an image, or image and PDF files, from the clipboard. Returns whether there was one.
    @discardableResult
    private func pasteImage() -> Bool {
#if os(iOS)
        guard UIPasteboard.general.hasImages else {
            pdfError = "The clipboard has no image. Copy an image first, then choose Paste image."
            return false
        }
        // Wait for the menu to close, or iOS can't show its "Allow Paste" question.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await attach(UIPasteboard.general.itemProviders)
        }
        return true
#else
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .pdf)
            }
        if !files.isEmpty {
            addFiles(files)
            return true
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation else { return false }
        attachments.append(ImageStore.jpeg(from: tiff, maxPixelSize: 2048, quality: 0.9) ?? tiff)
        return true
#endif
    }

    /// Images become photo attachments; PDFs are read into text.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    attachments.append(ImageStore.jpeg(from: data, maxPixelSize: 2048, quality: 0.9) ?? data)
                } else {
                    pdfError = "\(url.lastPathComponent): couldn't open the image."
                }
            } else if type?.conforms(to: .pdf) == true {
                readingPDFs += 1
                Task {
                    defer { readingPDFs -= 1 }
                    do {
                        documents.append(try await PDFExtractor.extract(from: url, api: store.api))
                    } catch {
                        pdfError = "\(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            } else if DataFiles.supports(url) {
                do {
                    documents.append(try DataFiles.attach(url))
                } catch {
                    pdfError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            } else {
                pdfError = "\(url.lastPathComponent): only images, PDFs and data files (CSV, Excel, JSON…) can be attached."
            }
        }
    }

    /// A camera picture: attached, or read as text when scanning.
    private func cameraPicture(_ data: Data) {
        guard scanning else { return attachments.append(data) }
        scanning = false
        readingPDFs += 1
        Task {
            defer { readingPDFs -= 1 }
            do {
                documents.append(try await PDFExtractor.extract(photo: data, name: "Scanned text", api: store.api))
            } catch {
                pdfError = "Scanned text: \(error.localizedDescription)"
            }
        }
    }

    /// Reads the text of picture files; PDFs are read as usual (scanned pages included).
    private func scanFiles(_ urls: [URL]) {
        let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
        addFiles(pdfs)
        let pictures = urls.filter { !pdfs.contains($0) }
        guard !pictures.isEmpty else { return }
        readingPDFs += 1
        Task {
            defer { readingPDFs -= 1 }
            for url in pictures {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    documents.append(try await PDFExtractor.extract(photo: data, name: url.deletingPathExtension().lastPathComponent, api: store.api))
                } catch {
                    pdfError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .camera: showCamera = true
        case .photos: showPhotoPicker = true
        case .files: showFileImporter = true
        case .paste: pasteImage()
        case .scanText: showScanChoice = true
        case .decide: showDecision = true
        case .newKnowledge: showKnowledge = true
        case .workspace:
#if os(macOS)
            if let url = chooseWorkspace() { store.workspace = url }
#endif
        }
    }

    private var videoModeChip: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Length", selection: Binding(get: { store.videoSeconds }, set: { store.videoSeconds = $0 })) {
                    ForEach(BlabladorAPI.videoDurations, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                if attachments.isEmpty {
                    Picker("Shape", selection: Binding(get: { store.videoAspect }, set: { store.videoAspect = $0 })) {
                        ForEach(BlabladorAPI.videoAspects, id: \.id) { Text("\($0.name) \($0.id)").tag($0.id) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "film.fill")
                    Text(attachments.isEmpty ? "Video · \(store.videoSeconds) s · \(store.videoAspectName)" : "Video from image · \(store.videoSeconds) s")
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Video length and shape")
            Button {
                videoMode = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave video mode")
        }
        .scaledFont(.caption, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.gradient, in: Capsule())
        .padding(.leading, 8)
        .padding(.top, 4)
    }

    private var imageModeChip: some View {
        HStack(spacing: 6) {
            if attachments.isEmpty {
                // Model for new images can be switched right here.
                Menu {
                    ForEach(BlabladorAPI.imageModels, id: \.id) { model in
                        Button {
                            store.imageModel = model.id
                        } label: {
                            if model.id == store.imageModel {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paintbrush.pointed.fill")
                        Text(store.imageModelName)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Image model, \(store.imageModelName)")
            } else {
                Image(systemName: "paintbrush.pointed.fill")
                Text("Edit image · Qwen-Image")
            }
            Button {
                imageMode = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave image mode")
        }
        .scaledFont(.caption, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.gradient, in: Capsule())
        .padding(.leading, 8)
        .padding(.top, 4)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumbnail(data: data)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button {
                            attachments.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .accessibilityLabel("Remove image")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }
}

extension ComposerView {
    private var documentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(documents) { document in
                    DocumentChip(document: document) {
                        documents.removeAll { $0.id == document.id }
                    }
                }
                if readingPDFs > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading text…")
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }
}

/// A PDF attachment: file name, page count and whether OCR was used.
struct DocumentChip: View {
    let document: DocumentAttachment
    var onRemove: (() -> Void)?

    private var detail: String {
        if document.dataFile != nil { return "Data file" }
        let pages = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
        return document.ocrPageCount > 0 ? "\(pages) · OCR" : pages
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: document.dataFile != nil ? "tablecells" : "doc.richtext")
                .scaledFont(.title3)
                .foregroundStyle(Theme.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.name)
                    .scaledFont(.caption, weight: .medium)
                    .lineLimit(1)
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(document.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3)))
    }
}

private struct AttachmentThumbnail: View {
    let data: Data

    var body: some View {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 200
           ] as CFDictionary) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Color.gray
        }
    }
}

#if os(macOS)
extension Notification.Name {
    /// Asks the key window's composer to attach what's on the clipboard.
    static let pasteAttachment = Notification.Name("pasteAttachment")
}

/// Lets the composer report that it took the paste, so the text field doesn't paste too.
final class PasteRequest {
    var handled = false

    /// An image without text (a screenshot, a copied picture), or copied image/PDF files from Finder.
    static var clipboardHasAttachment: Bool {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.contains(where: { ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp", "bmp", "pdf"].contains($0.pathExtension.lowercased()) }) {
            return true
        }
        let types = board.types ?? []
        return !types.contains(.string) && NSImage.canInit(with: board)
    }
}
#endif
