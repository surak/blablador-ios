import SwiftUI

@main
struct BlabladorApp: App {
    @StateObject private var store = ChatStore()
#if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
#endif

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(store)
#if os(macOS)
                .frame(minWidth: 700, minHeight: 600)
#endif
        }
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    /// ⌘C doesn't reach SwiftUI's selectable Text, although Edit → Copy does.
    /// Send the shortcut down the same responder chain as the menu item.
    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "c" else { return event }
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) ? nil : event
        }
    }
}
#endif
