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

/// Text size chosen with ⌘+ / ⌘− / ⌘0, as steps away from the normal size.
enum TextSize {
    static let key = "textSizeStep"
    static let range = -3...6

#if os(iOS)
    /// iOS scales text through Dynamic Type.
    static func dynamicType(_ step: Int) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        let index = sizes.firstIndex(of: .large)! + step
        return sizes[min(max(index, 0), sizes.count - 1)]
    }
#endif
}

private struct TextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// Text scale on the Mac, where SwiftUI ignores Dynamic Type.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// A text style that follows the chosen text size on every platform.
private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    var weight: Font.Weight?
    var design: Font.Design?

    func body(content: Content) -> some View {
#if os(macOS)
        content.font(.system(size: Self.macSize(style) * scale,
                             weight: weight ?? (style == .headline ? .bold : .regular), design: design ?? .default))
#else
        content.font(.system(style, design: design, weight: weight))
#endif
    }

    /// macOS point sizes of the text styles.
    private static func macSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }
}

extension View {
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }
}
