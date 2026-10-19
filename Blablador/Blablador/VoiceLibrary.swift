import AVFoundation
import Foundation
import SwiftUI

/// A Drama 3 voice: a built-in Fish Audio voice, or one cloned from a short recording.
struct Voice: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Fish Audio voice ID for built-in voices.
    var referenceID: String?
    /// Reference recording in VoiceLibrary for cloned voices.
    var sampleFile: String?
    /// What is said in the reference recording; Drama 3 needs it to clone.
    var transcript = ""

    var isCloned: Bool { sampleFile != nil }
}

/// How Drama 3 should deliver the text: a direction in [brackets], pace and whisper tags.
enum SpeechEmotion: String, CaseIterable, Identifiable {
    case neutral, warm, happy, excited, calm, sad, angry, fearful, sarcastic, storyteller, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: "Neutral"
        case .warm: "Warm"
        case .happy: "Happy"
        case .excited: "Excited"
        case .calm: "Calm"
        case .sad: "Sad"
        case .angry: "Angry"
        case .fearful: "Fearful"
        case .sarcastic: "Sarcastic"
        case .storyteller: "Storyteller"
        case .custom: "Custom…"
        }
    }

    /// Plain-language direction placed before the text.
    var direction: String? {
        switch self {
        case .neutral, .custom: nil
        case .warm: "warm and friendly"
        case .happy: "cheerful, smiling"
        case .excited: "excited, energetic"
        case .calm: "calm and soothing"
        case .sad: "sad, close to tears"
        case .angry: "angry, barely restrained"
        case .fearful: "nervous and frightened"
        case .sarcastic: "dry and sarcastic"
        case .storyteller: "like a storyteller reading to children"
        }
    }
}

enum SpeechPace: String, CaseIterable, Identifiable {
    case slow, normal, fast
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Bracketed sounds and paired tags from the Drama 3 docs, offered in the composer.
enum SpeechMarkup {
    static let sounds = ["[pause]", "[long pause]", "[small laugh]", "[laughs]", "[sigh]", "[shaky breath]", "[deep breath]", "[gasps]", "[clears throat]", "[sniffs]"]
    static let tags: [(tag: String, title: String)] = [
        ("whisper", "Whisper"), ("soft", "Soft"), ("emphasis", "Emphasis"), ("stress", "Stress"),
        ("forceful", "Forceful"), ("slow", "Slow"), ("fast", "Fast")
    ]
    static let languages = ["german", "french", "spanish", "italian", "japanese", "chinese", "korean"]

    /// Tells the chat model how to write a script with these controls.
    static let guide = """
    Write the script with Drama 3 controls where they help: plain-language directions in square brackets before the words they affect \
    (e.g. [barely holding it together] I'm fine.), sounds and pauses in brackets at the exact position \
    (\(sounds.joined(separator: ", "))), and paired tags around words: \(tags.map { "<\($0.tag)>…</\($0.tag)>" }.joined(separator: ", ")). \
    Language switches: <german>…</german> etc. Don't overdo it.
    """
}

@MainActor
final class VoiceLibrary: ObservableObject {
    static let shared = VoiceLibrary()

    static let builtIn = [
        Voice(id: "bf322df2096a46f18c579d0baa36f41d", name: "Adrian", referenceID: "bf322df2096a46f18c579d0baa36f41d"),
        Voice(id: "c70cfb98867a4bfb9ae20d2401257b92", name: "Delia", referenceID: "c70cfb98867a4bfb9ae20d2401257b92"),
        Voice(id: "f3a2b90078d54a65af4b95f63bc7798e", name: "Sheila", referenceID: "f3a2b90078d54a65af4b95f63bc7798e")
    ]

    @Published private(set) var cloned: [Voice] = []

    @AppStorage("speechVoice") var selectedID: String = VoiceLibrary.builtIn[0].id {
        willSet { objectWillChange.send() }
    }
    @AppStorage("speechEmotion") var emotion: SpeechEmotion = .neutral {
        willSet { objectWillChange.send() }
    }
    @AppStorage("speechCustomDirection") var customDirection = "" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("speechPace") var pace: SpeechPace = .normal {
        willSet { objectWillChange.send() }
    }
    @AppStorage("speechWhisper") var whisper = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("speechToolsEnabled") var toolsEnabled = true {
        willSet { objectWillChange.send() }
    }

    var voices: [Voice] { Self.builtIn + cloned }
    var selected: Voice { voices.first { $0.id == selectedID } ?? Self.builtIn[0] }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let voices = try? JSONDecoder().decode([Voice].self, from: data) {
            cloned = voices
        }
    }

    /// Applies the delivery settings to a script.
    func styled(_ script: String) -> String {
        var text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if whisper { text = "<whisper>\(text)</whisper>" }
        if pace != .normal { text = "<\(pace.rawValue)>\(text)</\(pace.rawValue)>" }
        let direction = emotion == .custom ? customDirection.trimmingCharacters(in: .whitespacesAndNewlines) : emotion.direction ?? ""
        if !direction.isEmpty { text = "[\(direction)] " + text }
        return text
    }

    func add(name: String, sample: Data, transcript: String) {
        let file = UUID().uuidString + ".m4a"
        try? sample.write(to: Self.directory.appendingPathComponent(file), options: .atomic)
        let voice = Voice(name: name, sampleFile: file, transcript: transcript)
        cloned.append(voice)
        selectedID = voice.id
        persist()
    }

    func delete(_ voice: Voice) {
        if let file = voice.sampleFile { try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file)) }
        cloned.removeAll { $0.id == voice.id }
        if selectedID == voice.id { selectedID = Self.builtIn[0].id }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(cloned).write(to: Self.indexURL, options: .atomic)
    }

    nonisolated static func sampleData(for file: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(file))
    }

    nonisolated private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static var indexURL: URL { directory.appendingPathComponent("voices.json") }

    // MARK: - Reference samples

    /// Longest reference recording sent for cloning.
    static let maxSampleSeconds = 30.0

    /// Converts any audio or video file to an AAC sample of at most 30 seconds.
    static func prepareSample(from url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw SampleError.noAudio }
        let duration = try await asset.load(.duration)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw SampleError.noAudio }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        export.outputURL = output
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, CMTime(seconds: maxSampleSeconds, preferredTimescale: 600)))
        await export.export()
        if let error = export.error { throw error }
        return try Data(contentsOf: output)
    }

    /// 16-bit PCM WAV of a sample; Blablador's Whisper only decodes WAV and MP3.
    nonisolated static func wav(from sample: Data) throws -> Data {
        let temp = FileManager.default.temporaryDirectory
        let input = temp.appendingPathComponent(UUID().uuidString + ".m4a")
        let output = temp.appendingPathComponent(UUID().uuidString + ".wav")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try sample.write(to: input)
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let destination = try AVAudioFile(forWriting: output, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { throw SampleError.noAudio }
            while source.framePosition < source.length {
                try source.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try destination.write(from: buffer)
            }
        }
        return try Data(contentsOf: output)
    }

    enum SampleError: LocalizedError {
        case noAudio, youTube

        var errorDescription: String? {
            switch self {
            case .noAudio: "This file has no audio."
            case .youTube: "YouTube pages can't be downloaded. Save the audio as a file, or use a direct link to an audio or video file."
            }
        }
    }

    /// Downloads a direct link to an audio or video file.
    static func downloadSample(from url: URL) async throws -> Data {
        if let host = url.host?.lowercased(), host.contains("youtube.") || host.contains("youtu.be") {
            throw SampleError.youTube
        }
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: "")
        }
        // AVFoundation needs a file extension to recognise the format.
        let ext = url.pathExtension.isEmpty ? (response.suggestedFilename as NSString?)?.pathExtension ?? "mp4" : url.pathExtension
        let named = file.deletingPathExtension().appendingPathExtension(ext.isEmpty ? "mp4" : ext)
        try FileManager.default.moveItem(at: file, to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        return try await prepareSample(from: named)
    }
}

/// Generated speech, stored as files like ImageStore.
enum AudioStore {
    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    static func save(_ data: Data) -> String {
        let name = UUID().uuidString + ".mp3"
        try? data.write(to: url(for: name), options: .atomic)
        return name
    }

    static func delete(_ names: [String]) {
        for name in names { try? FileManager.default.removeItem(at: url(for: name)) }
    }
}

enum SpeechTools {
    static let generate: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_speech",
            "description": "Speak a script aloud with the user's chosen voice (Drama 3 text-to-speech). Use when the user asks you to say, read, narrate, perform or voice something. " + SpeechMarkup.guide,
            "parameters": [
                "type": "object",
                "properties": [
                    "script": ["type": "string", "description": "The exact words to speak, in the user's language, with optional Drama 3 controls."]
                ],
                "required": ["script"]
            ]
        ]
    ]
}

/// Records a voice sample from the microphone.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-sample.m4a")

    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
#endif
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings),
              recorder.record(forDuration: VoiceLibrary.maxSampleSeconds) else { return false }
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                if recorder.isRecording { self.elapsed = recorder.currentTime } else { _ = self.stop() }
            }
        }
        return true
    }

    /// Stops recording and returns the sample.
    func stop() -> Data? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        guard isRecording else { return nil }
        isRecording = false
        return try? Data(contentsOf: url)
    }
}

/// Plays one generated speech file at a time.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var playingName: String?
    private var player: AVAudioPlayer?

    func toggle(_ name: String) {
        if playingName == name {
            stop()
            return
        }
        stop()
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
#endif
        guard let player = try? AVAudioPlayer(contentsOf: AudioStore.url(for: name)) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playingName = name
    }

    func play(data: Data) {
        stop()
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingName = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingName = nil }
    }
}
