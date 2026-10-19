# Blablador macOS App

A native macOS/iOS/iPadOS application that provides a simple web view wrapper for the Helmholtz Blablador web application.

## Overview

Blablador is a SwiftUI-based macOS/iOS/iPadOS app that provides an enhanced mobile experience for accessing the Blablador platform. It features a full-screen web view with navigation controls and sharing capabilities.

## Features

- **Chat**: Streaming replies from all Blablador chat models (default `deepseek-v4.1-flash-at-hzdr`)
- **Voice**: On-device dictation and read-aloud
- **Web search**: Cited results from Blablador's search engine
- **Photos and camera**: Ask vision-capable models about pictures
- **PDFs**: Attach PDFs with **+ → PDF**. Text is extracted on the device with PDFKit; scanned pages without a text layer are read with Apple's Vision OCR. The text is sent to the model along with your question, so it works with every model.
- **Images**: Create images with FLUX.2-dev or Qwen-Image 2.1, edit them with Qwen-Image
- **History**: Searchable chats stored on the device; API key kept in the Keychain

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

1. Clone the repository
2. Open `Blablador/Blablador.xcodeproj` in Xcode
3. Select the My Mac run destination
4. Build and run (⌘R)

## Project Structure

```
Blablador/
├── Blablador/
│   ├── BlabladorApp.swift     # App entry point
│   ├── BlabladorAPI.swift     # /models and streaming /chat/completions client
│   ├── ChatStore.swift        # Conversations, persistence, sending/streaming
│   ├── ChatModels.swift       # Messages, conversations, models
│   ├── PDFExtractor.swift     # PDF text extraction (PDFKit + Vision OCR)
│   ├── SpeechRecognizer.swift # Dictation and read-aloud
│   ├── *View.swift            # SwiftUI views
│   └── Info.plist             # App configuration
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
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk macosx -configuration Debug
```

### Release Build

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphoneos -configuration Release
```

## License

Copyright (c) 2025 Helmholtz-Zentrum Jülich
