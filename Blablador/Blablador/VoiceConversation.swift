import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

/// Talking with Blablador: listens, sends what was said when the user pauses, reads the reply aloud while it
/// streams (Drama 3 with the selected voice, or the device's voice) and listens again. Speaking over the reply
/// interrupts it. One audio engine with voice processing does both, so the echo of the reply is cancelled.
@MainActor
final class VoiceConversation: ObservableObject {
    enum Phase { case starting, listening, thinking, speaking, paused }
    enum Speaker: String { case blablador, device }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var heard = ""
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?
    @AppStorage("conversationSpeaker") private var speakerName = Speaker.blablador.rawValue

    var speaker: Speaker {
        get { Speaker(rawValue: speakerName) ?? .blablador }
        set { objectWillChange.send(); speakerName = newValue.rawValue }
    }

    /// The reply being spoken.
    private(set) var replyID: UUID?

    /// Seconds of quiet after speech that end the user's turn.
    static let pause: TimeInterval = 1.2

    private weak var store: ChatStore?
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let requests = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var requestID = UUID()
    private var transcript = ""
    /// Words said over the reply that interrupted it; the turn continues from them.
    private var carried = ""
    private var lastHeard = Date()
    private var timer: Timer?
    private var consumed = 0
    private var spokenWords: Set<String> = []
    private var queue: [Task<[AVAudioPCMBuffer], Never>] = []
    private var playLoop: Task<Void, Never>?
    private var playing: Once?
    private var generation = 0
    private var running = false

    func start(with store: ChatStore) async {
        guard !running else { return }
        self.store = store
        guard await Self.permissions() else {
            errorMessage = "Allow the microphone and speech recognition for Blablador in Settings to talk with it."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        do {
#if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true)
            UIApplication.shared.isIdleTimerDisabled = true
#endif
            // Echo cancellation: the reply played through this engine isn't heard as the user speaking.
            try? engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let input = engine.inputNode
            let requests = requests
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                requests.append(buffer)
                let level = Self.level(of: buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        running = true
        store.voiceConversation = true
        listen()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        silence()
        task?.cancel()
        task = nil
        requests.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        store?.voiceConversation = false
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    /// The orb: interrupts a reply, resumes after a pause, or ends the turn right away.
    func tap() {
        switch phase {
        case .thinking, .speaking: interrupt(keeping: "")
        case .paused: listen()
        case .listening: if !heard.isEmpty { submit(heard) }
        case .starting: break
        }
    }

    func togglePause() {
        if phase == .paused {
            listen()
        } else {
            interrupt(keeping: "")
            phase = .paused
            task?.cancel()
            requests.set(nil)
            heard = ""
        }
    }

    // MARK: - Listening

    private func listen() {
        carried = ""
        phase = .listening
        newRequest()
    }

    /// A fresh recognition request; what was heard before is dropped.
    private func newRequest() {
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        requests.set(request)
        transcript = ""
        heard = carried
        lastHeard = Date()
        let id = UUID()
        requestID = id
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, self.running, self.requestID == id else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastHeard = Date()
                    if self.phase == .listening { self.heard = Self.joined(self.carried, text) }
                }
                if ended {
                    if self.phase == .listening, !self.heard.isEmpty {
                        self.submit(self.heard)
                    } else if self.phase != .paused {
                        // Recognition stops after a long silence; keep listening.
                        try? await Task.sleep(for: .milliseconds(300))
                        if self.requestID == id { self.newRequest() }
                    }
                }
            }
        }
    }

    private func tick() {
        guard running, let store else { return }
        switch phase {
        case .listening:
            if !heard.trimmingCharacters(in: .whitespaces).isEmpty, Date().timeIntervalSince(lastHeard) > Self.pause {
                submit(heard)
            }
        case .thinking, .speaking:
            let words = Self.words(transcript)
            let fresh = words.filter { !spokenWords.contains($0) }
            let stopWord = words.last.map { Self.stopWords.contains($0) && !spokenWords.contains($0) } ?? false
            if fresh.count >= 2 || stopWord {
                interrupt(keeping: stopWord && fresh.count < 2 ? "" : transcript)
                return
            }
            feed()
            if !store.isStreaming, isCaughtUp, queue.isEmpty, playing == nil { listen() }
        case .paused, .starting:
            break
        }
    }

    private static let stopWords: Set<String> = ["stop", "wait", "stopp", "warte", "halt", "arrête"]

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else { return }
        if store.isStreaming { store.stop() }
        carried = ""
        phase = .thinking
        generation += 1
        consumed = 0
        spokenWords = []
        newRequest()
        heard = ""
        store.send(text)
        replyID = store.current?.messages.last { $0.role == .assistant }?.id
    }

    /// Stops the reply and its speech, and listens; words said over it start the next turn.
    private func interrupt(keeping words: String) {
        silence()
        if store?.isStreaming == true { store?.stop() }
        let fresh = Self.words(words).filter { !spokenWords.contains($0) }
        phase = .listening
        carried = fresh.joined(separator: " ")
        newRequest()
    }

    // MARK: - Speaking

    /// The reply's text so far, as it is read out.
    private var replyText: String {
        guard let replyID, let message = store?.message(replyID) else { return "" }
        if message.isError { return message.content }
        return SpeechSynthesizer.speakableText(ChatStore.splitThinking(message.content).answer)
    }

    private var isCaughtUp: Bool { replyText.count <= consumed }

    /// Queues the next finished sentences of the streaming reply.
    private func feed() {
        guard let store else { return }
        let text = replyText
        guard text.count > consumed else { return }
        let finished = !store.isStreaming
        let rest = String(text.dropFirst(consumed))
        var end = rest.endIndex
        if !finished {
            guard let last = rest.ranges(of: #/[.!?…:;](\s|$)|\n/#).last?.upperBound else { return }
            end = last
        }
        let chunk = String(rest[..<end])
        // Drama 3 takes a few seconds per request: speak the first sentence soon, then bigger pieces.
        let minimum = speaker == .device ? 1 : (queue.isEmpty && playing == nil ? 30 : 90)
        guard finished || chunk.count >= minimum else { return }
        consumed += chunk.count
        let spoken = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spoken.contains(where: \.isLetter) || spoken.contains(where: \.isNumber) else { return }
        spokenWords.formUnion(Self.words(spoken))
        enqueue(spoken)
    }

    private func enqueue(_ text: String) {
        let format = format
        let job: Task<[AVAudioPCMBuffer], Never>
        if speaker == .blablador, let api = store?.api {
            let library = VoiceLibrary.shared
            let voice = library.selected
            let styled = library.styled(text)
            job = Task {
                if let data = try? await api.speech(text: styled, voice: voice), let buffers = try? Self.decode(data, to: format) {
                    return buffers
                }
                return await Self.deviceSpeech(text, to: format)
            }
        } else {
            job = Task { await Self.deviceSpeech(text, to: format) }
        }
        queue.append(job)
        if playLoop == nil {
            let generation = generation
            playLoop = Task { await play(generation) }
        }
    }

    private func play(_ generation: Int) async {
        do {
            while !queue.isEmpty, self.generation == generation {
                let job = queue.removeFirst()
                let buffers = await job.value
                guard self.generation == generation else { break }
                guard !buffers.isEmpty else { continue }
                phase = .speaking
                let once = Once()
                playing = once
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    for (index, buffer) in buffers.enumerated() {
                        if index == buffers.count - 1 {
                            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in once.resume() }
                        } else {
                            player.scheduleBuffer(buffer)
                        }
                    }
                }
                if playing === once { playing = nil }
            }
            if self.generation == generation { playLoop = nil }
        }
    }

    /// Stops speaking and drops what was queued.
    private func silence() {
        generation += 1
        queue.forEach { $0.cancel() }
        queue = []
        playLoop = nil
        player.stop()
        playing?.resume()
        playing = nil
        if running { player.play() }
    }

    // MARK: - Audio

    nonisolated static func decode(_ data: Data, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return convert([buffer], to: format)
    }

    /// The device's voice for the text's language, rendered to buffers so it plays through the engine.
    static func deviceSpeech(_ text: String, to format: AVAudioFormat) async -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechSynthesizer.voice(for: text)
        let collected = BufferBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            once.set(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    once.resume()
                    return
                }
                collected.append(pcm)
            }
        }
        _ = synthesizer
        return convert(collected.buffers, to: format)
    }

    nonisolated static func convert(_ buffers: [AVAudioPCMBuffer], to format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        guard let first = buffers.first, let converter = AVAudioConverter(from: first.format, to: format) else { return [] }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(total) * format.sampleRate / first.format.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var remaining = buffers
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !remaining.isEmpty else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return remaining.removeFirst()
        }
        return output.frameLength > 0 ? [output] : []
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return min(1, sqrt(sum / Float(count)) * 12)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func joined(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func permissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
#if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
#else
        return await AVCaptureDevice.requestAccess(for: .audio)
#endif
    }
}

/// The recognition request the microphone tap feeds, swapped between turns.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request?.endAudio()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }
}

private final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AVAudioPCMBuffer] = []
    var buffers: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); stored.append(buffer); lock.unlock() }
}

/// Resumes a continuation once, whichever comes first: the audio finishing or being stopped.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if done { lock.unlock(); continuation.resume(); return }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        done = true
        lock.unlock()
        continuation?.resume()
    }
}

/// Full-screen conversation: the orb, what was heard or is being said, the voice, pause and end.
struct VoiceConversationView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var conversation = VoiceConversation()
    @ObservedObject private var voices = VoiceLibrary.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Menu {
                    Picker("Voice", selection: Binding(
                        get: { conversation.speaker == .device ? "device" : voices.selectedID },
                        set: { id in
                            if id == "device" {
                                conversation.speaker = .device
                            } else {
                                conversation.speaker = .blablador
                                voices.selectedID = id
                            }
                        }
                    )) {
                        ForEach(voices.voices) { Text($0.name).tag($0.id) }
                        Text("This device's voice (faster)").tag("device")
                    }
                } label: {
                    Label(conversation.speaker == .device ? "Device voice" : voices.selected.name, systemImage: "person.wave.2")
                        .scaledFont(.subheadline, weight: .medium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.body, weight: .semibold)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End conversation")
                .keyboardShortcut(.cancelAction)
            }

            Spacer()
            orb
            VStack(spacing: 10) {
                Text(status)
                    .scaledFont(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                Text(caption)
                    .scaledFont(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(maxWidth: 520, minHeight: 120, alignment: .top)
                    .animation(.default, value: caption)
            }
            Spacer()

            HStack(spacing: 40) {
                Button { conversation.togglePause() } label: {
                    Image(systemName: conversation.phase == .paused ? "mic.slash.fill" : "mic.fill")
                        .scaledFont(.title2)
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(conversation.phase == .paused ? 0.3 : 0.12), in: Circle())
                }
                .accessibilityLabel(conversation.phase == .paused ? "Resume listening" : "Pause listening")
                Button { close() } label: {
                    Image(systemName: "phone.down.fill")
                        .scaledFont(.title2)
                        .frame(width: 64, height: 64)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("End conversation")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(
            LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.27), Color(red: 0.04, green: 0.04, blue: 0.1)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .task { await conversation.start(with: store) }
        .onDisappear { conversation.stop() }
        .alert("Talking with Blablador", isPresented: Binding(
            get: { conversation.errorMessage != nil },
            set: { if !$0 { conversation.errorMessage = nil; close() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversation.errorMessage ?? "")
        }
#if os(macOS)
        .frame(width: 440, height: 640)
#endif
    }

    private var orb: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse: CGFloat = switch conversation.phase {
            case .listening: 1 + CGFloat(conversation.level) * 0.35
            case .speaking: 1 + 0.06 * CGFloat(sin(time * 7)) + 0.04 * CGFloat(sin(time * 11.3))
            case .thinking: 1 + 0.03 * CGFloat(sin(time * 3))
            default: 1
            }
            ZStack {
                Circle()
                    .fill(Theme.gradient)
                    .frame(width: 200, height: 200)
                    .scaleEffect(pulse * 1.15)
                    .opacity(conversation.phase == .paused ? 0.15 : 0.35)
                    .blur(radius: 24)
                Circle()
                    .fill(Theme.gradient)
                    .frame(width: 170, height: 170)
                    .scaleEffect(pulse)
                    .rotationEffect(.degrees(conversation.phase == .thinking ? time * 90 : 0))
                Image("Avatar")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .opacity(conversation.phase == .paused ? 0.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: conversation.level)
        }
        .frame(width: 260, height: 260)
        .contentShape(Circle())
        .onTapGesture { conversation.tap() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(status)
    }

    private var status: String {
        switch conversation.phase {
        case .starting: "Starting…"
        case .listening: conversation.heard.isEmpty ? "Listening…" : "Listening · tap to send now"
        case .thinking: replyStatus ?? "Thinking…"
        case .speaking: "Speaking · talk or tap to interrupt"
        case .paused: "Paused · tap to talk"
        }
    }

    private var replyStatus: String? {
        conversation.replyID.flatMap { store.message($0)?.status }
    }

    private var caption: String {
        switch conversation.phase {
        case .listening: conversation.heard
        case .speaking, .thinking:
            conversation.replyID.flatMap { store.message($0) }.map { SpeechSynthesizer.speakableText(ChatStore.splitThinking($0.content).answer) }
                .map { String($0.suffix(280)) } ?? ""
        default: ""
        }
    }

    private func close() {
        conversation.stop()
        dismiss()
    }
}
