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
```

## Project structure

```
app/src/main/java/de/fz_juelich/blablador/
├── MainActivity.kt            # Entry point
├── ChatViewModel.kt           # Conversations, settings, sending/streaming, tool loop
├── data/
│   ├── Models.kt              # ChatMessage, Conversation, RemoteModel, DocumentAttachment
│   ├── BlabladorApi.kt        # /models, streaming /chat/completions, images, OCR
│   ├── Tools.kt               # Tool definitions and web search
│   ├── PdfExtractor.kt        # PDF text (PdfBox), OCR (ML Kit or LightOnOCR)
│   └── Storage.kt             # Chat history, images, settings, encrypted API key
└── ui/
    ├── ChatScreen.kt          # Top bar, history drawer, messages, composer
    ├── MessageItem.kt         # Message rows, images, sources, actions
    ├── Markdown.kt            # Markdown renderer with code blocks and tables
    ├── SettingsScreen.kt
    └── Theme.kt
```
