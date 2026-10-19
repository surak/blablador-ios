import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var synthesizer = SpeechSynthesizer()
    @ObservedObject private var siri = SiriCommandCenter.shared

    @State private var draft = ""
    @State private var attachments: [Data] = []
    @State private var documents: [DocumentAttachment] = []
    @State private var imageMode = false
    @State private var speechMode = false
    @State private var showHistory = false
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
                    NavigationStack { chat }
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
            if let conversation = store.current, !conversation.messages.isEmpty {
                messageList(conversation)
            } else {
                WelcomeView { prompt in
                    inputFocused = false
                    store.send(prompt)
                }
            }
            ComposerView(draft: $draft, attachments: $attachments, documents: $documents, imageMode: $imageMode, speechMode: $speechMode, speech: speech, focused: $inputFocused, onSend: send)
        }
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
                            onRegenerate: store.regenerate
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
        }
    }

    @ViewBuilder
    private var historyDrawer: some View {
        if showHistory {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { showHistory = false } }
                HistoryView {
                    withAnimation(.spring(duration: 0.3)) { showHistory = false }
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(Theme.background)
                .transition(.move(edge: .leading))
            }
            .transition(.opacity)
        }
    }

    private func send() {
        if speech.isRecording { speech.stop() }
        inputFocused = false
        let text = draft
        let images = attachments
        let pdfs = documents
        draft = ""
        attachments = []
        documents = []
        store.send(text, attachments: images, documents: pdfs, createImage: imageMode, speak: speechMode)
    }

    private func handleSiri(_ command: String?) {
        guard let command, !command.isEmpty else { return }
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
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 2) {
                    Text(store.selectedModelName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .font(.caption)
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
                                        .font(.subheadline)
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
    @Binding var imageMode: Bool
    @Binding var speechMode: Bool
    @ObservedObject var speech: SpeechRecognizer
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @EnvironmentObject private var store: ChatStore
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showKnowledge = false
    @State private var showOCRPicker = false
    @State private var ocrItems: [PhotosPickerItem] = []
    @State private var readingPDFs = 0
    @State private var pdfError: String?

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
        if imageMode { return attachments.isEmpty ? "Describe an image" : "Describe the change" }
        return "Ask Blablador"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                attachmentStrip
            }
            if !documents.isEmpty || readingPDFs > 0 {
                documentStrip
            }
            if !store.activeKnowledge.isEmpty {
                ActiveKnowledgeStrip()
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
            if speechMode {
                HStack(spacing: 8) {
                    SpeechModeChip { speechMode = false }
                    SpeechMarkupMenu(draft: $draft)
                }
                .padding(.leading, 8)
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 4) {
                addMenu

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
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
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(speech.isRecording ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate")

                if store.isStreaming {
                    Button(action: store.stop) {
                        Image(systemName: "stop.fill")
                            .font(.body)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Theme.background)
                            .background(.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop generating")
                } else if canSend {
                    Button(action: onSend) {
                        Image(systemName: speechMode ? "waveform" : imageMode ? "paintbrush.pointed.fill" : "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speechMode ? "Speak" : imageMode ? "Create image" : "Send")
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
        .onChange(of: imageMode) { _, on in if on { speechMode = false } }
        .onChange(of: speechMode) { _, on in if on { imageMode = false } }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
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
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                readingPDFs += 1
                Task {
                    defer { readingPDFs -= 1 }
                    do {
                        documents.append(try await PDFExtractor.extract(from: url, api: store.api))
                    } catch {
                        pdfError = "\(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
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
            CameraPicker { data in attachments.append(data) }
                .ignoresSafeArea()
        }
#endif
    }

    private var addMenu: some View {
        Menu {
#if os(iOS)
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
#endif
            Button { showPhotoPicker = true } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button { showFileImporter = true } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            Button { showOCRPicker = true } label: {
                Label("Text from photo", systemImage: "text.viewfinder")
            }
            KnowledgeMenu { showKnowledge = true }
            Divider()
            Toggle(isOn: $imageMode) {
                Label("Create image", systemImage: "paintbrush.pointed")
            }
            Toggle(isOn: $speechMode) {
                Label("Speak", systemImage: "waveform")
            }
            Toggle(isOn: Binding(
                get: { store.webSearchEnabled },
                set: { store.webSearchEnabled = $0 }
            )) {
                Label("Web search", systemImage: "globe")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
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
        .font(.caption.weight(.medium))
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
                    .font(.caption)
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
        let pages = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
        return document.ocrPageCount > 0 ? "\(pages) · OCR" : pages
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.title3)
                .foregroundStyle(Theme.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
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
