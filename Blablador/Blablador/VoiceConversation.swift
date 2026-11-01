import AVFoundation
import NaturalLanguage
import os
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

    /// Opens the conversation (blablador://talk).
    static let open = Notification.Name("BlabladorTalk")
    /// Asked right away when the conversation opens (blablador://talk?q=…).
    static var firstQuestion: String?
    private static let log = Logger(subsystem: "de.fz-juelich.blablador", category: "talk")

    /// Seconds a sentence may take with Drama 3 before the device speaks it.
    nonisolated static let voiceTimeout: Double = 6

    /// Seconds of quiet after speech that end the user's turn.
    static let pause: TimeInterval = 1.2

    private weak var store: ChatStore?
    private var recognizer = VoiceConversation.recognizer(for: UserDefaults.standard.string(forKey: "conversationLanguage") ?? "")
    @AppStorage("conversationLanguage") private var languageStored = ""

    /// The language the user speaks and Blablador answers in; "" follows the system.
    var language: String {
        get { languageStored }
        set {
            objectWillChange.send()
            languageStored = newValue
            recognizer = Self.recognizer(for: newValue)
            store?.voiceLanguage = Self.englishName(newValue)
            if running, phase == .listening { newRequest() }
        }
    }

    static func recognizer(for language: String) -> SFSpeechRecognizer? {
        (language.isEmpty ? nil : SFSpeechRecognizer(locale: Locale(identifier: language)))
            ?? SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Languages speech recognition knows, named in the user's language.
    static var languages: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    static func englishName(_ language: String) -> String? {
        language.isEmpty ? nil : Locale(identifier: "en").localizedString(forIdentifier: language)
    }
    /// Listens (on iOS with voice processing, i.e. echo cancellation) and plays the reply.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
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
    /// The reply's text up to `consumed`, to notice when it's rewritten.
    private var queuedText = ""
    private var spokenWords: Set<String> = []
    private var queue: [Task<[AVAudioPCMBuffer], Never>] = []
    private var playLoop: Task<Void, Never>?
    private var playing: Once?
    private var generation = 0
    private var running = false
    private var buffersSeen = 0
    private var askedApproval: UUID?
    private var approvalHeard = false

    func start(with store: ChatStore) async {
        guard !running else { return }
        self.store = store
        Self.log.notice("starting")
        guard await Self.permissions() else {
            Self.log.notice("no permission")
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
            do {
#if os(macOS)
                // On the Mac a failed attempt at voice processing leaves the microphone silent; skip it.
                try startEngine(voiceProcessing: false)
#else
                try startEngine(voiceProcessing: true)
#endif
            } catch {
                // Some microphones and speaker setups can't do echo cancellation; without it the
                // check for words from the reply keeps the echo from interrupting.
                Self.log.notice("voice processing failed: \(error.localizedDescription, privacy: .public)")
                teardownEngine()
                try startEngine(voiceProcessing: false)
            }
            Self.log.notice("started, voice processing \(self.voiceProcessing), on-device \(recognizer.supportsOnDeviceRecognition)")
        } catch {
            Self.log.notice("audio failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The microphone couldn't be started: \(error.localizedDescription)"
            return
        }
        running = true
        lastSound = Date()
        store.voiceLanguage = Self.englishName(language)
        store.voiceConversation = true
        listen()
        if let question = Self.firstQuestion {
            Self.firstQuestion = nil
            submit(question)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var voiceProcessing = false

    private func startEngine(voiceProcessing: Bool) throws {
        self.voiceProcessing = voiceProcessing
        if voiceProcessing {
            // Echo cancellation: the reply played through this engine isn't heard as the user speaking.
            try engine.inputNode.setVoiceProcessingEnabled(true)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let handler = microphoneHandler
#if os(macOS)
        // The Mac listens through AVCaptureSession: AVAudioEngine's input stalls when a headset like
        // AirPods switches to its microphone mode, and the engine here only plays.
        try microphone.start(handler)
#else
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Blablador", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone was found."])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in handler(buffer) }
#endif
        engine.prepare()
        try engine.start()
        player.play()
        // Headsets such as AirPods switch modes when the microphone opens, which stops the engine.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAudio() }
        }
    }

    private var configurationObserver: NSObjectProtocol?
    /// Set when the microphone has delivered only silence for a while, e.g. a MacBook with its lid closed.
    @Published private(set) var silentMicrophone: String?
    private var lastSound = Date()

    private func checkMicrophone() {
#if os(macOS)
        if microphone.isStale {
            Self.log.notice("input device changed, switching")
            try? microphone.start(microphoneHandler)
            lastSound = Date()
            silentMicrophone = nil
            if phase == .listening { newRequest() }
            return
        }
        let name = microphone.deviceName
#else
        let name = "the microphone"
#endif
        if level > 0 { lastSound = Date() }
        let silent = phase != .paused && Date().timeIntervalSince(lastSound) > 3
        if silent != (silentMicrophone != nil) { silentMicrophone = silent ? name : nil }
    }
#if os(macOS)
    private let microphone = MicrophoneCapture()
#endif

    /// Feeds microphone audio to the recognizer (as mono) and the level meter; called on an audio thread.
    private var microphoneHandler: @Sendable (AVAudioPCMBuffer) -> Void {
        let requests = requests
        return { [weak self] buffer in
            let mono = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)!
            let single = Self.mixed(buffer, as: mono) ?? buffer
            requests.append(single)
            let level = Self.level(of: single)
            Task { @MainActor in
                guard let self else { return }
                self.level = level
                self.buffersSeen += 1
                if self.buffersSeen % 200 == 1 { Self.log.notice("audio \(self.buffersSeen) buffers, level \(level), \(buffer.format.description, privacy: .public)") }
            }
        }
    }

    private func restartAudio() {
        guard running else { return }
        Self.log.notice("audio configuration changed, restarting")
        silence()
        teardownEngine()
        do {
            try startEngine(voiceProcessing: voiceProcessing)
        } catch {
            Self.log.notice("restart failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The microphone stopped: \(error.localizedDescription)"
        }
        if phase == .thinking || phase == .speaking { listen() }
    }

    private func teardownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
#if os(macOS)
        microphone.stop()
#else
        engine.inputNode.removeTap(onBus: 0)
#endif
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
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
        teardownEngine()
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
        Self.log.notice("listening")
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
        Self.log.notice("new request, recognizer available \(self.recognizer?.isAvailable ?? false)")
        transcript = ""
        heard = carried
        lastHeard = Date()
        let id = UUID()
        requestID = id
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            if let error { Self.log.notice("recognition ended: \(error.localizedDescription, privacy: .public)") }
            if let text { Self.log.notice("heard: \(text, privacy: .private)") }
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
        checkMicrophone()
        switch phase {
        case .listening:
            if !heard.trimmingCharacters(in: .whitespaces).isEmpty, Date().timeIntervalSince(lastHeard) > Self.pause {
                submit(heard)
            }
        case .thinking, .speaking:
            if let approval = store.commandApproval {
                if askedApproval != approval.id {
                    askedApproval = approval.id
                    approvalHeard = false
                    enqueue(approval.title + " Say yes or no.", device: true)
                }
                // Listen for the answer only once the question was spoken, so its echo doesn't count.
                guard queue.isEmpty, playing == nil else { return }
                if !approvalHeard {
                    approvalHeard = true
                    newRequest()
                    return
                }
                // A tool waits for the user's OK: "yes" allows it once, "no" denies it.
                let words = Self.words(transcript)
                if words.contains(where: Self.yesWords.contains) || words.contains(where: Self.noWords.contains) {
                    let allow = words.contains(where: Self.yesWords.contains) && !words.contains(where: Self.noWords.contains)
                    Self.log.notice("approval \(approval.title, privacy: .public): \(allow ? "allowed" : "denied")")
                    store.answerApproval(allow ? .once : .deny)
                    newRequest()
                }
                return
            }
            let words = Self.words(transcript)
            let fresh = words.filter { !spokenWords.contains($0) }
            let stopWord = words.last.map { Self.stopWords.contains($0) && !spokenWords.contains($0) } ?? false
            if fresh.count >= 2 || stopWord {
                interrupt(keeping: stopWord && fresh.count < 2 ? "" : transcript)
                return
            }
            feed()
            // The play loop still runs while the next sentence's audio is being made.
            if !store.isStreaming, isCaughtUp, queue.isEmpty, playing == nil, playLoop == nil { listen() }
        case .paused, .starting:
            break
        }
    }

    private static let yesWords: Set<String> = ["yes", "yeah", "yep", "allow", "ok", "okay", "sure", "ja", "oui", "si", "sí"]
    private static let noWords: Set<String> = ["no", "nope", "deny", "don't", "nein", "non"]
    private static let stopWords: Set<String> = ["stop", "wait", "stopp", "warte", "halt", "arrête"]

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else { return }
        if store.isStreaming { store.stop() }
        carried = ""
        phase = .thinking
        generation += 1
        consumed = 0
        queuedText = ""
        spokenWords = []
        newRequest()
        heard = ""
        Self.log.notice("sending: \(text, privacy: .private)")
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
        // The reply was rewritten (e.g. a tool's notes replaced): don't read fragments of it.
        guard text.hasPrefix(queuedText) else {
            Self.log.notice("reply changed, skipping")
            queuedText = text
            consumed = text.count
            return
        }
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
        queuedText += chunk
        let spoken = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spoken.contains(where: \.isLetter) || spoken.contains(where: \.isNumber) else { return }
        spokenWords.formUnion(Self.words(spoken))
        enqueue(spoken)
    }

    private func enqueue(_ text: String, device: Bool = false) {
        let format = format
        let job: Task<[AVAudioPCMBuffer], Never>
        if speaker == .blablador, !device, let api = store?.api {
            let library = VoiceLibrary.shared
            let voice = library.selected
            let styled = library.styled(text)
            job = Task {
                let started = Date()
                // A voice that is too slow for a conversation gives way to the device's voice for this sentence.
                let data = await withTaskGroup(of: Data?.self) { group in
                    group.addTask { try? await api.speech(text: styled, voice: voice) }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(Self.voiceTimeout))
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                Self.log.notice("Drama 3 \(data == nil ? "gave up" : "answered", privacy: .public) after \(Date().timeIntervalSince(started)) s")
                if let data, let buffers = try? Self.decode(data, to: format), !buffers.isEmpty {
                    return buffers
                }
                return await Self.deviceSpeech(text, to: format)
            }
        } else {
            job = Task { await Self.deviceSpeech(text, to: format) }
        }
        Self.log.notice("speaking with \(self.speaker.rawValue, privacy: .public): \(text, privacy: .private)")
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
                Self.log.notice("playing \(buffers.count) buffers, \(buffers.reduce(0) { $0 + Int($1.frameLength) }) frames")
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

    /// All channels mixed into one.
    private nonisolated static func mixed(_ buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1, let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = copy.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        copy.frameLength = buffer.frameLength
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[channel][frame] }
            target[frame] = sum / Float(channels)
        }
        return copy
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

#if os(macOS)
/// The Mac's default microphone through AVCaptureSession, delivered as PCM buffers.
private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var session: AVCaptureSession?
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "de.fz-juelich.blablador.microphone")
    private(set) var deviceID: String?
    private(set) var deviceName = ""

    /// The system's input changed (e.g. AirPods connected) since the session started.
    var isStale: Bool { session != nil && AVCaptureDevice.default(for: .audio)?.uniqueID != deviceID }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Blablador", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone was found."])
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        deviceID = device.uniqueID
        deviceName = device.localizedName
        let output = AVCaptureAudioDataOutput()
        // Float PCM, which the recognizer and the level meter read directly.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "Blablador", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone can't be used right now."])
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        self.handler = handler
        self.session = session
        session.startRunning()
    }

    func stop() {
        session?.stopRunning()
        session = nil
        handler = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        handler(buffer)
    }
}
#endif

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
                Picker(selection: Binding(
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
                    ForEach(voices.voices) { voice in
                        Text(voice.isCloned ? "\(voice.name) (cloned, slow)" : voice.name).tag(voice.id)
                    }
                    Divider()
                    Text("This device's voice (fastest)").tag("device")
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .pickerStyle(.menu)
                .tint(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
                .fixedSize()
                Picker(selection: Binding(get: { conversation.language }, set: { conversation.language = $0 })) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(VoiceConversation.languages, id: \.id) { Text($0.name).tag($0.id) }
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)
                .tint(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
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

            Spacer(minLength: 0)
            orb
            VStack(spacing: 10) {
                Text(status)
                    .scaledFont(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                Text(caption)
                    .scaledFont(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(maxWidth: 520, minHeight: 60, alignment: .top)
                    .animation(.default, value: caption)
            }
            Spacer(minLength: 0)

            if let approval = store.commandApproval {
                VStack(spacing: 8) {
                    CommandApprovalCard(approval: approval) { store.answerApproval($0) }
                        .foregroundStyle(.primary)
                        .environment(\.colorScheme, .dark)
                    Text("Or say “yes” or “no”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
        .frame(width: 460, height: 620)
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
        .scaleEffect(store.commandApproval == nil ? 1 : 0.6)
        .frame(height: store.commandApproval == nil ? 260 : 160)
        .animation(.spring(duration: 0.4), value: store.commandApproval == nil)
        .contentShape(Circle())
        .onTapGesture { conversation.tap() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(status)
    }

    private var status: String {
        switch conversation.phase {
        case .starting: "Starting…"
        case .listening:
            if let microphone = conversation.silentMicrophone {
#if os(macOS)
                "No sound from \(microphone). Is the lid closed? Choose another input in System Settings → Sound, or connect AirPods."
#else
                "No sound from \(microphone)."
#endif
            } else {
                conversation.heard.isEmpty ? "Listening…" : "Listening · tap to send now"
            }
        case .thinking: store.commandApproval != nil ? "Blablador needs your OK" : replyStatus ?? "Thinking…"
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
