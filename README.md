# Blablador iOS App

A native iOS application that provides a simple web view wrapper for the Helmholtz Blablador web application.

## Overview

Blablador is a SwiftUI-based iOS app that provides an enhanced mobile experience for accessing the Blablador platform. It features a full-screen web view with navigation controls and sharing capabilities.

## Features

- **Full-Screen Web View**: Native rendering of the Blablador web application
- **Navigation Controls**: Back and forward navigation with gesture support
- **Refresh**: Easy access to reload the current page
- **Share**: Share current URLs with other apps
- **Bottom Toolbar**: Intuitive navigation controls for easy access

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

1. Clone the repository
2. Open `Blablador/Blablador.xcodeproj` in Xcode
3. Select your target device (iPhone/iPad simulator or physical device)
4. Build and run (⌘R)

## Project Structure

```
Blablador/
├── Blablador/
│   ├── BlabladorApp.swift    # App entry point
│   ├── WebView.swift          # WebView implementation with navigation
│   └── Info.plist            # App configuration
└── Blablador.xcodeproj/      # Xcode project files
```

## Architecture

The app uses SwiftUI with a MVVM-inspired approach:

- **BlabladorApp.swift**: The main app entry point that configures the root view
- **WebView.swift**: Contains three main components:
  - `WebViewStore`: ObservableObject that manages WKWebView state and navigation
  - `WebView`: UIViewRepresentable wrapper for WKWebView
  - `WebContainerView`: Main view with toolbar and navigation controls

## Configuration

The default URL is configured in `WebView.swift`:

```swift
private enum WebConstants {
    static let startURL = URL(string: "https://staging.helmholtz-blablador.fz-juelich.de")
}
```

To change the target URL, modify the `startURL` value to point to your desired environment.

## Building

### Development Build

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphonesimulator -configuration Debug
```

### Release Build

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphoneos -configuration Release
```

## License

Copyright (c) 2025 Helmholtz-Zentrum Jülich