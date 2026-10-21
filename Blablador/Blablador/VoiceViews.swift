import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Play button for generated speech in a reply.
/// A generated video with its sound, playable in the chat.
struct VideoClip: View {
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VideoPlayer(player: player)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: 520, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            ShareLink(item: VideoStore.url(for: name)) {
                Label("Save or share", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .onAppear { if player == nil { player = AVPlayer(url: VideoStore.url(for: name)) } }
        .onDisappear { player?.pause() }
    }

    private var aspectRatio: CGFloat {
        guard let track = AVAsset(url: VideoStore.url(for: name)).tracks(withMediaType: .video).first else { return 16 / 9 }
        let size = track.naturalSize.applying(track.preferredTransform)
        return size.height == 0 ? 16 / 9 : abs(size.width / size.height)
    }
}

struct SpeechClip: View {
    let name: String
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var saving = false

    var body: some View {
        let playing = playback.playingName == name
        HStack(spacing: 12) {
            Button {
                playback.toggle(name)
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.white)
                    .background(Theme.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Stop" : "Play speech")
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: playing)
                .font(.title2)
                .foregroundStyle(Theme.gradient)
            Button {
                saving = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Save audio")
            .fileExporter(isPresented: $saving, document: AudioFile(url: AudioStore.url(for: name)),
                          contentType: .mp3, defaultFilename: "Blablador speech") { _ in }
        }
        .padding(8)
        .padding(.trailing, 8)
        .background(Theme.surface, in: Capsule())
    }
}

/// Generated speech handed to the Save dialog.
struct AudioFile: FileDocument {
    static let readableContentTypes: [UTType] = [.mp3]
    var data: Data

    init(url: URL) { data = (try? Data(contentsOf: url)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Composer chip shown in speech mode: voice picker and leave button.
struct SpeechModeChip: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = VoiceLibrary.shared
    @State private var cloning = false
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(library.voices) { voice in
                    Button {
                        library.selectedID = voice.id
                    } label: {
                        if voice.id == library.selectedID {
                            Label(voice.name, systemImage: "checkmark")
                        } else {
                            Text(voice.name)
                        }
                    }
                }
                Divider()
                Button { cloning = true } label: {
                    Label("Clone a voice…", systemImage: "person.wave.2")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text("\(library.selected.name) · \(library.emotion == .neutral ? "Drama 3" : library.emotion.title)")
                    Image(systemName: "chevron.down").imageScale(.small)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Voice, \(library.selected.name)")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave speech mode")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.gradient, in: Capsule())
        .sheet(isPresented: $cloning) { AddVoiceView().environmentObject(store) }
    }
}

/// Inserts Drama 3 sounds, pauses and tags into the draft.
struct SpeechMarkupMenu: View {
    @Binding var draft: String

    var body: some View {
        Menu {
            Section("Sounds and pauses") {
                ForEach(SpeechMarkup.sounds, id: \.self) { sound in
                    Button(sound) { insert(sound) }
                }
            }
            Section("Delivery") {
                ForEach(SpeechMarkup.tags, id: \.tag) { item in
                    Button(item.title) { insert("<\(item.tag)></\(item.tag)>") }
                }
                Button("Direction […]") { insert("[]") }
            }
            Menu("Language") {
                ForEach(SpeechMarkup.languages, id: \.self) { language in
                    Button(language.capitalized) { insert("<\(language)></\(language)>") }
                }
            }
        } label: {
            Label("Expressions", systemImage: "theatermasks")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func insert(_ markup: String) {
        if !draft.isEmpty && !draft.hasSuffix(" ") { draft += " " }
        draft += markup
    }
}

/// Settings section for Drama 3 voices and delivery.
struct VoiceSettingsSection: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = VoiceLibrary.shared
    @State private var cloning = false

    var body: some View {
        Section {
            Picker("Voice", selection: $library.selectedID) {
                ForEach(library.voices) { voice in
                    Text(voice.isCloned ? "\(voice.name) (cloned)" : voice.name).tag(voice.id)
                }
            }
            Button { cloning = true } label: {
                Label("Clone a voice…", systemImage: "person.wave.2")
            }
            .sheet(isPresented: $cloning) { AddVoiceView().environmentObject(store) }
            NavigationLink("Manage voices") { VoicesView() }
            Picker("Feeling", selection: $library.emotion) {
                ForEach(SpeechEmotion.allCases) { Text($0.title).tag($0) }
            }
            if library.emotion == .custom {
                TextField("e.g. tired after a long day, but amused", text: $library.customDirection, axis: .vertical)
            }
            Picker("Pace", selection: $library.pace) {
                ForEach(SpeechPace.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Whisper", isOn: $library.whisper)
            Toggle("Let the assistant speak", isOn: $library.toolsEnabled)
        } header: {
            Text("Voice")
        } footer: {
            Text("Speech is created with Drama 3. In speech mode, add pauses, laughs, whispers and more with the Expressions menu.")
        }
    }
}

struct VoicesView: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = VoiceLibrary.shared
    @State private var adding = false

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(VoiceLibrary.builtIn) { row($0) }
            }
            Section {
                ForEach(library.cloned) { row($0) }
                    .onDelete { offsets in
                        offsets.map { library.cloned[$0] }.forEach(library.delete)
                    }
                Button {
                    adding = true
                } label: {
                    Label("Clone a voice", systemImage: "plus")
                }
            } header: {
                Text("Cloned")
            } footer: {
                Text("Only clone your own voice or voices you have permission to use.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voices")
        .sheet(isPresented: $adding) { AddVoiceView().environmentObject(store) }
    }

    private func row(_ voice: Voice) -> some View {
        Button {
            library.selectedID = voice.id
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(voice.name).foregroundStyle(.primary)
                    if voice.isCloned {
                        Text(voice.transcript).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if voice.id == library.selectedID {
                    Image(systemName: "checkmark").foregroundStyle(Theme.gradient)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
#if os(macOS)
        .contextMenu {
            if voice.isCloned {
                Button("Delete", role: .destructive) { library.delete(voice) }
            }
        }
#endif
    }
}

/// Collects a reference sample by recording, importing a file or downloading a link, then transcribes it.
struct AddVoiceView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()

    @State private var name = ""
    @State private var link = ""
    @State private var sample: Data?
    @State private var transcript = ""
    @State private var working: String?
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. My voice", text: $name)
                }
                Section {
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        if recorder.isRecording {
                            Label("Stop recording · \(Int(recorder.elapsed))s / \(Int(VoiceLibrary.maxSampleSeconds))s", systemImage: "stop.circle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Label("Record a sample", systemImage: "mic")
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Choose an audio or video file", systemImage: "folder")
                    }
                    HStack {
                        TextField("Link to an audio or video file", text: $link)
                            .autocorrectionDisabled()
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                        Button("Fetch") { Task { await fetch() } }
                            .disabled(URL(string: link)?.scheme?.hasPrefix("http") != true)
                    }
                } header: {
                    Text("Sample")
                } footer: {
                    Text("10–30 seconds of clear speech from one person, without music. Longer files are cut to the first 30 seconds.")
                }
                if let working {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(working)
                        }
                    }
                }
                if let sample {
                    Section {
                        Button {
                            AudioPlayback.shared.play(data: sample)
                        } label: {
                            Label("Play sample", systemImage: "play.circle")
                        }
                        TextField("What is said in the sample", text: $transcript, axis: .vertical)
                            .lineLimit(2...8)
                    } header: {
                        Text("Transcript")
                    } footer: {
                        Text("Transcribed with Whisper. Fix any mistakes; an exact transcript gives a better clone.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clone a voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        _ = recorder.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let sample else { return }
                        VoiceLibrary.shared.add(name: name.trimmingCharacters(in: .whitespaces), sample: sample, transcript: transcript)
                        dismiss()
                    }
                    .disabled(sample == nil || working != nil || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    await load("Reading file…") {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        return try await VoiceLibrary.prepareSample(from: url)
                    }
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
#endif
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            if let data = recorder.stop() { await load("Transcribing…") { data } }
        } else if await !recorder.start() {
            error = "Microphone access is needed to record. Allow it in Settings."
        }
    }

    private func fetch() async {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
        await load("Downloading…") { try await VoiceLibrary.downloadSample(from: url) }
    }

    /// Obtains a sample, then transcribes it with Whisper.
    private func load(_ status: String, _ obtain: () async throws -> Data) async {
        error = nil
        working = status
        defer { working = nil }
        do {
            let data = try await obtain()
            sample = data
            working = "Transcribing…"
            transcript = try await store.api.transcribe(audio: VoiceLibrary.wav(from: data))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
