# Blablador for Android

Native Android client for [Helmholtz Blablador](https://helmholtz-blablador.fz-juelich.de), the OpenAI-compatible
LLM service of Forschungszentrum Jülich (`https://api.blablador.fz-juelich.de/v1`). Kotlin, Jetpack Compose and Material 3.
It is the Android counterpart of [blablador-ios](https://github.com/surak/blablador-ios) (Mac, iPhone and iPad).

## Features

- **Chat** with every Blablador chat model, streaming replies; default `deepseek-v4.1-flash-at-hzdr`. Markdown with code blocks and tables
- **Thinking**: the thinking trace of reasoning models shows in a collapsible panel above the reply
- **Wait for a reply** (Settings): how long to wait for slow models, up to no limit
- **Web search** through search.blablador.fz-juelich.de, with cited sources and pictures next to the answer; reads web pages and online PDFs in full
- **Photos, camera and files** for vision-capable models (+ → File picks images or PDFs; + → Paste image attaches a copied image)
- **PDFs** (+ → PDF): text extracted on the device with PdfBox; scanned pages read with OCR
- **Text from photo** (+ → Text from photo): OCR of documents, receipts or slides
- **OCR engine** in Settings → Documents: on device (ML Kit) or Blablador's LightOnOCR (`alias-ocr`), which keeps tables; falls back to on-device
- **Create and edit images** with FLUX.2-dev or Qwen-Image 2.1; tap **Edit** on any image in the chat
- **Dictation** (system speech recognizer) and **read-aloud** (system text-to-speech)
- **Memory**: facts about you saved across chats, editable in Settings; searches earlier chats when you refer to them
- **Python**: the assistant runs Python on the device (Pyodide: numpy, pandas, matplotlib) for calculations, data and plots shown in the reply
- **Share to Blablador**: links, text, photos, PDFs and data files from any app's share menu, "Open with" Blablador, blablador:// links, and app-icon shortcuts (Ask Blablador, Add to memory)
- **Skills**: instructions for tasks you repeat, loaded when a task matches; import and share as Markdown
- **Connected tools (MCP)**: add MCP servers over HTTPS and the assistant uses their tools, each call approved by you
- **Long chats** are summarised with alias-fast once they get long, so they keep working
- **Maths, diagrams and previews**: LaTeX with KaTeX, Mermaid diagrams, live HTML/SVG previews; save code blocks as files
- **History** with search; personalised greeting; API key stored encrypted with the Android Keystore
- **Knowledge bases** (+ → Knowledge): collections of PDFs and text files indexed with `alias-qwen3-4b-embeddings` and re-ranked with
  `alias-qwen3-4b-reranker`; the index stays on the device and replies cite excerpts as [K1], [K2]
- **Speech with Drama 3** (+ → Speak): built-in voices, feelings, pace, whisper and an Expressions menu for pauses, laughs and tags;
  the assistant can also speak with the `generate_speech` tool
- **Voice cloning**: record a sample, pick an audio or video file, or fetch a link; Whisper transcribes it for Drama 3
- **Decide** (+ → Decide): the Clef decision model (`alias-clef`); write your own decisions and questions (yes/no, choice, score) and save them, or start from 73 examples; answers with probabilities
- **Update notice**: when GitHub has a newer release, a banner above the chat links to the new APK

Agent mode is Mac only on iOS and isn't ported.

The decision examples in `app/src/main/assets/decision-examples.json` are generated from decision-model-frontend; regenerate with
`node scripts/generate-decision-examples.js ../decision-model-frontend/static/app.js` rather than editing them.

## Using the new features

### Knowledge bases
1. **+ → Knowledge → New knowledge base…** (or Settings → Knowledge and decisions → Knowledge bases) and name it.
2. Open it and **Add documents**: PDFs and text files. Each is split into ~1200-character passages (200 overlap),
   embedded in batches with `alias-qwen3-4b-embeddings` (falls back to `alias-embeddings`) and stored on the device
   under `files/knowledge/<id>/` as `chunks.json` and `vectors.bin` (normalized little-endian floats).
3. Switch a base on for a chat in **+ → Knowledge**; active bases show above the message field.
4. Each question finds the 24 closest passages, `alias-qwen3-4b-reranker` keeps the best 6, and they go into the
   system prompt as [K1]…[K6]. Tap a citation under the reply to read the passage.

### Speech and voices (Drama 3)
- **+ → Speak (Drama 3)** turns the next messages into speech with `alias-voice-drama3` (`/audio/speech`); the clip plays
  in the chat and can be shared. The **Expressions** menu inserts pauses, laughs, whispers and other tags.
- Settings → Voice: voice (Adrian, Delia, Sheila or your own), feeling, pace, whisper, and whether the assistant may
  speak by itself with the `generate_speech` tool.
- **Clone a voice…**: record with the microphone, pick an audio/video file or give a direct link (YouTube pages are not
  supported). The sample is converted to 16 kHz mono WAV, transcribed with `faster-whisper-large-v3` (you can correct
  the text) and sent as `references[].audio_path` plus the transcript.
- Keep samples short (about 5 s). The server's time grows with the sample length, and samples longer than about 10 s
  currently exceed the gateway timeout and fail with 502. Samples at 44.1 kHz also fail, which is why the app converts
  everything to 16 kHz.

### Decisions (Clef)
**+ → Decide (Clef)** opens the decision screen. Tap the decision name and choose **New decision**, a saved one
under **My decisions**, or one of 73 examples in 12 categories. Describe the situation (plain text or JSON), then
**Add question**: yes/no, a choice between options, or a score on levels from lowest to highest. Tap a question to edit
it. **Save as my decision** keeps it on the phone. It calls `POST /v1/systemone` with `alias-clef` and shows each answer with
probabilities.

## Permissions
- Internet
- Camera (photos), microphone (dictation and voice samples); both are asked for when first used

## Installing the APK
Download `Blablador-<version>-android.apk` from the
[releases](https://github.com/surak/blablador-ios/releases), open it on the phone and allow installing from that
source. It is signed with a development key, so installing a later build from another source may require
uninstalling first.

## Requirements

- Android 8.0 (API 26) or later
- A Blablador API key: a Helmholtz Codebase personal access token with the `read_user` scope (https://codebase.helmholtz.cloud/-/user_settings/personal_access_tokens/legacy/new)

## Building

Needs JDK 17 and the Android SDK (platform 35, build tools 35).

```bash
brew install openjdk@17 && brew install --cask android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"
echo "sdk.dir=$ANDROID_HOME" > local.properties

./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug         # onto a connected device or emulator
./gradlew testDebugUnitTest    # unit tests (skills, memory, chat search, web pages, maths, history, MCP, streaming)
./gradlew assembleRelease      # app/build/outputs/apk/release/app-release.apk (signed with the debug key)
```

## Project structure

```
app/src/main/java/de/fz_juelich/blablador/
├── MainActivity.kt            # Entry point
├── ChatViewModel.kt           # Conversations, settings, replies per chat, tool loop, approvals, trace,
│                              # scheduled task runs, notifications
├── data/
│   ├── Models.kt              # ChatMessage, Conversation, RemoteModel, DocumentAttachment
│   ├── BlabladorApi.kt        # /models, streaming /chat/completions, images, OCR, embeddings,
│   │                          # rerank, speech, transcription, decisions
│   ├── Tools.kt               # Tool definitions (web search, images, generate_speech)
│   ├── Planning.kt            # update_plan, trace, @mentions, skills drafted after multi-step tasks
│   ├── Permissions.kt         # Allow / Ask / Never per kind of tool (and per MCP server)
│   ├── Tasks.kt               # Scheduled tasks (encrypted tasks.json), schedule_task, alarm, notifications
│   ├── DeviceTools.kt         # Calendar (CalendarContract), contacts, location; no reminders on Android
│   ├── Knowledge.kt           # Knowledge bases: chunking, embeddings, vector store, search, rerank
│   ├── Voice.kt               # Voices, delivery settings, audio decoding/resampling, recorder, playback
│   ├── Decision.kt            # Clef questions, examples, saved decisions and answers
│   ├── Updates.kt             # Checks GitHub for a newer release
│   ├── PdfExtractor.kt        # PDF text (PdfBox), OCR (ML Kit or LightOnOCR)
│   └── Storage.kt             # Chat history, images, settings, encrypted API key
└── ui/
    ├── ChatScreen.kt          # Top bar, history drawer, messages, composer
    ├── MessageItem.kt         # Message rows, images, sources, actions
    ├── Markdown.kt            # Markdown renderer with code blocks and tables
    ├── KnowledgeScreen.kt     # Knowledge base list and documents
    ├── VoiceScreens.kt        # Speech clips, Expressions menu, voices, clone a voice
    ├── DecisionScreen.kt      # Clef decisions
    ├── ToolsPanel.kt          # The + panel: attach, reply mode, tools, knowledge, connected tools, more
    ├── AgentViews.kt          # Plan card, trace line and sheet, @mention chips and suggestions
    ├── AgentScreens.kt        # Permissions and scheduled tasks
    ├── SettingsScreen.kt
    └── Theme.kt
```

## Version history
The Android and Apple apps share one version number and one release.

- **3.3.1**: voice cloning up front (+ panel, empty chat, speech mode, @Voice), answers laid out with paragraphs, headings, quotes and small source marks
- **3.3.0**: plans for bigger tasks, skills drafted after tasks, replies that keep running with notifications, scheduled tasks, calendar/contacts/location, permissions per tool (Allow/Ask/Never), trace with time and tokens, new + panel, @ mentions, What's new, better empty-chat examples, scan text from camera/photos/files
- **3.2.0**: linked memories: facts note the people, projects and tools they are about, and recall brings back connected facts
- **3.1.0**: reads web pages, summarises long chats, MCP servers, maths and diagrams, HTML previews, runs Python (plots, CSV/Excel/JSON data files), edit messages and switch versions, regenerate with another model, recall by meaning, share to Blablador and open files with it, blablador:// links, app shortcuts
- **3.0.1**: memory learns from every chat automatically (decisions, projects, conclusions, not only facts about you; can be turned off); chats get short titles
- **3.0.0**: long-term memory, search of earlier chats, skills (write, import, share; the assistant suggests new ones); everything saved is encrypted; memory can't be changed by text from web pages or documents; HTTPS only
- **2.6.5**: pictures from the web next to answers (people, places, things); searches before saying it doesn't know someone
- **2.6.4**: Mac: ⌘+ / ⌘− now also resize reply text, your messages, the text field and the chat list
- **2.6.3**: Mac: bigger and smaller text with ⌘+ / ⌘− / ⌘0 (View menu); also on iPad with a keyboard
- **2.6.2**: share and copy generated speech as an audio file (for example into Messages); speech replies drop Read aloud and Select text
- **2.6.1**: security fixes: the API key stays out of backups and is never stored unencrypted, only web and email links open, update links limited to this project's releases, the Codebase name lookup only with Blablador keys
- **2.6.0**: continue a video from its last frame, start a video from a picture, save videos
- **2.5.1**: version in step with the Mac and iPhone fix for playing videos
- **2.5.0**: videos with sound (MiniMax-H3), choose another OpenAI-compatible endpoint, API-key link with the read_user scope
- **2.4.0**: thinking trace, configurable reply timeout, paste images
- **2.3.0**: attach images from files; version shown in Settings
- **2.2.1**: version in step with the Mac and iPhone fix for the Decide window
- **2.2.0**: write and save your own decisions; update notice
- **2.1.0**: knowledge bases, Drama 3 speech with voice cloning, Clef decisions
- **2.0.0**: first native Android app: chat, web search, PDFs and OCR, photos, image creation and editing
