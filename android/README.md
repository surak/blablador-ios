# Blablador for Android

Native Android client for [Helmholtz Blablador](https://helmholtz-blablador.fz-juelich.de), the OpenAI-compatible
LLM service of Forschungszentrum Jülich (`https://api.blablador.fz-juelich.de/v1`). Kotlin, Jetpack Compose and Material 3.
It is the Android counterpart of [blablador-ios](https://github.com/surak/blablador-ios) (Mac, iPhone and iPad).

## Features

- **Chat** with every Blablador chat model, streaming replies; default `deepseek-v4.1-flash-at-hzdr`. Markdown with code blocks and tables
- **Web search** through search.blablador.fz-juelich.de, with cited sources
- **Photos and camera** for vision-capable models
- **PDFs** (+ → PDF): text extracted on the device with PdfBox; scanned pages read with OCR
- **Text from photo** (+ → Text from photo): OCR of documents, receipts or slides
- **OCR engine** in Settings → Documents: on device (ML Kit) or Blablador's LightOnOCR (`alias-ocr`), which keeps tables; falls back to on-device
- **Create and edit images** with FLUX.2-dev or Qwen-Image 2.1; tap **Edit** on any image in the chat
- **Dictation** (system speech recognizer) and **read-aloud** (system text-to-speech)
- **History** with search; personalised greeting; API key stored encrypted with the Android Keystore
- **Knowledge bases** (+ → Knowledge): collections of PDFs and text files indexed with `alias-qwen3-4b-embeddings` and re-ranked with
  `alias-qwen3-4b-reranker`; the index stays on the device and replies cite excerpts as [K1], [K2]
- **Speech with Drama 3** (+ → Speak): built-in voices, feelings, pace, whisper and an Expressions menu for pauses, laughs and tags;
  the assistant can also speak with the `generate_speech` tool
- **Voice cloning**: record a sample, pick an audio or video file, or fetch a link; Whisper transcribes it for Drama 3
- **Decide** (+ → Decide): the Clef decision model (`alias-clef`) with 73 examples; answers with probabilities

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
**+ → Decide (Clef)** opens the decision screen: pick one of 73 examples in 12 categories or write a situation and
questions (yes/no, choice, or score). It calls `POST /v1/systemone` with `alias-clef` and shows each answer with
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
- A Blablador API key: https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/

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
./gradlew assembleRelease      # app/build/outputs/apk/release/app-release.apk (signed with the debug key)
```

## Project structure

```
app/src/main/java/de/fz_juelich/blablador/
├── MainActivity.kt            # Entry point
├── ChatViewModel.kt           # Conversations, settings, sending/streaming, tool loop
├── data/
│   ├── Models.kt              # ChatMessage, Conversation, RemoteModel, DocumentAttachment
│   ├── BlabladorApi.kt        # /models, streaming /chat/completions, images, OCR, embeddings,
│   │                          # rerank, speech, transcription, decisions
│   ├── Tools.kt               # Tool definitions (web search, images, generate_speech)
│   ├── Knowledge.kt           # Knowledge bases: chunking, embeddings, vector store, search, rerank
│   ├── Voice.kt               # Voices, delivery settings, audio decoding/resampling, recorder, playback
│   ├── Decision.kt            # Clef questions, examples and answers
│   ├── PdfExtractor.kt        # PDF text (PdfBox), OCR (ML Kit or LightOnOCR)
│   └── Storage.kt             # Chat history, images, settings, encrypted API key
└── ui/
    ├── ChatScreen.kt          # Top bar, history drawer, messages, composer
    ├── MessageItem.kt         # Message rows, images, sources, actions
    ├── Markdown.kt            # Markdown renderer with code blocks and tables
    ├── KnowledgeScreen.kt     # Knowledge base list and documents
    ├── VoiceScreens.kt        # Speech clips, Expressions menu, voices, clone a voice
    ├── DecisionScreen.kt      # Clef decisions
    ├── SettingsScreen.kt
    └── Theme.kt
```

## Version history
- **2.1.0**: knowledge bases, Drama 3 speech with voice cloning, Clef decisions
- **2.0.0**: first native Android app: chat, web search, PDFs and OCR, photos, image creation and editing
