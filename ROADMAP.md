# Agent roadmap: memory, skills, automation

Hermes-style agent features built natively into the iOS/macOS and Android apps, running on the device against the
Blablador API. Ordered from least to most work. Each step ships in both apps.

## 1. Long-term memory (done)

- `remember` / `forget` tools; facts stored on the device (`MemoryStore`, `memories.json`), at most 100.
- Numbered list sent in the system prompt of every chat; replies show "Remembered: …" / "Forgot: …".
- Settings → Memory: on/off, view, edit, add, delete, forget everything.

## 2. Long-term memory, better recall

- Search past chats: a `search_chats` tool over the chat history (keyword first, then embeddings with
  `alias-qwen3-4b-embeddings`, reusing `KnowledgeLibrary`'s vector code).
- When memories grow past what fits the prompt, retrieve only the relevant ones by embedding similarity.
- Optional summary of each finished chat saved as a memory.

## 3. Skills

- A skill is a named Markdown instruction document ("How I want meeting notes", "Write a Helmholtz press release").
- Library in Settings: create, edit, import/export (`.md` with a front-matter name and description), share between devices
  through files.
- Only names and descriptions go in the system prompt; a `use_skill` tool loads the full text when it applies.
- `save_skill` tool so the assistant can turn a successful procedure into a skill, after the user confirms.
- Skills can bundle knowledge bases and a preferred model.

## 4. Automation: scheduled tasks

- "Every morning at 8, summarise the news about X": tasks with a prompt, a schedule and a model, stored on the device.
- Runs produce a chat and a notification. iOS: `BGAppRefreshTask` gives no exact times, so exact schedules need local
  notifications that run on tap, or a server; macOS: a timer while the app runs plus a login item; Android: WorkManager.
- `schedule_task` tool so the assistant can create tasks from chat.

## 5. Automation: browser

- A `browse` tool that loads a page in an off-screen WKWebView / Android WebView and returns readable text
  (follow-up to the existing `web_search` snippets).
- Then interactive steps (click, fill, scroll) with screenshots read by a vision model, every action approved by the
  user like `run_command` in agent mode. Confined to http(s); no saved passwords.
- Hardest part: reliable element targeting and keeping the user in control; start read-only.
