# Agent roadmap: memory, skills, automation

Hermes-style agent features built natively into the iOS/macOS and Android apps, running on the device against the
Blablador API. Ordered from least to most work. Each step ships in both apps.

## 1. Long-term memory (done)

- `remember` / `forget` tools; facts stored on the device (`MemoryStore`, `memories.json`), at most 100.
- Numbered list sent in the system prompt of every chat; replies show "Remembered: …" / "Forgot: …".
- Settings → Memory: on/off, view, edit, add, delete, forget everything.

## 2. Long-term memory, better recall (done, keyword version)

- `search_chats` tool: keyword search over earlier chats, returning excerpts with chat title and date (`ChatSearch`).
  Counts as outside content, so memory can't be changed in the same reply.
- After every reply, `alias-fast` picks out facts worth keeping from the exchange (about the user and about the topics
  discussed) and saves them; only the user's own text when the reply read outside content. Can be turned off.
- Over 30 memories, only the ones sharing words with the question plus the 10 newest are sent, keeping their numbers.
- Later: embeddings (`alias-qwen3-4b-embeddings`, reusing `KnowledgeLibrary`'s vector code) instead of keywords;
  optional summary of each finished chat saved as a memory.

## 3. Skills (done)

- A skill is a named Markdown instruction document ("How I want meeting notes", "Write a Helmholtz press release"),
  saved encrypted (`skills.json`).
- Settings → Skills: create, edit, delete, import `.md` files (front matter with `name` and `description`), share as Markdown.
- Only names and descriptions go in the system prompt; `use_skill` loads the full text; replies show "Used skill: …".
- `suggest_skill`: the assistant offers a skill under its reply; nothing is saved until the user presses Save.
- Later: skills that bundle knowledge bases and a preferred model.

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
