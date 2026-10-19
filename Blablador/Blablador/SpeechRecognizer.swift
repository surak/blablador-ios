import AVFoundation
import Foundation
import Speech

/// Live on-device dictation using the system speech recognizer.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        Task {
            guard await Self.requestPermissions() else {
                errorMessage = "Allow microphone and speech recognition access in Settings to use voice input."
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                errorMessage = "Speech recognition is not available right now."
                return
            }
            do {
                try begin(with: recognizer)
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        isRecording = false
        audioLevel = 0
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        stop()
        transcript = ""

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.audioLevel = level }
        }

        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }

        audioEngine = engine
        self.request = request
        isRecording = true
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(count))
        return min(1, rms * 12)
    }

    private static func requestPermissions() async -> Bool {
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

/// Reads assistant replies aloud.
@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingID: UUID?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ message: ChatMessage) {
        if speakingID == message.id {
            synthesizer.stopSpeaking(at: .immediate)
            speakingID = nil
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message.content)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        speakingID = message.id
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }
}
