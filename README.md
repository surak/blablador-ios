# Blablador apps

Native clients for [Helmholtz Blablador](https://helmholtz-blablador.fz-juelich.de), the OpenAI-compatible LLM service of
Forschungszentrum Jülich (`https://api.blablador.fz-juelich.de/v1`).

| Platform | Code | Download |
|---|---|---|
| macOS, iPhone, iPad (SwiftUI) | [`Blablador/`](Blablador) | [Latest release](https://github.com/surak/blablador-ios/releases/latest): `Blablador-<version>-macOS.dmg` |
| Android 8.0+ (Kotlin, Compose) | [`android/`](android) — see [android/README.md](android/README.md) | [Latest release](https://github.com/surak/blablador-ios/releases/latest): `Blablador-<version>-android.apk` |
| Windows, Linux, Raspberry Pi, Mac (Rust, egui) | [`desktop/`](desktop) — see [desktop/README.md](desktop/README.md) | [Latest release](https://github.com/surak/blablador-ios/releases/latest): `Blablador-<version>-windows-x86_64.zip`, `Blablador-<version>-linux-x86_64.tar.gz`, `Blablador-<version>-linux-arm64.tar.gz` (Raspberry Pi OS 64-bit), `Blablador-<version>-macos-arm64-desktop.tar.gz` |

The Android app has the same features as the Apple apps except agent mode, which is Mac only. The Windows/Linux app is a
smaller client: chat, thinking effort, web search, memory, attachments, knowledge bases and approved shell commands.

## Overview

Blablador is a SwiftUI app for macOS, iOS and iPadOS that chats with every Blablador model.

## Features

- **Chat**: Streaming replies from all Blablador chat models (default `deepseek-v4.1-flash-at-hzdr`), with Markdown formatting, code blocks and tables
- **Thinking**: for models that think before answering (DeepSeek, Qwen, GPT-OSS…), **Thinking…** above the reply shows the trace's latest line; tap it to read all of it. Choose the **thinking effort** (Off, Low, Medium, High, Max; Medium by default) per model in the model menu or Settings → Model. The app sends each model the setting it understands (`reasoning_effort`, chat template switches) and falls back, e.g. from Max to xhigh or High, when a model refuses one
- **Write while it answers**: send another message while a reply streams and it waits above the composer; **Steer** stops the reply and sends it now, the bin removes it, tapping it edits it. Queued messages are sent by themselves when the reply ends. Scroll up during a reply to read; scroll back to the end (or tap the arrow) to follow it again
- **`bla`, a coding agent on the command line** (Mac, Linux, Windows, Raspberry Pi), written in Rust: `bla "fix the failing test"`, `git diff | bla "write a commit message"`, or `bla` alone for a chat. It reads and edits files and runs commands, asking first; everything is a plugin (permissions, hooks, skills, memory, `/undo`, plugins in any language). Comes with the Mac app (Settings → Command line, or the Homebrew cask), and as a download for the other systems; `bla login` once. See [cli/README.md](cli/README.md)
- **Slow models**: Settings → Model → **Wait for a reply** sets how long to wait for a reply to start or continue (2, 5, 10 or 30 minutes, or no limit; default 10)
- **Voice**: On-device dictation and read-aloud
- **Web search**: Cited results from Blablador's search engine
- **Photos and camera**: Ask vision-capable models about pictures from Photos, the camera, or a file (**+ → File (image or PDF)…**). On the Mac and iPad, drag images and PDFs onto the chat to attach them. Paste a copied image with ⌘V on the Mac (screenshots, pictures, image files copied in Finder) or **+ → Paste image**
- **PDFs and OCR**: Attach PDFs with **+ → PDF**. Text is extracted on the device with PDFKit; scanned pages without a text layer are read with OCR. **+ → Text from photo** turns photos of documents into text. In Settings → Documents choose the OCR engine: on device (Apple Vision, private and offline) or Blablador's LightOnOCR (`alias-ocr`), which keeps tables and layout; if Blablador fails, the app falls back to on-device OCR. The text is sent to the model along with your question, so it works with every model.
- **Knowledge bases**: Collections of PDFs and text files that stay available, like Open WebUI's knowledge. Create them in Settings → Knowledge bases (or **+ → Knowledge → Manage knowledge…**) and switch them on per chat with the books button next to the model picker or **+ → Knowledge**, or type `#` and its name in the message; the books button can also create a new one. Text is extracted on the device (with OCR for scans), embedded with `alias-qwen3-4b-embeddings` and stored locally; for each question the best passages are found, re-ranked with `alias-qwen3-4b-reranker` and given to the model, which cites them as [K1], [K2]. Tap a citation to read the passage.
- **Agent mode (Mac)**: **+ → Agent: work in a folder…** turns a chat into a coding agent, like Claude Code or Codex. The model can list, read, search, create and edit files in that folder, and run shell commands there. File edits apply directly; every shell command waits for **Run**, **Allow for this chat** or **Deny**. Each tool call appears as a step under the reply (tap it for output or the diff). Works best with tool-calling models such as `alias-code` or DeepSeek-V4.1-Flash.
- **Decisions**: **+ → Decide…** runs the Clef decision model (`alias-clef`, `/v1/systemone`), which answers typed questions — yes/no, choice and score — with probabilities instead of text. Start a **New decision**: describe the situation (plain text or JSON), add questions, give choice questions their options and score questions their levels (lowest first), and save it under **My decisions**. Or start from one of the 73 examples from decision-model-frontend in 12 categories (routing, triage and safety, business, documents, science…), whose questions can be edited too.
- **Updates**: the app checks GitHub for a newer release. On the Mac, **Update** downloads it, checks it against `SHA256SUMS.txt`, replaces the app and restarts it (also **Blablador → Check for Updates…**); if the app's folder isn't writable it links to the download instead. iPhone and iPad show a notice with a link to the release.
- **Speech and voice cloning**: Turn on **+ → Speak** to have text spoken with Drama 3 (`alias-voice-drama3`), or ask the assistant to say something. Pick a feeling, pace and whisper in Settings → Voice, and add pauses, laughs, whispers and other expressions from the Expressions menu. Clone a voice with **Clone a voice…** in Settings → Voice or in the Speak chip's voice menu, from a recording, an audio or video file, or a direct link to one (10–30 seconds; YouTube pages are not supported). The sample is transcribed with Whisper.
- **Images**: Create images with FLUX.2-dev or Qwen-Image 2.1 (**+ → Create or edit image**). To edit, tap **Edit** on any image in the chat, or attach a photo and turn on image mode, then describe the change; editing uses Qwen-Image. You can also just ask the assistant to change the latest image.
- **Videos**: Make short videos with sound from a description with MiniMax-H3 (**+ → Create video**). Choose 4–10 seconds and landscape, portrait or square from the chip above the text field. A clip takes a few minutes; it plays in the chat and can be saved or shared. **Continue** on a video starts the next clip from its last frame; an image attached in video mode becomes the opening frame, and the clip takes its shape
- **History**: Searchable chats stored on the device; API key kept in the Keychain
- **Other endpoints**: Blablador by default; Settings can point the app at any OpenAI-compatible endpoint, with a button to go back to Blablador. API keys are Helmholtz Codebase personal access tokens with the `read_user` scope

## Requirements

- iOS and iPadOS 17.0+, macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

### Mac with Homebrew

```bash
brew install --cask surak/tap/blablador
```

Installs Blablador.app and the `bla` command line from the latest release ([surak/homebrew-tap](https://github.com/surak/homebrew-tap)). The app keeps updating itself; `brew upgrade` follows releases too.

### From source

1. Clone the repository
2. Open `Blablador/Blablador.xcodeproj` in Xcode
3. Select the My Mac (or an iPhone simulator) run destination
4. Build and run (⌘R)

The project is generated with xcodegen from `Blablador/project.yml`, so run `xcodegen` there after adding a source file.
Unit tests run without Xcode: `swift test` in the repository root builds the app's sources as `BlabladorCore` and tests them.

## Project Structure

```
Blablador/                    # an Xcode project: iOS, iPadOS and macOS
├── Blablador/                # the app, SwiftUI (AGENTS.md describes every file)
│   ├── BlabladorApp.swift    # App entry point, owns the ChatStore
│   ├── BlabladorAPI.swift    # /models and streaming /chat/completions client
│   ├── ChatStore.swift       # Conversations, persistence, sending/streaming
│   ├── ChatModels.swift      # Messages, conversations, models
│   ├── *View.swift           # SwiftUI views (chat, history, settings…)
│   ├── AgentTools.swift      # Agent mode: file and shell tools in a folder (Mac)
│   ├── KnowledgeBase.swift   # Knowledge bases: chunking, embeddings, retrieval
│   ├── Memory.swift, Recall.swift, Skills.swift, Goals.swift, Tasks.swift
│   ├── VoiceLibrary.swift, VoiceConversation.swift, SpeechRecognizer.swift
│   ├── DecisionView.swift, Proteins.swift, RoomMapper.swift
│   └── Info.plist            # App configuration
├── BlabladorShare/           # Share extension for iOS and macOS
└── Blablador.xcodeproj/      # Xcode project (project.yml for xcodegen)

android/                      # Kotlin, Jetpack Compose — same features, no agent mode
desktop/                      # Rust, egui — a smaller client
cli/                          # bla, the coding agent, in Rust
shared/                       # the model table bla and the desktop app read
docs/                         # the website
Tests/BlabladorTests/         # swift test from the repository root
Package.swift                 # builds the app's sources as BlabladorCore, without BlabladorApp.swift
```

## Architecture

The app is SwiftUI with MVVM-ish separation: an `ObservableObject` store holds the state and the work, views draw it.

- **BlabladorApp.swift** creates the `ChatStore` and the root `ChatView`, plus `Launcher`, which runs `bla` when the
  binary is started with `--cli`
- **ChatStore** owns conversations, persistence, the selected model, sending and streaming; a reply runs per conversation
  (`ChatStore.running`) and keeps going when the user switches chats. `runTurn` streams into the open message, records the
  tool calls as steps and the timings, tokens and model as a `Trace`
- **BlabladorAPI** talks to the OpenAI-compatible endpoint: `/models`, streaming `/chat/completions` with tools,
  `/embeddings`, `/rerank`, `/audio/speech`, `/videos/sync` and `/systemone`; helper calls (chat titles, memory
  learning) go to `helperModel`. The Room Mapper is a plain chat completion with a model that answers in commands and
  JSON (`visualGeometry`), the molecular jobs go through `POST /responses` (`Proteins.swift`)
- Views are `ChatView`, `MessageView`, `HistoryView`, `SettingsView` and the panels under the + button. `MarkdownText`
  draws a reply, and `RichContent` renders maths with KaTeX and Mermaid diagrams in a `WKWebView` fed by JavaScript;
  no web view wraps the chat itself
- Everything the app saves goes through `EncryptedStorage` (AES-GCM, key in the Keychain)

## Configuration

The endpoint and the models are constants in `BlabladorAPI.swift`: `defaultEndpoint` (Blablador), `defaultModel`
(`deepseek-v4.1-flash-at-hzdr`) and the aliases for the image, OCR, embedding, reranker and speech models. The endpoint
can be changed at runtime in Settings (UserDefaults `apiEndpoint`), and the API key is a Helmholtz Codebase token the
user enters, kept in the Keychain.

## Building

### Development Build

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk macosx -configuration Debug
```

### Release Build

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk iphoneos -configuration Release
```

### Mac installer (DMG)

```bash
xcodebuild -project Blablador/Blablador.xcodeproj -scheme Blablador -sdk macosx -configuration Release \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -derivedDataPath build/dd build
scripts/make-dmg.sh build/dd/Build/Products/Release/Blablador.app Blablador-macOS.dmg
```

`make-dmg.sh` draws the installer background (`scripts/dmg/background.swift`) and lays out the window with
[dmgbuild](https://github.com/dmgbuild/dmgbuild) (`scripts/dmg/settings.py`): app and Applications side by side with an
arrow, the first-launch command, and the app icon on the mounted volume. dmgbuild is installed into a temporary venv if missing.

## License

Copyright (c) 2025 Helmholtz-Zentrum Jülich
