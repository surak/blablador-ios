# AI Agent Instructions

This file contains instructions for AI agents working on this iOS project.

## Project Overview

Blablador is a native SwiftUI chat client for the Helmholtz Blablador OpenAI-compatible API (`https://api.blablador.fz-juelich.de/v1`). It streams chat completions, supports on-device voice dictation, read-aloud, on-device PDF reading with OCR, Drama 3 speech with voice cloning, chat history and model selection (default `deepseek-v4.1-flash-at-hzdr`).

## Code Style Guidelines

- Follow Swift naming conventions (camelCase for variables/functions, PascalCase for types)
- Use SwiftUI best practices and declarative syntax
- Keep views focused on UI logic, business logic goes into ViewModel/Store classes
- Use `ObservableObject` and `@StateObject` for state management
- Prefer `disabled(!store.canGoBack)` over manually handling button states
- Use SwiftUI modifiers and view composition patterns

## File Structure

- `BlabladorApp.swift`: App entry point, owns the `ChatStore`
- `ChatModels.swift`: `ChatMessage`, `Conversation`, `RemoteModel`
- `BlabladorAPI.swift`: `/models` and streaming `/chat/completions` client
- `ChatStore.swift`: Conversations, persistence, model selection, sending/streaming
- `KeychainHelper.swift`: API key storage
- `PDFExtractor.swift`: PDF text extraction (PDFKit, Vision OCR for scanned pages)
- `VoiceLibrary.swift`, `VoiceViews.swift`: Drama 3 speech (`alias-voice-drama3` via `/audio/speech`), voice cloning (reference sample as `references[].audio_path` data URI plus transcript from Whisper), delivery settings
- `SpeechRecognizer.swift`: Dictation (Speech framework) and read-aloud (AVSpeechSynthesizer)
- `ChatView.swift`, `MessageView.swift`, `HistoryView.swift`, `SettingsView.swift`, `Theme.swift`: UI
- `SiriIntents.swift`, `SiriCommandCenter.swift`: "Ask Blablador" Siri shortcut, which starts a new chat
- `Info.plist`: App configuration, microphone/speech permission strings

## Testing

Before making changes:
1. Build the project: `xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphonesimulator -configuration Debug`
2. Verify no compilation errors
3. Test on simulator if making UI changes

## Common Tasks

- Change the default model: `BlabladorAPI.defaultModel` in `BlabladorAPI.swift`
- Change the API endpoint: `BlabladorAPI.baseURL`
- New Swift files must also be added to `Blablador.xcodeproj/project.pbxproj` (or regenerate with `xcodegen`)

## Dependencies

- SwiftUI
- Speech, AVFoundation
- Security (Keychain)

## Build Configuration

- **Minimum iOS Version**: iOS 17.0
- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI
- **Web Rendering**: WKWebView

## Notes

- The API key is entered by the user in Settings and stored in the Keychain; never hardcode it.
