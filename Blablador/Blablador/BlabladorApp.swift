import SwiftUI

@main
struct BlabladorApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
#endif

    var body: some Scene {
        WindowGroup(id: "chat") {
            ChatWindow()
        }
#if os(macOS)
        .commands { AppCommands() }
#endif
    }
}

/// One window (or tab) with its own open conversation; the chat history is shared.
private struct ChatWindow: View {
    @StateObject private var store = ChatStore()

    var body: some View {
        ChatView()
            .environmentObject(store)
            .focusedSceneObject(store)
#if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
#endif
    }
}

#if os(macOS)
private struct AppCommands: Commands {
    @FocusedObject private var store: ChatStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await AppUpdater.shared.check(force: true) } }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { store?.settingsRequested = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(store == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                // Opened windows join the current one as tabs unless tabbing is briefly off.
                NSWindow.allowsAutomaticWindowTabbing = false
                openWindow(id: "chat")
                DispatchQueue.main.async { NSWindow.allowsAutomaticWindowTabbing = true }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { openWindow(id: "chat") }
                .keyboardShortcut("t", modifiers: .command)
        }
    }
}
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    /// ⌘C doesn't reach SwiftUI's selectable Text, although Edit → Copy does.
    /// Send the shortcut down the same responder chain as the menu item.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // New windows join the current window as tabs.
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        NSWindow.allowsAutomaticWindowTabbing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘V with an image (or image/PDF files) on the clipboard attaches it instead of pasting text.
            if flags == .command, event.charactersIgnoringModifiers == "v", PasteRequest.clipboardHasAttachment {
                let request = PasteRequest()
                NotificationCenter.default.post(name: .pasteAttachment, object: request)
                if request.handled { return nil }
            }
            guard flags == .command, event.charactersIgnoringModifiers == "c" else { return event }
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) ? nil : event
        }
    }
}
#endif

#if os(macOS)
extension Notification.Name {
    /// Asks the key window's composer to attach what's on the clipboard.
    static let pasteAttachment = Notification.Name("pasteAttachment")
}

/// Lets the composer report that it took the paste, so the text field doesn't paste too.
final class PasteRequest {
    var handled = false

    /// An image without text (a screenshot, a copied picture), or copied image/PDF files from Finder.
    static var clipboardHasAttachment: Bool {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.contains(where: { ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp", "bmp", "pdf"].contains($0.pathExtension.lowercased()) }) {
            return true
        }
        let types = board.types ?? []
        return !types.contains(.string) && NSImage.canInit(with: board)
    }
}
#endif
