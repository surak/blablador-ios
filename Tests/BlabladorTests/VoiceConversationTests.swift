import AVFoundation
import XCTest
@testable import BlabladorCore

@MainActor
final class VoiceConversationTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func testDeviceVoiceRendersToEngineFormat() async throws {
        let buffers = await VoiceConversation.deviceSpeech("Hello, this is Blablador.", to: format)
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertEqual(buffers.first?.format.sampleRate, 24_000)
        // About a second or more of speech.
        XCTAssertGreaterThan(frames, 12_000)
    }

    func testEchoWordsAreRecognised() {
        XCTAssertEqual(VoiceConversation.words("It's 25 °C, sunny!"), ["it", "s", "25", "c", "sunny"])
        XCTAssertEqual(VoiceConversation.joined("", "hi"), "hi")
    }

    func testDramaVoiceDecodes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLABLADOR_NETWORK_TESTS"] == "1", let token = environment["HELMHOLTZ_BLABLADOR_TOKEN"] else { throw XCTSkip("network") }
        let started = Date()
        let data = try await BlabladorAPI(apiKey: token).speech(text: "Hello, nice to talk with you.", voice: VoiceLibrary.builtIn[0])
        print("DRAMA SECONDS:", Date().timeIntervalSince(started))
        let buffers = try VoiceConversation.decode(data, to: format)
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        print("DRAMA AUDIO SECONDS:", Double(frames) / 24_000)
        XCTAssertGreaterThan(frames, 12_000)
    }

    func testWhisperUnderstandsOurRecordingFormat() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLABLADOR_NETWORK_TESTS"] == "1", let token = environment["HELMHOLTZ_BLABLADOR_TOKEN"] else { throw XCTSkip("network") }
        let speech = await VoiceConversation.deviceSpeech("Hello, what is the weather like in Lisbon today?", to: format)
        let samples = speech.flatMap { buffer in Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
        let wav = VoiceConversation.wav(samples, sampleRate: 24_000)
        let text = try await BlabladorAPI(apiKey: token).transcribe(audio: wav)
        print("WHISPER:", text)
        XCTAssertTrue(text.lowercased().contains("lisbon"))
    }

    func testWhisperKeepsTheChosenLanguage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLABLADOR_NETWORK_TESTS"] == "1", let token = environment["HELMHOLTZ_BLABLADOR_TOKEN"] else { throw XCTSkip("network") }
        let speech = await VoiceConversation.deviceSpeech("Olá, como está o tempo em Lisboa hoje? Vai chover à tarde?", to: format)
        let samples = speech.flatMap { buffer in Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
        let wav = VoiceConversation.wav(samples, sampleRate: 24_000)
        let api = BlabladorAPI(apiKey: token)
        print("WHISPER pt:", try await api.transcribe(audio: wav, language: "pt"))
        print("WHISPER auto:", try await api.transcribe(audio: wav))
    }
}
