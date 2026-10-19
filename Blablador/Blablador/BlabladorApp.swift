import SwiftUI

@main
struct BlabladorApp: App {
    @StateObject private var store = ChatStore()

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
