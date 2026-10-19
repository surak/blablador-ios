import ImageIO
import PhotosUI
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var synthesizer = SpeechSynthesizer()
    @ObservedObject private var siri = SiriCommandCenter.shared

    @State private var draft = ""
    @State private var attachments: [Data] = []
    @State private var imageMode = false
    @State private var showHistory = false
    @State private var showSettings = false
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
        .task {
            await store.loadModels()
            await store.loadUserName()
            if store.apiKey.isEmpty { showSettings = true }
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
            ComposerView(draft: $draft, attachments: $attachments, imageMode: $imageMode, speech: speech, focused: $inputFocused, onSend: send)
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
#else
        ToolbarItem(placement: .principal) {
            ModelMenu()
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
        }
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
        draft = ""
        attachments = []
        store.send(text, attachments: images, createImage: imageMode)
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
            Label {
                Text(store.selectedModelName)
            } icon: {
                Image("Avatar")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .labelStyle(.titleAndIcon)
#else
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image("Avatar")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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
    @Binding var imageMode: Bool
    @ObservedObject var speech: SpeechRecognizer
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @EnvironmentObject private var store: ChatStore
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var placeholder: String {
        if speech.isRecording { return "Listening…" }
        if imageMode { return attachments.isEmpty ? "Describe an image" : "Describe the change" }
        return "Ask Blablador"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                attachmentStrip
            }
            if imageMode {
                imageModeChip
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
                        Image(systemName: imageMode ? "paintbrush.pointed.fill" : "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(imageMode ? "Create image" : "Send")
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
            Divider()
            Toggle(isOn: $imageMode) {
                Label("Create image", systemImage: "paintbrush.pointed")
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
            Image(systemName: "paintbrush.pointed.fill")
            Text(attachments.isEmpty ? "Image · \(store.imageModelName)" : "Edit image · Qwen-Image")
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
