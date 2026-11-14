# Blablador for Windows, Linux and Raspberry Pi

A native desktop client written in Rust (egui), sharing the version number and release with the iOS/Mac and Android apps.

Features: streaming chat with model and thinking-effort choice, encrypted chat history (AES-GCM, key in the
system keyring or a private file when there is none), web search and page reading, long-term memory, search of
earlier chats, shell commands in a chosen folder after approval, attached PDFs and text files, and knowledge bases
(embeddings and rerank on Blablador), and 3D room: photos mapped into a floor plan and a point cloud by `alias-visual-geometry` (`src/mapper.rs`).

Proteins (`src/proteins.rs`): the five molecular models — ESMFold2, BioEmu2, RFdiffusion3, BindCraft and
Proteina-Complexa. They are job APIs, not chat models: a submitted job is kept here (encrypted, like everything
else) because the service has no job list of its own, is polled while the app is open, and its result archive is
downloaded as soon as it finishes, since results are deleted upstream after 48 hours. There is no progress
percentage and no ETA — the service publishes neither. Every downloaded structure is measured before it is
shown: a job can finish, report success and hand back a backbone that no chemistry allows. The protocol, the
five forms and that check live in the shared crate (`../shared`, `blablador-models`), which also says which
models can chat, so `bla` and the app always agree.

    cargo run --release     # build and start
    cargo test

Linux needs `libxkbcommon`, GTK 3 (file dialogs) and D-Bus (Secret Service). `BLABLADOR_API_KEY` overrides the
saved key; `BLABLADOR_DATA_DIR` moves the data folder; `BLABLADOR_NO_KEYRING=1` keeps secrets in files.

Releases: `.github/workflows/desktop.yml` builds `Blablador-<version>-windows-x86_64.zip`, `Blablador-<version>-linux-arm64.tar.gz` (Raspberry Pi OS 64-bit), `Blablador-<version>-macos-arm64-desktop.tar.gz` and
`Blablador-<version>-linux-x86_64.tar.gz` when a release is published and adds them to `SHA256SUMS.txt`.
Bump `version` in `Cargo.toml` with the other apps.

Not yet ported: OCR of scanned PDFs, images, voice, Drama 3 speech, agent file tools, MCP, skills, scheduled tasks.
