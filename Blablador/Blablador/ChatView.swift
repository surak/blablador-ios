import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var synthesizer = SpeechSynthesizer()
    @ObservedObject private var siri = SiriCommandCenter.shared

    @State private var draft = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let conversation = store.current, !conversation.messages.isEmpty {
                    messageList(conversation)
                } else {
                    WelcomeView { prompt in
                        store.send(prompt)
                    }
                }
                ComposerView(draft: $draft, speech: speech, focused: $inputFocused, onSend: send)
            }
            .background(Theme.background)
            .toolbar { toolbar }
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .overlay { historyDrawer }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .task {
            await store.loadModels()
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.spring(duration: 0.3)) { showHistory = true }
            } label: {
                Label("Chats", systemImage: "line.3.horizontal")
            }
        }
        ToolbarItem(placement: .principal) {
            ModelMenu()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.newChat()
                draft = ""
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
        let text = draft
        draft = ""
        store.send(text)
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
            VStack(spacing: 0) {
                Text("Blablador")
                    .font(.headline)
                    .foregroundStyle(.primary)
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
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hello there")
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
    @ObservedObject var speech: SpeechRecognizer
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @EnvironmentObject private var store: ChatStore

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                store.webSearchEnabled.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.title3)
                    .frame(width: 36, height: 40)
                    .foregroundStyle(store.webSearchEnabled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.webSearchEnabled ? "Web search on" : "Web search off")

            TextField(speech.isRecording ? "Listening…" : "Ask Blablador", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.vertical, 10)
                .padding(.leading, 6)
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
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Theme.gradient, lineWidth: speech.isRecording ? 2 + CGFloat(speech.audioLevel) * 3 : 0)
                .animation(.easeOut(duration: 0.1), value: speech.audioLevel)
        }
        .animation(.spring(duration: 0.25), value: canSend)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
    }
}
