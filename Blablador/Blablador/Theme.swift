import SwiftUI

enum Theme {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.27, green: 0.52, blue: 0.96), Color(red: 0.61, green: 0.42, blue: 0.93), Color(red: 0.85, green: 0.40, blue: 0.56)],
        startPoint: .leading,
        endPoint: .trailing
    )

#if os(iOS)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let background = Color(uiColor: .systemBackground)
#else
    static let surface = Color.primary.opacity(0.07)
    static let background = Color(nsColor: .windowBackgroundColor)
#endif
}

enum Clipboard {
    static func copy(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
    }
}
