import Combine
import Foundation

@MainActor
final class SiriCommandCenter: ObservableObject {
    static let shared = SiriCommandCenter()

    @Published private(set) var pendingCommand: String?
    /// Files and text handed to the app ("Open in Blablador", the share extension, blablador:// links), for a new
    /// chat's composer.
    @Published private(set) var pendingShare: Share?

    struct Share: Equatable {
        var text = ""
        var files: [URL] = []
    }

    private init() {}

    func handle(command: String) {
        pendingCommand = command
    }

    func consumePendingCommand() {
        pendingCommand = nil
    }

    func share(text: String = "", files: [URL] = []) {
        guard !text.isEmpty || !files.isEmpty else { return }
        pendingShare = Share(text: text, files: files)
    }

    func consumeShare() {
        pendingShare = nil
    }

    /// Opened files, and links: blablador://ask?q=… sends a question, blablador://new?text=… fills a new chat.
    func open(_ url: URL) {
        if url.isFileURL {
            share(files: [url])
            return
        }
        guard url.scheme == "blablador", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value ?? "" }
        switch url.host() {
        case "ask": if !value("q").isEmpty { handle(command: value("q")) }
        case "new": share(text: [value("text"), value("url")].filter { !$0.isEmpty }.joined(separator: "\n"))
        default: break
        }
    }
}
