# AI Agent Instructions

This file contains instructions for AI agents working on this iOS project.

## Project Overview

Blablador is a native SwiftUI chat client for the Helmholtz Blablador OpenAI-compatible API (`https://api.blablador.fz-juelich.de/v1`). It streams chat completions, supports on-device voice dictation, read-aloud, on-device PDF reading with OCR, knowledge bases (RAG), Drama 3 speech with voice cloning, chat history and model selection (default `deepseek-v4.1-flash-at-hzdr`).

## Android

The Android app lives in `android/` (Kotlin, Jetpack Compose); see `android/README.md` for building and its structure.
Keep features in sync between the two apps. Both apps share one version number (`MARKETING_VERSION` in the Xcode
project, `versionName` in `android/app/build.gradle.kts`; bump `versionCode` and `CURRENT_PROJECT_VERSION` too) and one
release tagged `v<version>` with the Mac DMG and zip, the Android APK and `SHA256SUMS.txt`.

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
- `KeychainHelper.swift`: API key storage; `EncryptedStorage` encrypts chat history and memories (AES-GCM, key in the Keychain; plain files from older versions are converted). Android: `EncryptedStorage` in `data/Storage.kt` (Keystore, `EncryptedFile`), excluded from backups
- `PDFExtractor.swift`: PDF and photo text extraction (PDFKit; OCR with Vision or Blablador's `alias-ocr` LightOnOCR, chosen in Settings, HTML tables converted to Markdown)
- `AgentTools.swift`, `AgentViews.swift`: agent mode (macOS). Tools list/read/search/write/edit files confined to `Conversation.workspace` (paths resolved through symlinks) and `run_command` via `zsh -lc` after the user approves (`ChatStore.commandApproval`); up to `AgentTools.maxRounds` tool rounds, steps stored in `ChatMessage.steps`
- `AppUpdater.swift`: checks `api.github.com/repos/surak/blablador-ios/releases/latest`; on macOS downloads `Blablador-<version>-macOS.zip`, verifies it against `SHA256SUMS.txt`, the exact asset name and checksum line, the bundle id, a newer version and a signature from the same Apple developer team as the running app (`verifySignature`), then swaps the bundle after quitting and relaunches. iOS shows `UpdateBanner` with a link. Releases must keep these asset names
- `DecisionView.swift`, `DecisionExamples.swift`: Clef decision model (`alias-clef`, `POST /v1/systemone`, question types noul/choice/score; the user writes their own decisions and questions, saved in UserDefaults by `SavedDecisions`). `DecisionExamples.swift` is generated from `../decision-model-frontend/static/app.js` PRESETS with `node scripts/generate-decision-examples.js ../decision-model-frontend/static/app.js`; regenerate rather than edit
- Video mode (`ChatStore.makeVideo`, `BlabladorAPI.generateVideo`): `alias-video` (MiniMax-H3) via multipart `POST /v1/videos/sync` with `prompt`, `aspect_ratio`, `width`/`height` and `extra_params={"duration":n}`; returns an MP4 with sound, stored in `VideoStore`, shown by `VideoClip` (AVPlayerView/AVPlayerViewController; SwiftUI `VideoPlayer` crashes). An attached image is uploaded as `first_frame` (then no aspect/size is sent); **Continue** puts `VideoStore.lastFrame` into the composer
- `KnowledgeBase.swift`, `KnowledgeViews.swift`: knowledge bases (RAG) — chunks and normalized vectors stored per base on device, `/embeddings` with `alias-qwen3-4b-embeddings`, `/rerank` with `alias-qwen3-4b-reranker`, excerpts injected into the system prompt as [K1]…
- `VoiceLibrary.swift`, `VoiceViews.swift`: Drama 3 speech (`alias-voice-drama3` via `/audio/speech`), voice cloning (reference sample as `references[].audio_path` data URI plus transcript from Whisper), delivery settings
- `SpeechRecognizer.swift`: Dictation (Speech framework) and read-aloud (AVSpeechSynthesizer)
- `ChatView.swift`, `MessageView.swift`, `HistoryView.swift`, `SettingsView.swift`, `Theme.swift`: UI
- `WebSearch.swift`: `web_search` and `image_search` tools on Blablador's SearXNG (`search.blablador.fz-juelich.de`, `categories=images`); found pictures (HTTPS only) are stored in `ChatMessage.webImages` and shown above the answer by `WebImagesView`. `WebSearch.systemPrompt` tells the model to search before saying it doesn't know a person. Android: `WebSearch` in `data/Tools.kt`
- `Memory.swift`: long-term memory (`MemoryStore`, `memories.json` in Application Support): `remember`/`forget` tools, numbered facts in every system prompt, `MemoryView` in Settings; replies record `ChatMessage.remembered`/`forgotten`. Android: `data/Memory.kt`, `ui/MemoryScreen.kt`. Next steps in `ROADMAP.md`
- `SiriIntents.swift`, `SiriCommandCenter.swift`: "Ask Blablador" Siri shortcut, which starts a new chat
- `Info.plist`: App configuration, microphone/speech permission strings

## Testing

Before making changes:
1. Build the project: `xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphonesimulator -configuration Debug`
2. Verify no compilation errors
3. Test on simulator if making UI changes

## Common Tasks

- Change the default model: `BlabladorAPI.defaultModel` in `BlabladorAPI.swift`
- The API endpoint: `BlabladorAPI.endpoint` (UserDefaults `apiEndpoint`, set in Settings; `defaultEndpoint` is Blablador). Android: `BlabladorApi.endpoint`, saved by `Settings.endpoint`
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
