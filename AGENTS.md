# AI Agent Instructions

This file contains instructions for AI agents working on this iOS project.

## Project Overview

Blablador is a SwiftUI-based iOS application that wraps the Helmholtz Blablador web application in a native iOS experience. The app uses WKWebView to render the web content and provides navigation controls, refresh functionality, and URL sharing.

## Code Style Guidelines

- Follow Swift naming conventions (camelCase for variables/functions, PascalCase for types)
- Use SwiftUI best practices and declarative syntax
- Keep views focused on UI logic, business logic goes into ViewModel/Store classes
- Use `ObservableObject` and `@StateObject` for state management
- Prefer `disabled(!store.canGoBack)` over manually handling button states
- Use SwiftUI modifiers and view composition patterns

## File Structure

- `BlabladorApp.swift`: Main app entry point, contains the App struct and root scene configuration
- `WebView.swift`: WebView implementation with navigation controls and state management
- `Info.plist`: App configuration (display name, version info, etc.)

## Testing

Before making changes:
1. Build the project: `xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphonesimulator -configuration Debug`
2. Verify no compilation errors
3. Test on simulator if making UI changes

## Common Tasks

### Changing the Default URL

Edit `WebConstants.startURL` in `WebView.swift`:

```swift
private enum WebConstants {
    static let startURL = URL(string: "https://your-target-url.com")
}
```

### Adding New Toolbar Buttons

Modify the `ToolbarItemGroup` in `WebContainerView.swift`:

```swift
ToolbarItemGroup(placement: .bottomBar) {
    // existing buttons...
    Button(action: yourAction) {
        Image(systemName: "your.icon")
    }
}
```

### Modifying WebView Behavior

The `WKWebViewConfiguration` in `WebViewStore` init method can be customized to:
- Enable/disable JavaScript
- Set custom user agents
- Configure cookies
- Add message handlers

## Dependencies

- SwiftUI
- WebKit
- UIKit (for UIActivityViewController on iOS)

## Build Configuration

- **Minimum iOS Version**: iOS 17.0
- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI
- **Web Rendering**: WKWebView

## Notes

- The app uses a WebView wrapper approach rather than a fully native implementation
- Navigation gestures are enabled by default
- JavaScript is enabled for the web application
- The app uses iOS 17+ NavigationStack instead of NavigationView