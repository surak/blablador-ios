# Blablador for Windows, Linux and Raspberry Pi

A native desktop client written in Rust (egui), sharing the version number and release with the iOS/Mac and Android apps.

Features: streaming chat with model and thinking-effort choice, encrypted chat history (AES-GCM, key in the
system keyring or a private file when there is none), web search and page reading, long-term memory, search of
earlier chats, shell commands in a chosen folder after approval, attached PDFs and text files, and knowledge bases
(embeddings and rerank on Blablador).

    cargo run --release     # build and start
    cargo test

Linux needs `libxkbcommon`, GTK 3 (file dialogs) and D-Bus (Secret Service). `BLABLADOR_API_KEY` overrides the
saved key; `BLABLADOR_DATA_DIR` moves the data folder; `BLABLADOR_NO_KEYRING=1` keeps secrets in files.

Releases: `.github/workflows/desktop.yml` builds `Blablador-<version>-windows-x86_64.zip`, `Blablador-<version>-linux-arm64.tar.gz` (Raspberry Pi OS 64-bit), `Blablador-<version>-macos-arm64-desktop.tar.gz` and
`Blablador-<version>-linux-x86_64.tar.gz` when a release is published and adds them to `SHA256SUMS.txt`.
Bump `version` in `Cargo.toml` with the other apps.

Not yet ported: OCR of scanned PDFs, images, voice, Drama 3 speech, agent file tools, MCP, skills, scheduled tasks.
