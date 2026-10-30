import SwiftUI

@main
struct BlabladorApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
#endif

    var body: some Scene {
        WindowGroup(id: "chat") {
            ChatWindow()
                .onOpenURL { SiriCommandCenter.shared.open($0) }
                // Links and opened files go to an open window instead of a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .modifier(ShareInboxPickup())
        }
        .commands {
            TextSizeCommands()
#if os(macOS)
            AppCommands()
#endif
        }
    }
}

/// Takes items from the share extension whenever the app comes to the front.
private struct ShareInboxPickup: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { SiriCommandCenter.shared.takeInbox() }
            .onChange(of: phase) { _, phase in
                if phase == .active { SiriCommandCenter.shared.takeInbox() }
            }
    }
}

/// View → Bigger Text (⌘+), Smaller Text (⌘−), Actual Size (⌘0).
private struct TextSizeCommands: Commands {
    @AppStorage(TextSize.key) private var step = 0

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Bigger Text") { step = min(step + 1, TextSize.range.upperBound) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(step >= TextSize.range.upperBound)
            Button("Smaller Text") { step = max(step - 1, TextSize.range.lowerBound) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(step <= TextSize.range.lowerBound)
            Button("Actual Size") { step = 0 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(step == 0)
            Divider()
        }
    }
}

/// One window (or tab) with its own open conversation; the chat history is shared.
private struct ChatWindow: View {
    @StateObject private var store = ChatStore()
    @AppStorage(TextSize.key) private var textSizeStep = 0

    var body: some View {
        ChatView()
            .environmentObject(store)
            .focusedSceneObject(store)
#if os(macOS)
            .environment(\.textScale, pow(1.1, CGFloat(textSizeStep)))
            .scaledFont(.body)
#else
            .dynamicTypeSize(TextSize.dynamicType(textSizeStep))
#endif
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

