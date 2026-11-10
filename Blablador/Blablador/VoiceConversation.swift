import AVFoundation
#if os(macOS)
import CoreAudio
#endif
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
    /// What the user says, kept for Whisper when the language can't be recognised on the device.
    private let recording = RecordingBox()
    private var speechStarted: Date?
    private var lastVoice = Date()
    private var transcribing = false

    /// Languages Apple only recognises on its servers (unreliable for a running conversation) go to Whisper.
    var usesWhisper: Bool { !language.isEmpty && recognizer?.supportsOnDeviceRecognition != true }
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
    /// Until then the microphone still hears the end of the reply from the speakers (latency and the room).
    private var echoUntil = Date.distantPast
    private var queue: [Task<[AVAudioPCMBuffer], Never>] = []
    /// The text of each queued part, so it can be spoken again with another voice.
    private var queueTexts: [String] = []
    /// The part the play loop is waiting for.
    private var awaitingText: String?
    private var playLoop: Task<Void, Never>?
    /// The last cloned-voice request; the next one waits for it.
    private var clonedChain: Task<Data?, Never>?
    private var playing: Once?
    private var generation = 0
    private var running = false
    private var buffersSeen = 0
    /// Temporary: what the microphone and recognition are doing, shown under the buttons.
    @Published private(set) var diagnostics = ""
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
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true)
            UIApplication.shared.isIdleTimerDisabled = true
#endif
            do {
                // Voice processing (Apple's echo cancellation) silenced the microphone on the Mac and the iPad,
                // so it stays off; the check for the reply's own words keeps its echo from interrupting.
                try startEngine(voiceProcessing: false)
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
    /// When the reply last streamed or a sentence started playing.
    private var lastProgress = Date()
    /// When the last question was sent; the end of it mustn't count as talking over the answer.
    private var submittedAt = Date.distantPast

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
        let recording = recording
        return { [weak self] buffer in
            let mono = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)!
            let single = Self.mixed(buffer, as: mono) ?? buffer
            requests.append(single)
            recording.append(single)
            let level = Self.level(of: single)
            Task { @MainActor in
                guard let self else { return }
                self.level = level
                self.peak = max(self.peak, level)
                self.buffersSeen += 1
                if self.buffersSeen % 200 == 1 { Self.log.notice("audio \(self.buffersSeen) buffers, level \(level), \(buffer.format.description, privacy: .public)") }
            }
        }
    }

    private func restartAudio(attempt: Int = 1) {
        guard running else { return }
        Self.log.notice("audio configuration changed, restarting (attempt \(attempt))")
        silence()
        teardownEngine()
        do {
            try startEngine(voiceProcessing: voiceProcessing)
            audioProblem = nil
        } catch {
            Self.log.notice("restart failed: \(error.localizedDescription, privacy: .public)")
            // Devices switching (e.g. AirPods connecting) settle within a few seconds: try again.
            if attempt < 8 {
                audioProblem = "Switching audio devices…"
                Task {
                    try? await Task.sleep(for: .seconds(0.75))
                    self.restartAudio(attempt: attempt + 1)
                }
                return
            }
            audioProblem = "The microphone stopped (\(error.localizedDescription)). Tap the circle to try again."
        }
        if phase == .thinking || phase == .speaking { listen() }
    }

    /// Shown in place of the status while the audio isn't working; cleared once it is.
    @Published private(set) var audioProblem: String?
    /// A short note under the status, e.g. when nothing was understood; cleared when the user speaks.
    @Published private(set) var notice: String?

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

    /// Talking over the reply works only when it can't be heard by the microphone: headphones, not speakers.
    /// Recognised words still interrupt (the reply's own words don't count); levels alone don't.
    var canTalkOver: Bool { !usesWhisper || Self.headphones }

    static var headphones: Bool {
#if os(iOS)
        let kinds: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .carAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { kinds.contains($0.portType) }
#else
        func property<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: inout T) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        }
        var device = AudioObjectID(0)
        guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &device) else { return false }
        var transport = UInt32(0)
        guard property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport) else { return false }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE || transport == kAudioDeviceTransportTypeUSB { return true }
        // The built-in output with something plugged into the headphone jack.
        var source = UInt32(0)
        return transport == kAudioDeviceTransportTypeBuiltIn
            && property(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, &source)
            && source == 0x6864_706E // 'hdpn'
#endif
    }

    /// The orb: interrupts a reply, resumes after a pause, or ends the turn right away.
    func tap() {
        if audioProblem != nil {
            restartAudio()
            return
        }
        switch phase {
        case .thinking, .speaking: interrupt(keeping: "")
        case .paused: listen()
        case .listening:
            if usesWhisper {
                if speechStarted != nil { sendNow = true }
            } else if !heard.isEmpty {
                submit(heard)
            }
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
        // Right after a reply, what the microphone hears is mostly its echo.
        if !spokenWords.isEmpty { echoUntil = Date().addingTimeInterval(1.2) }
        newRequest()
    }

    /// Mostly the reply's own words: its echo from the speakers, not the user.
    func isEcho(_ text: String) -> Bool {
        let words = Self.words(text)
        guard !words.isEmpty, !spokenWords.isEmpty else { return false }
        let own = words.filter(spokenWords.contains).count
        return Double(own) / Double(words.count) >= 0.6
    }

    /// A fresh recognition request; what was heard before is dropped.
    private func newRequest() {
        task?.cancel()
        if usesWhisper {
            task = nil
            requests.set(nil)
            transcript = ""
            heard = carried
            recording.reset()
            speechStarted = nil
            return
        }
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
                if self.phase == .listening, Date() < self.echoUntil {
                    // The reply's echo: start over once it has died down.
                    if ended || text != nil { self.transcript = ""; self.heard = self.carried }
                    if ended { try? await Task.sleep(for: .milliseconds(300)); if self.requestID == id { self.newRequest() } }
                    return
                }
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
#if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "no input"
#else
        let route = ""
#endif
        diagnostics = "\(phase) · mic \(String(format: "%.2f", level)) (noise \(String(format: "%.2f", noiseFloor))) · \(buffersSeen) blocks · engine \(engine.isRunning ? "on" : "OFF") · \(usesWhisper ? "whisper" : "apple") · \(route)"
        let waiting = speaker == .blablador && playing == nil && (!queue.isEmpty || playLoop != nil)
        if waiting != waitingForVoice { waitingForVoice = waiting }
        switch phase {
        case .listening where usesWhisper:
            listenForWhisper()

        case .listening where Date() < echoUntil:
            peak = 0
            if usesWhisper { recording.reset(); speechStarted = nil }
            else if !transcript.isEmpty { newRequest() }

        case .listening:
            if !heard.trimmingCharacters(in: .whitespaces).isEmpty, Date().timeIntervalSince(lastHeard) > Self.pause {
                submit(heard)
            }
        case .thinking, .speaking:
            if usesWhisper, phase == .speaking || playing != nil, store.commandApproval == nil, !canTalkOver {
                // On speakers the reply's echo is as loud as a voice; a tap interrupts.
                peak = 0
            }
            else if usesWhisper, phase == .speaking || playing != nil, store.commandApproval == nil {
                // Talking over the reply: a voice clearly louder than the room (and than the reply's echo)
                // for about half a second stops it and starts the next question.
                // Clearly louder than the reply's own echo; a level not counted as a voice is learnt as echo.
                let loud = peak > max(0.15, noiseFloor * 6, echoLevel * 2.5)
                if !loud {
                    echoLevels.append(peak)
                    if echoLevels.count > 40 { echoLevels.removeFirst(echoLevels.count - 40) }
                    echoLevel = echoLevels.sorted()[echoLevels.count / 2]
                }
                peak = 0
                bargeTicks = loud ? bargeTicks + 1 : 0
                if bargeTicks >= 5 {
                    Self.log.notice("user talked over the reply")
                    bargeTicks = 0
                    peak = 0
                    silence()
                    if store.isStreaming { store.stop() }
                    phase = .listening
                    speechStarted = Date().addingTimeInterval(-0.45)
                    lastVoice = Date()
                    voicedTime = 0.45
                    heard = "…"
                    recording.keepLast(seconds: 1.5)
                    return
                }
            }
            else if usesWhisper, phase == .thinking, store.commandApproval == nil, playing == nil, queue.isEmpty, playLoop == nil,
                    Date().timeIntervalSince(submittedAt) > 1.5 {
                // Nothing is playing, so a voice now is the user's: stop the reply and take the new question,
                // keeping what is being recorded.
                let loud = peak > max(Self.voiceLevel, noiseFloor * 5)
                updateNoiseFloor(peak)
                peak = 0
                // Half a second of voice, not a single noise.
                bargeTicks = loud ? bargeTicks + 1 : 0
                if bargeTicks >= 3 {
                    Self.log.notice("user spoke while the reply was being made, taking the new question")
                    bargeTicks = 0
                    generation += 1
                    if store.isStreaming { store.stop() }
                    phase = .listening
                    speechStarted = Date().addingTimeInterval(-0.45)
                    voicedTime = 0.45
                    lastVoice = Date()
                    heard = "…"
                    return
                }
            }
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
            // Over speakers the recogniser mishears the reply's echo, so it takes three new words.
            if (fresh.count >= 3 && !isEcho(transcript)) || stopWord {
                interrupt(keeping: stopWord && fresh.count < 2 ? "" : transcript)
                return
            }
            feed()
            // Safety net: the reply is done but nothing has played for a long while. A part still being made
            // gets longer: a cloned voice takes up to 45 s per try, with a retry, one part after another.
            let waitingForAudio = playLoop != nil && (awaitingText != nil || !queue.isEmpty)
            if !store.isStreaming, playing == nil, Date().timeIntervalSince(lastProgress) > (waitingForAudio ? 200 : 60) {
                Self.log.notice("nothing played for a minute, listening again")
                silence()
                listen()
                return
            }
            // The play loop still runs while the next sentence's audio is being made.
            if !store.isStreaming, isCaughtUp, queue.isEmpty, playing == nil, playLoop == nil { listen() }
        case .paused, .starting:
            break
        }
    }

    /// Speech detected by loudness; after a pause the recording goes to Whisper.
    private func listenForWhisper() {
        let level = peak
        peak = 0
        guard !transcribing else { return }
        updateNoiseFloor(level)
        let threshold = max(Self.voiceLevel, noiseFloor * 5)
        if level > threshold {
            if speechStarted == nil {
                speechStarted = Date()
                voicedTime = 0
            }
            voicedTime += 0.15
            lastVoice = Date()
            // Only show that it's hearing someone once it's more than a noise.
            if voicedTime >= 0.45, heard.isEmpty {
                notice = nil
                heard = "…"
            }
        }
        guard let started = speechStarted, sendNow || Date().timeIntervalSince(lastVoice) > Self.pause || Date().timeIntervalSince(started) > 60 else {
            if speechStarted == nil { recording.keepLast(seconds: 1) }
            return
        }
        let (samples, rate) = recording.take()
        speechStarted = nil
        let tapped = sendNow
        sendNow = false
        // A cough or a click isn't a question; Whisper invents words for those.
        guard let api = store?.api, voicedTime >= 0.45 || tapped else {
            Self.log.notice("ignored \(self.voicedTime) s of sound (threshold \(threshold), noise \(self.noiseFloor))")
            heard = ""
            voicedTime = 0
            return
        }
        voicedTime = 0
        transcribing = true
        heard = "Transcribing…"
        let wav = Self.wav(Self.normalized(samples), sampleRate: rate)
        Self.log.notice("whisper recording \(samples.count) samples at \(rate) Hz, \(Double(samples.count) / rate) s, spoken for \(Date().timeIntervalSince(started)) s")
        let code = Locale(identifier: language).language.languageCode?.identifier
        Task {
            let text = (try? await api.transcribe(audio: wav, language: code, timeout: 30)) ?? ""
            transcribing = false
            Self.log.notice("whisper heard \(text.count) characters")
            guard running, phase == .listening else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                heard = ""
                notice = "Didn't catch that, please say it again."
                recording.reset()
            } else {
                submit(Self.joined(carried, text))
            }
        }
    }

    /// The lowest level that counts as a voice; the room's noise sets the real threshold above it.
    /// Headsets like AirPods suppress noise, so a voice there can be as quiet as 0.03.
    private static let voiceLevel: Float = 0.03

    /// The room's background level: the quieter fifth of the last six seconds, so a voice or a bang
    /// doesn't raise it and a single silent moment doesn't drop it.
    private func updateNoiseFloor(_ level: Float) {
        recentLevels.append(level)
        if recentLevels.count > 40 { recentLevels.removeFirst(recentLevels.count - 40) }
        let sorted = recentLevels.sorted()
        noiseFloor = sorted[sorted.count / 5]
    }
    private var noiseFloor: Float = 0.01
    /// How loud the reply itself sounds in the microphone while it plays (the median of the last seconds).
    private var echoLevel: Float = 0
    private var echoLevels: [Float] = []
    private var recentLevels: [Float] = []
    /// The loudest moment since the last check; single readings miss speech between syllables.
    private var peak: Float = 0
    /// Seconds of the current turn that were louder than the room.
    private var voicedTime = 0.0
    /// The user tapped to send what they said.
    private var sendNow = false
    /// Consecutive checks with a loud voice while the reply plays.
    private var bargeTicks = 0

    /// Louder, so quiet headset recordings don't reach Whisper as near-silence (which it answers with nothing).
    nonisolated static func normalized(_ samples: [Float], target: Float = 0.9) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0.0005 else { return samples }
        let gain = min(target / peak, 40)
        return samples.map { $0 * gain }
    }

    nonisolated static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian)
        append(UInt16(1).littleEndian); append(rate.littleEndian); append((rate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2).littleEndian)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32_767).littleEndian) }
        return data
    }

    private static let yesWords: Set<String> = ["yes", "yeah", "yep", "allow", "ok", "okay", "sure", "ja", "oui", "si", "sí"]
    private static let noWords: Set<String> = ["no", "nope", "deny", "don't", "nein", "non"]
    private static let stopWords: Set<String> = ["stop", "wait", "stopp", "warte", "halt", "arrête"]

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else { return }
        if isEcho(text) {
            Self.log.notice("ignored the reply's own echo")
            heard = ""
            newRequest()
            return
        }
        if store.isStreaming { store.stop() }
        carried = ""
        phase = .thinking
        lastProgress = Date()
        submittedAt = Date()
        generation += 1
        consumed = 0
        partsQueued = 0
        partPlaying = 0
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

    /// Sentences are queued but no audio has come back yet.
    @Published private(set) var waitingForVoice = false
    /// The reply is spoken in parts (each a separate request for server voices); shown so the pauses make sense.
    @Published private(set) var partsQueued = 0
    @Published private(set) var partPlaying = 0
    /// The reply has finished streaming, so the number of parts is final.
    var partsKnown: Bool { store?.isStreaming == false && isCaughtUp }

    /// "part 2 of 4", or "part 2" while the reply is still coming in; nil for a single part.
    func partText(_ part: Int) -> String? {
        guard partsQueued > 1 || !partsKnown else { return nil }
        return partsKnown ? "part \(part) of \(partsQueued)" : "part \(part)"
    }

    private var isCaughtUp: Bool { replyText.count <= consumed }

    /// Queues the next finished sentences of the streaming reply.
    private func feed() {
        guard let store else { return }
        let text = replyText
        if store.isStreaming { lastProgress = Date() }
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
        let cloned = speaker == .blablador && VoiceLibrary.shared.selected.isCloned
        let minimum = speaker == .device ? 1 : (queue.isEmpty && playing == nil ? 30 : cloned ? 220 : 90)
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
        let chosen = language.isEmpty ? nil : language
        let job: Task<[AVAudioPCMBuffer], Never>
        if speaker == .blablador, !device, let api = store?.api {
            let library = VoiceLibrary.shared
            let voice = library.selected
            let styled = library.styled(text)
            let timeout = Self.voiceTimeout
            if voice.isCloned {
                // Cloned voices: one request at a time (the server can't make several at once) and a retry;
                // only when Drama 3 fails both does the device's voice speak, with a notice.
                let previous = clonedChain
                let chain = Task<Data?, Never> {
                    _ = await previous?.value
                    for attempt in 1...2 {
                        let started = Date()
                        let result = await Self.withinTime(45, { () -> Result<Data, Error> in
                            do { return .success(try await api.speech(text: styled, voice: voice)) } catch { return .failure(error) }
                        })
                        if case let .success(data) = result {
                            Self.log.notice("cloned voice answered after \(Date().timeIntervalSince(started)) s")
                            return data
                        }
                        let reason: String
                        if case let .failure(error) = result { reason = error.localizedDescription } else { reason = "no answer in 45 s" }
                        Self.log.notice("cloned voice failed (attempt \(attempt)): \(reason, privacy: .public)")
                        if Task.isCancelled { return nil }
                    }
                    return nil
                }
                clonedChain = chain
                job = Task {
                    if let data = await chain.value, let buffers = try? Self.decode(data, to: format), !buffers.isEmpty {
                        return buffers
                    }
                    if Task.isCancelled { return [] }
                    // Better the device's voice than silence; the notice says why.
                    await MainActor.run { [weak self] in
                        self?.notice = "\(voice.name)'s voice isn't available right now (Drama 3 didn't answer), so the device's voice spoke."
                    }
                    return await Self.deviceSpeech(text, to: format, language: chosen)
                }
            } else {
                job = Task {
                    let started = Date()
                    // A built-in voice that is too slow for a conversation gives way to the device's voice for this sentence.
                    let data = await withTaskGroup(of: Data?.self) { group in
                        group.addTask { try? await api.speech(text: styled, voice: voice) }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
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
                    return await Self.deviceSpeech(text, to: format, language: chosen)
                }
            }
        } else {
            job = Task { await Self.deviceSpeech(text, to: format, language: chosen) }
        }
        Self.log.notice("speaking with \(self.speaker.rawValue, privacy: .public): \(text, privacy: .private)")
        if !device { partsQueued += 1 }
        queue.append(job)
        queueTexts.append(text)
        if playLoop == nil {
            let generation = generation
            playLoop = Task { await play(generation) }
        }
    }

    private func play(_ generation: Int) async {
        do {
            while !queue.isEmpty, self.generation == generation {
                let job = queue.removeFirst()
                awaitingText = queueTexts.isEmpty ? nil : queueTexts.removeFirst()
                let buffers = await job.value
                guard self.generation == generation else { break }
                awaitingText = nil
                Self.log.notice("playing \(buffers.count) buffers, \(buffers.reduce(0) { $0 + Int($1.frameLength) }) frames")
                guard !buffers.isEmpty else { continue }
                if !engine.isRunning {
                    try? engine.start()
                    player.play()
                }
                phase = .speaking
                let once = Once()
                playing = once
                partPlaying += 1
                lastProgress = Date()
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

    /// The voice changed mid-answer: the part playing finishes, the parts not yet spoken are made again
    /// with the new voice.
    func revoice() {
        guard running, phase == .thinking || phase == .speaking else { return }
        var texts = queueTexts
        if let awaitingText { texts.insert(awaitingText, at: 0) }
        guard !texts.isEmpty else { return }
        Self.log.notice("voice changed, redoing \(texts.count) parts")
        queue.forEach { $0.cancel() }
        queue = []
        queueTexts = []
        awaitingText = nil
        clonedChain?.cancel()
        clonedChain = nil
        // The old play loop ends after the part it is playing (or at once if it was still waiting);
        // the new one schedules after it, so nothing is cut off.
        generation += 1
        playLoop = nil
        partsQueued = max(0, partsQueued - texts.count)
        for text in texts { enqueue(text) }
    }

    /// Stops speaking and drops what was queued.
    private func silence() {
        generation += 1
        queue.forEach { $0.cancel() }
        queueTexts = []
        awaitingText = nil
        clonedChain?.cancel()
        clonedChain = nil
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
    static func deviceSpeech(_ text: String, to format: AVAudioFormat, language: String? = nil) async -> [AVAudioPCMBuffer] {
        // Without a voice for the language, the synthesizer may never finish.
        await withinTime(20) { await renderDeviceSpeech(text, to: format, language: language) } ?? []
    }

    /// The result of `work`, or nil when it takes longer than `seconds`.
    nonisolated static func withinTime<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func renderDeviceSpeech(_ text: String, to format: AVAudioFormat, language: String?) async -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechSynthesizer.voice(for: text, preferred: language)
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
        return output.frameLength > 0 ? [trimmed(output)] : []
    }

    /// Without the silence voices put before and after speech, so nothing seems to hang when a part starts.
    nonisolated static func trimmed(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.01) -> AVAudioPCMBuffer {
        guard let samples = buffer.floatChannelData?[0], buffer.format.channelCount == 1 else { return buffer }
        let count = Int(buffer.frameLength)
        guard let first = (0..<count).first(where: { abs(samples[$0]) > threshold }),
              let last = (0..<count).last(where: { abs(samples[$0]) > threshold }) else { return buffer }
        // Keep a short margin so words don't start or end abruptly.
        let margin = Int(buffer.format.sampleRate * 0.08)
        let start = max(0, first - margin)
        let end = min(count, last + margin)
        guard start > 0 || end < count,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(end - start)),
              let target = copy.floatChannelData?[0] else { return buffer }
        copy.frameLength = AVAudioFrameCount(end - start)
        target.update(from: samples + start, count: end - start)
        return copy
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
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<count { sum += samples[i] * samples[i] }
        } else if let samples = buffer.int16ChannelData?[0] {
            for i in 0..<count { let value = Float(samples[i]) / 32_768; sum += value * value }
        } else {
            return 0.01
        }
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

/// Microphone samples (mono) while the user may be speaking.
private final class RecordingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 48_000

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        lock.lock()
        rate = buffer.format.sampleRate
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        // At most two minutes.
        if samples.count > Int(rate * 120) { samples.removeFirst(samples.count - Int(rate * 120)) }
        lock.unlock()
    }

    /// Before speech starts, only the last moment is kept so the first word isn't cut.
    func keepLast(seconds: Double) {
        lock.lock()
        let keep = Int(rate * seconds)
        if samples.count > keep { samples.removeFirst(samples.count - keep) }
        lock.unlock()
    }

    func take() -> ([Float], Double) {
        lock.lock()
        defer { samples = []; lock.unlock() }
        return (samples, rate)
    }

    func reset() {
        lock.lock()
        samples = []
        lock.unlock()
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
    @State private var choosingLanguage = false

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
                        conversation.revoice()
                    }
                )) {
                    ForEach(voices.voices) { voice in
                        Text(voice.isCloned ? "\(voice.name) (cloned)" : voice.name).tag(voice.id)
                    }
                    Divider()
                    Text("Device voice (fast)").tag("device")
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white)
                .frame(maxWidth: 190)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
                .help("The voice that speaks the answers. Cloned voices are slower and are spoken in parts.")
                Button { choosingLanguage = true } label: {
                    Label(conversation.language.isEmpty ? "Automatic" : Locale.current.localizedString(forIdentifier: conversation.language) ?? conversation.language,
                          systemImage: "globe")
                        .scaledFont(.subheadline, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 150)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $choosingLanguage) {
                    NavigationStack {
                        LanguageList(selection: Binding(get: { conversation.language }, set: { conversation.language = $0 }))
                    }
#if os(macOS)
                    .frame(minWidth: 360, minHeight: 480)
#endif
                }
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
            // The circle gives way when the window is short, so the buttons stay inside it.
            GeometryReader { space in
                let scale = min(1, max(0.35, space.size.height / 260))
                orb(scale: store.commandApproval == nil ? scale : min(scale, 0.6))
                    .frame(width: space.size.width, height: space.size.height)
            }
            .frame(minHeight: 90, maxHeight: 260)
            .layoutPriority(-1)
            VStack(spacing: 10) {
                Text(status)
                    .scaledFont(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                Text(caption)
                    .scaledFont(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(maxWidth: 520, alignment: .top)
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

#if os(iOS)
            Text(conversation.diagnostics)
                .scaledFont(.caption2, design: .monospaced)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
#endif
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
        .frame(minWidth: 440, idealWidth: 480, minHeight: 400, idealHeight: 600)
#endif
    }

    private func orb(scale: CGFloat) -> some View {
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
        .scaleEffect(scale)
        .frame(width: 260 * scale, height: 260 * scale)
        .animation(.spring(duration: 0.4), value: scale)
        .contentShape(Circle())
        .onTapGesture { conversation.tap() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(status)
    }

    private var status: String {
        if let problem = conversation.audioProblem { return problem }
        if conversation.phase == .listening, conversation.heard.isEmpty, let notice = conversation.notice { return notice }
        return phaseStatus
    }

    private var interruptHint: String {
        conversation.canTalkOver ? "talk or tap to interrupt" : "tap to interrupt"
    }

    private var phaseStatus: String {
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
        case .thinking:
            if store.commandApproval != nil {
                "Blablador needs your OK"
            } else if conversation.waitingForVoice {
                "Preparing " + (conversation.partText(conversation.partPlaying + 1).map { $0 + " in " } ?? "") + "\(voices.selected.name)'s voice…"
            } else {
                replyStatus ?? "Thinking…"
            }
        case .speaking:
            if conversation.waitingForVoice, let next = conversation.partText(conversation.partPlaying + 1) {
                "Preparing \(next)…"
            } else if let part = conversation.partText(conversation.partPlaying) {
                "Speaking \(part) · \(interruptHint)"
            } else {
                "Speaking · \(interruptHint)"
            }
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

/// The languages speech recognition knows, searchable.
private struct LanguageList: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let languages = VoiceConversation.languages.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        List {
            if search.isEmpty {
                row("", "Automatic (the system's language)")
            }
            ForEach(languages, id: \.id) { row($0.id, $0.name) }
        }
        .searchable(text: $search, prompt: "Search languages")
        .navigationTitle("Language")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func row(_ id: String, _ name: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(Theme.gradient) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
