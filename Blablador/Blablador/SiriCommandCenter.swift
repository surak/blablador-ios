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

    /// Takes the waiting share, so only one window gets it once.
    func claimShare() -> Share? {
        defer { pendingShare = nil }
        return pendingShare
    }

    /// Picks up what the share extension left (everything shared since the app was last open goes into one chat).
    func takeInbox() {
        let items = ShareInbox.take()
        guard !items.isEmpty else { return }
        share(text: items.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), files: items.flatMap(\.files))
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
        case "inbox": takeInbox()
        case "ask": if !value("q").isEmpty { handle(command: value("q")) }
        case "new": share(text: [value("text"), value("url")].filter { !$0.isEmpty }.joined(separator: "\n"))
        default: break
        }
    }
}
