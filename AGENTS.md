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
- `KeychainHelper.swift`: API key storage; `EncryptedStorage` encrypts everything the app saves: chats, memories, images, audio, videos, voice samples, knowledge bases, saved decisions and custom instructions (AES-GCM, key in the Keychain; files from older versions are converted at launch). Players and share sheets get decrypted copies in a temporary folder (`decryptedCopy`), cleared at launch. `AppFolder.url` is where files live: Application Support on iOS, its own `Application Support/de.fz-juelich.blablador` folder on the unsandboxed Mac (`~/Library/Application Support/Knowledge` belongs to macOS). Android: `EncryptedStorage` in `data/Storage.kt` (Keystore, `EncryptedFile`, decrypted copies in `cacheDir/decrypted`), all excluded from backups; custom instructions in the encrypted preferences. Memory can't be changed in a reply that read web results, PDFs, knowledge bases or agent files (`outsideContent` in `runTurn`)
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
- `Memory.swift`: long-term memory (`MemoryStore`, `memories.json` in Application Support): `remember`/`forget` tools, numbered facts in every system prompt, `MemoryView` in Settings; replies record `ChatMessage.remembered`/`forgotten`. Android: `data/Memory.kt`, `ui/MemoryScreen.kt`. After each reply `MemoryStore.learn` asks the helper model which facts from the exchange to keep (Settings: Learn from every chat; only the user's text when the reply read outside content). `BlabladorAPI.helperModel` is `alias-fast` on Blablador (the chat's model on other endpoints), also used for chat titles (`nameChat`). `search_chats` (`ChatSearch`) searches earlier chats; over 30 memories only relevant ones are sent. Next steps in `ROADMAP.md`
- `WebSearch.swift` also has `WebPage` (`read_page` tool): fetches public http(s) pages and PDFs (no local or private addresses, checked again after redirects) and reduces HTML to readable text, 24,000 characters; counts as outside content
- Long chats: above about 120,000 characters `ChatStore.compact` has the helper model summarise all but the last 8 messages into `Conversation.summary`/`summaryCount`; `history()` sends the summary in the system prompt instead of those messages
- `MCP.swift`: MCP client (Streamable HTTP, JSON or SSE answers, `Mcp-Session-Id`), servers in Settings → Connected tools (encrypted `mcp.json`, optional bearer token). Tools appear as `<server>__<tool>`; calls wait for the user's OK in `CommandApprovalCard` unless the server's "Ask before each tool call" is off or the user chose Allow for this chat; shown as agent steps; outside content
- `RichContent.swift`: `WebBlock` (WKWebView, content pushed in with JavaScript) renders maths with KaTeX and Mermaid diagrams from jsDelivr; `ArtifactBlock` previews closed html/svg/mermaid fences; `CodeActions` copy and save code blocks
- `PythonRunner.swift`: `run_python` tool (Settings: Run Python code): Pyodide 0.26.4 from jsDelivr in a hidden WKWebView, `callAsyncJavaScript` runs the code with attached documents as text files in /data; stdout, last value and tracebacks go back to the model, matplotlib figures (MPLBACKEND=AGG) are saved as reply images; 3-minute timeout resets the web view; shown as a "Ran Python" step
- Data files (CSV, Excel, JSON…, `DataFiles` in `PythonRunner.swift`): attached as a `DocumentAttachment` with `dataFile` (encrypted original in `DataFiles/`, `text` describes it with the first 40 lines); Python gets the real bytes in /data; Excel via openpyxl installed with micropip on demand
- Versions: editing a message (`ChatStore.edit`) or regenerating keeps the old tail in `ChatMessage.alternatives` with `version` numbers; `showVersion` switches (`ChatStore.messages(_:showingVersion:at:)`); `Conversation.allMessages` covers every version when deleting files
- `Recall.swift`: smarter recall with `alias-qwen3-4b-embeddings` (Blablador endpoint only, `Embeddings.available`), vectors cut to 512 dimensions and normalised. Memories store `vector`, `sourceChat`, `sourceTitle`; over 30 memories `MemoryStore.systemPrompt(for:api:)` sends those within 0.2 of the best match (at least 0.5; unrelated texts score 0.3–0.5) plus keyword matches and the 10 newest. `ChatIndex` keeps message vectors (encrypted `chat-index.json`), updated after each reply, 256 messages per update; `ChatSearch.find` ranks by meaning and keywords, then `/rerank`. Memories also have `entities` (named people, projects, tools…, lowercased): `learn` asks for `{"fact", "about"}` objects, `linkMissing` names them for older or hand-written memories, and `MemoryStore.linked` adds memories up to two shared entities away from the relevant ones (entities on more than a tenth of the memories are ignored). Everything falls back to keywords without embeddings
- `Skills.swift`: skills (`SkillLibrary`, encrypted `skills.json`): names and descriptions in the system prompt, `use_skill` loads instructions, `suggest_skill` shows a card the user saves; Settings → Skills with import/share as Markdown with front matter. Android: `data/Skills.kt`, `ui/SkillsScreen.kt`
- `SiriIntents.swift`, `SiriCommandCenter.swift`: Shortcuts actions: Tell Blablador (opens a new chat), Ask Blablador (answers without opening the app and returns the text, optionally about a file or the page a link points to; saved as a chat), Run Blablador Skill, Add to Blablador Memory. `SiriCommandCenter.open` handles opened files (document types in Info.plist) and blablador://ask?q=…, blablador://new?text=…, blablador://inbox
- `BlabladorShare/`: share extension (iOS and macOS) for web pages, text, photos and files; writes to the App Group inbox (`ShareInbox`, group.de.fz-juelich.blablador on iOS, 4Q84Z7RZ3Z.de.fz-juelich.blablador on macOS) and the app picks it up when it comes to the front, in the key window. The Mac extension opens the app; on iOS the user opens it
- `Permissions.swift`: `ToolPermissions` (Allow/Ask/Never per kind of tool, UserDefaults `toolPermissions`; connected servers are `mcp:<id>`, their Allow/Ask is the server's `askBeforeCalls`; Never hides the tools) and `PermissionsView`. `ChatStore.authorize` checks the rule, "Allow for this chat" (`chatAllowed`) or queues a `CommandApproval` (per chat, `approvals`); the card offers Allow, Allow for this chat and Always allow
- `Planning.swift`: `update_plan` (`PlanTools`, `ChatMessage.plan`, `PlanCard`; 8 tool rounds, 25 with a plan), `Trace`/`TraceCall` on replies (model, seconds, rounds, tokens from `stream_options.include_usage` on Blablador, every tool call; `TraceLine` and `TraceView` with Run again via `ChatStore.rerun`), `Mention` (@ in the composer, kept on the user message; `ChatStore.mentionPrompt` adds them to that turn, mentioned tools are on for it), `SkillDrafter` (after 3+ successful tool calls the helper model drafts a skill from the request, tool names and arguments; Settings → Skills → Suggest skills after tasks)
- `Tasks.swift`: scheduled tasks (`ScheduledTask`, `TaskScheduler`, encrypted `tasks.json`, `schedule_task` tool, `TasksView`); due tasks run in a new chat via `ChatStore.runTask` while the app is open (30 s timer, and when it becomes active); local notifications at each time on iOS. `Notifier` posts a notification when a reply finishes while the user isn't watching or an approval waits; tapping opens blablador://chat?id=…
- Replies run per chat (`ChatStore.running`, `start`), keep going when the user switches chats; `isStreaming` is the open chat, `isBusy` any. iOS asks for background time per reply
- `DeviceTools.swift`: calendar, reminders (EventKit), contacts and location tools (Settings: Calendar, reminders, contacts and location; off by default); reads count as outside content, creating events/reminders and location ask first. Mac entitlements `personal-information.calendars/addressbook/location`
- `ToolsPanel.swift`: the + button's panel (attach, reply mode, tool switches, knowledge, connected tools, skills, scheduled tasks, permissions, folder, decide) and the @ mention list (`MentionCatalog`, `MentionSuggestions`, `MentionChips`)
- `Info.plist`: App configuration, microphone/speech permission strings

## Testing

- Unit tests: `swift test` at the repository root (Package.swift builds the app's sources, except `BlabladorApp.swift`, as `BlabladorCore`; tests in `Tests/BlabladorTests`, using their own Keychain service and a fake server for MCP and streaming). `BLABLADOR_NETWORK_TESTS=1 swift test --filter PythonTests` also runs real Pyodide. Android: `cd android && ./gradlew :app:testDebugUnitTest`.
- Keep app types the tests need out of `BlabladorApp.swift`.

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
