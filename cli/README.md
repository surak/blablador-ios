# bla

Blablador on the command line: a small, fast coding agent written in Rust, where everything is a plugin.

```sh
bla                                  # a chat in the terminal
bla "why does the build fail?"       # one question; it can look around and fix things
git diff | bla "write a commit message"
bla -c                               # continue the last session in this folder
```

It starts in under 10 ms, is a single 2–3 MB binary with no runtime, and uses no `unsafe` code. Like
[pi](https://pi.dev) it starts small: four tools (read, write, edit, bash) and a short system prompt.
Like [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), everything else is a plugin,
the model provider and those four tools included. From [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
it takes permission rules and modes, hooks, AGENTS.md/CLAUDE.md, skills, `@file` and print/JSON modes;
from [Hermes Agent](https://github.com/NousResearch/hermes-agent) a frozen memory and skills it writes
itself. Its memory is the Blablador apps' memory: what you tell the app, bla knows, and the other way round.

## Install

- **Mac:** it comes with the Blablador app (`brew install --cask surak/tap/blablador` links it), or
  Settings → Command line in the app.
- **Windows:** `powershell -ExecutionPolicy ByPass -c "iex ((New-Object Net.WebClient).DownloadString('https://surak.github.io/blablador-ios/install.ps1'))"`
  (goes into `%LOCALAPPDATA%\Programs\bla` and onto your PATH; `-Dir C:\Tools\bla` for another folder)
- **Linux, Raspberry Pi, Mac without the app:** `curl -fsSL https://surak.github.io/blablador-ios/install.sh | sh`
- Or download `Blablador-<version>-bla-<platform>` from the
  [latest release](https://github.com/surak/blablador-ios/releases/latest) and put `bla` on your PATH.
- **From source:** `cargo install --path cli`.

bla keeps itself up to date: at the start of a chat it looks for a newer release once every few hours and, if there is
one, installs it (downloaded from the release's bare `bla-<version>-<platform>`, checked against `SHA256SUMS.txt`, run
once with `--version` to see it works here) and starts the chat again with the new one. `bla update` does the same now
and says what happened; `bla update --check` only looks. A bla that belongs to the Mac app, Homebrew or cargo is left
alone and pointed at its own updater, and the app's Settings → Command line and `brew upgrade --cask` update those.
`BLA_NO_UPDATE_CHECK=1` stops bla from asking GitHub at all; `BLA_NO_AUTO_UPDATE=1` lets it look but never touch.

The first `bla` (or `bla login`) opens your browser on the page where a [Blablador API key](https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/) is made (a Codebase token with the `read_user` scope), and you paste the key there.
It goes into the system keyring (the same entry the desktop app uses), or `~/.bla/.apikey` readable only by you
where there is no keyring. `BLABLADOR_API_KEY` overrides it, and piping a key into `bla login` skips the browser —
see [below](#the-api-key-and-where-it-lives).

### The API key and where it lives

The key is looked up in this order, the first one that has it wins:

1. `BLABLADOR_API_KEY` — set it for one shell, or `setx` it on Windows.
2. The system keyring: macOS Keychain, GNOME Keyring/KWallet on Linux, Windows Credential Manager. The entry is
   service `de.fz-juelich.blablador`, account `apiKey` — on Windows its target name is
   `apiKey.de.fz-juelich.blablador`, visible under Control Panel → Credential Manager → Windows Credentials. The
   desktop app writes the same entry, so the two share a key. `BLABLADOR_NO_KEYRING=1` skips it.
3. The file `~/.bla/.apikey` (on Windows `%USERPROFILE%\.bla\.apikey`, and `BLA_HOME` moves `~/.bla`). On macOS
   and Linux it is created `0600`, so it is never readable by others, even briefly. It is the fallback for a keyring
   that rejects writes or silently drops them (the written key is read back to tell) — so a key can land here even
   where a keyring exists, and `bla login` says which place it saved to. On Windows the mode is a no-op: the file is
   protected only by the permissions it inherits in your profile.

`bla login` tries the key against the configured endpoint before saving it and prints how many chat models it sees;
if the endpoint is down it says so and saves the key anyway. `bla logout` deletes both the keyring entry and the
file. The key is removed from the environment of everything bla starts — commands, hooks, plugins, sub-agents — so a
`run_command` that echoes it gets nothing.

A key that is already known can be handed over without a browser or a prompt: `login` reads stdin when stdin is not
a terminal. On Windows, install and sign in in one line, then open a new terminal so `bla` is on the PATH:

```powershell
iex ((New-Object Net.WebClient).DownloadString('https://surak.github.io/blablador-ios/install.ps1')); 'PASTE-KEY-HERE' | & "$env:LOCALAPPDATA\Programs\bla\bla.exe" login
```

The key then sits in the shell's command line and history; `Clear-History` after, or run `bla login` on its own and
paste it at the hidden prompt.

## Using it

| | |
|---|---|
| `-m, --model ID` | model (default `deepseek-v4.1-flash-at-hzdr`; `/model ID` in a chat saves a new default) |
| `-e, --effort LEVEL` | thinking: off, low, medium, high, max |
| `-s, --system TEXT` | extra instructions |
| `-t, --thinking` | show the thinking in one-shot mode (a chat always shows it, dimmed) |
| `-c` / `-r ID` | continue the last session here / resume one (`bla sessions` lists them) |
| `--mode MODE` | default, careful, plan, yolo |
| `-y, --yes` | approve everything that would ask |
| `--no-tools` | just answer |
| `--no-plugin NAME` | turn a plugin off for this run |
| `--json` | events as JSON lines: text, thinking, tool_start, tool_end, usage, error |
| `--quiet` | no update of bla at the start of a chat |
| `-l, --models` | list the models |
| `-v, --version` | the version, and whether a newer one is out (fast: it uses an answer less than six hours old) |
| `--update` | install a newer bla now (same as `bla update`) |

In one-shot mode only the answer goes to stdout; tool lines and questions go to stderr, so `bla … > file` works.

The chat is a full-screen view with the Blablador logo at the top. Scroll back with the mouse wheel, the scroll
bar or Page Up/Down; drag over text to select and copy it; click a tool call or the thinking to open or close
it (Ctrl-O opens all). `/` suggests commands, Tab completes `@path`, Shift-Enter (or `\` then Enter) starts a
new line, Up/Down go through earlier messages, Option-Left/Right (or Ctrl-Left/Right, and Alt-b/Alt-f) move a word
at a time, Option-Delete deletes a word, Ctrl-A/Ctrl-E go to the start and end of the line. You can type while the
answer is written: messages wait their turn above the input. Esc stops the answer; Ctrl-C twice quits.

The line under the input shows the model, the thinking effort, the tokens (`in`: the last request, so how full the
context is; `out`: everything written this session), what that would cost at Claude's most expensive standard rate
(`≈$0.42 at Claude Fable 5`, $10/$50 per million tokens — Blablador itself is free, the number is a reference),
and the folder.

In a chat: `/help` lists the commands (`/new`, `/resume`, `/login` (a new key without leaving the chat; used at once), `/model`, `/effort`, `/mode`, `/compact`, `/undo`,
`/skills`, `/memory`, `/voice`, `/tools`, `/plugins`, and one per skill); `/yolo` stops asking for the rest of the
session and `/safe` starts again; `!command` runs a shell command and
shows the model its output; `@path` attaches a file; Esc or Ctrl-C stops the answer; Ctrl-C twice or Ctrl-D
quits. While it answers, Enter queues your message for after the answer, and `/steer TEXT` changes course without
stopping it: the model gets the message at its next step, between tool calls (or right after its last words).

### Talking to it

`/voice` turns the microphone on and bla answers out loud, the same conversation the apps have. Say something
and stop; the pause ends your turn, Whisper writes it down and it is sent as if you had typed it. The answer is
read back by Drama 3 sentence by sentence while it is still being written, so it starts talking before it has
finished thinking. `/voice pt` (or any language code) tells Whisper which language to expect instead of
guessing. `/voice off` ends it.

A line above the input shows whether it is listening, hearing you, writing you down or speaking, with a meter
for how loud the room is. Esc stops it talking; while it talks, so does saying "stop". To interrupt with a new
question, just ask it: the terminal has no echo cancellation, so bla ignores anything it hears in the second
after it stops and anything whose words are mostly words it just said, and it takes three words it did not say
to throw the answer away and listen to you instead. While voice is on the model is told to answer to be heard —
a few short sentences, no lists or code read out loud; code is shown on the screen and said to be there.

The first `/voice` makes your terminal ask for the microphone, and the permission belongs to the terminal
program, not to bla. On Linux, building needs the ALSA headers (`sudo apt-get install libasound2-dev`).

### On Telegram

`bla serve --telegram` answers in a Telegram chat instead of this terminal: the same folder, the same
tools, the same memory, from wherever you are. Send a message and it works; send a voice note and it
listens, through the same Whisper the microphone uses. `--speak` sends the answers back as voice notes
read by Drama 3.

```sh
export BLA_TELEGRAM_TOKEN=123456:AA…          # from @BotFather
bla serve --telegram --telegram-allow 4242    # your chat id
```

The token and the allowed chats can live in `~/.bla/telegram.json` instead:

```json
{ "token": "123456:AA…", "allow": [4242] }
```

**The allow list is not optional.** This gives whoever can message the bot an agent that reads files
and runs commands on the machine you started it on, so a message from any chat that is not on the
list is refused before the model sees a word of it, and the refused chat's id is printed so you can
add it if it was you. Start it without a list and it refuses to start at all. Anything that would ask
in the terminal asks in the chat — the command is shown and nothing runs until an allowed chat replies
`yes`, `always` or `no`, and after ten minutes with no answer it is a no.

In the chat: `/new` forgets the conversation, `/speak` turns reading aloud on and off, `/whoami` gives
the chat id, `/help` lists them. Each chat keeps its own conversation. Ctrl-C stops the bridge.

`BLA_TELEGRAM_API` points it at a bot API server of your own instead of Telegram's.

## Permissions

bla asks less than it used to, and about the same as Claude Code with edits accepted. Reads and changes inside
the working directory don't ask: every turn is checkpointed, so `/undo` takes changes back. Commands that only
look (`ls`, `rg`, `find`, `git status`…), even joined by pipes, `&&` and `;`, don't ask either, as long as they
don't redirect, substitute or reach outside the folder. Other commands ask: yes, always, or no.

**Always** is remembered for the project (in `~/.bla/approvals.json`) and covers the program and its
subcommand: approving `cargo test --release` also allows `cargo test` and `cargo test foo` later, and `npm run
build` allows `npm run lint`. For anything that deletes, escalates, reaches the network or runs a script
(`rm`, `sudo`, `curl`, `git push`, `python3 x.py`…) it covers only that exact command.

| Mode | Reads | File changes | Commands |
|---|---|---|---|
| default | allowed anywhere but the secrets | allowed inside the folder and in temp | ask only when it can't be undone |
| careful | allowed anywhere but the secrets | ask | ask, except looking and "always" |
| plan | allowed | refused | refused |
| yolo | allowed | allowed | allowed, deny rules aside |

`/yolo` switches to yolo mode for the rest of the session, `/safe` back to default.

Rules in `settings.json` come first: deny, then ask, then allow.

```json
{
  "model": "deepseek-v4.1-flash-at-hzdr",
  "permissions": {
    "mode": "default",
    "allow": ["bash(cargo test*)", "bash(npm run test:*)", "edit(src/**)"],
    "ask": ["bash(git push*)"],
    "deny": ["read(.env*)", "bash(rm -rf *)"]
  }
}
```

`tool(pattern)` matches the command for bash and the path for file tools (`*` within a folder, `**` across
folders; a bare name matches in any folder). Claude Code's spelling (`Bash(npm run test:*)`, `Write`, `MultiEdit`)
works too.

- **Allow rules** only apply to a single command: `cargo test && curl … | sh` asks even with `bash(cargo test*)`
  allowed.
- **Deny and ask rules** are checked against every part of a command line, including what follows `sudo`, `env` or
  `sh -c`. A shell can still hide a command in ways no pattern catches, though. For a hard guarantee, use plan mode,
  or a PreToolUse hook that inspects the command.

Other safeguards:

- **Read before change:** files have to be read before they are changed, and the change is refused if the file
  changed on disk since. Writes go through a temporary file and a rename, so a file is never half-written.
- **`/undo`:** puts back the files the last turn changed (the checkpoints plugin).
- **Secrets:** the API key never reaches commands, hooks or plugins (it is removed from their environment) and is
  never sent over plain http except to this computer.
- **Session files:** sessions are written readable only by you.

## Settings and trust

`~/.bla/settings.json`, then the project's `.bla/settings.json`. A repository you cloned shouldn't be able to run
code on your machine, so until you run `bla trust` in it, only its `model`, `effort` and its `deny`/`ask` rules
are read. Its hooks, plugins, skills, allow rules and endpoint are ignored.

| Key | |
|---|---|
| `model`, `effort` | as the options |
| `endpoint` | any OpenAI-compatible API (default Blablador); `allowInsecureHttp` for plain http elsewhere |
| `maxSteps` | model requests per message (60) |
| `compactAt` | compact the conversation past this many characters (240000) |
| `permissions` | above |
| `hooks` | below |
| `plugins` | `{"disabled": ["memory"], "external": [{"name": "x", "command": ["python3", "x.py"]}]}` |

Everything lives in `~/.bla` (or `BLA_HOME`): `settings.json`, `sessions/`, `skills/`, `memory/`, `plugins/`,
`AGENTS.md` (instructions for every project) and `history`.

## Plugins

`bla plugins` lists them. Built in, each can be turned off:

| Plugin | |
|---|---|
| openai | the model provider: streaming chat completions with tools, for any OpenAI-compatible endpoint |
| core-tools | read, write, edit, bash |
| context | `AGENTS.md` or `CLAUDE.md` from `~/.bla` and every folder from the project root down, the git branch, `@file` |
| permissions | rules and modes, `/mode` |
| hooks | shell hooks in Claude Code's format |
| skills | `SKILL.md` skills from `~/.bla/skills`, `~/.claude/skills`, `~/.agents/skills` (and the project's, when trusted); the agent saves new ones; `/skills`, `/<skill> task` |
| memory | the long-term memory shared with the Blablador apps (on the Mac through the app, `Blablador --memory`; on Linux and Windows the desktop app's encrypted `memories.json`), frozen into each session's prompt; `/memory`, and `/memory forget all` deletes every fact, in the apps too. Facts in the old `~/.bla/memory` are moved over once |
| checkpoints | `/undo` |
| compaction | summarises long conversations; `/compact` |
| blablador | Blablador's other models: `look_at_image` (vision), `ocr_image`, `generate_image`, `transcribe_audio`, and `blablador_models`, a catalog of every served model in `~/.bla/models.json` (new ones are looked up on Hugging Face or the web and described) |
| web | `web_search` on Blablador's SearXNG and `read_page` for public pages, PDFs and shared Google Docs; local and private addresses are refused |
| agents | `task`: subagents. `explore` ones are read-only and run in parallel; `general` ones may edit, after the usual permission check |
| processes | `bash_background`, `bash_output`, `bash_kill` for dev servers, watchers and long builds; `/jobs` |
| plan | `update_plan` checklists; `/goal TEXT` keeps bla working until the goal is reached and verified (`/goal clear` ends it) |
| mcp | MCP servers in Claude Code's `mcpServers` format from `~/.bla/mcp.json` (and a trusted project's `.mcp.json`), stdio or Streamable HTTP; tools appear as `server__tool`; `/mcp` |

Anything else is an external plugin: a program in any language that speaks JSON-RPC over stdin and stdout. It
can add tools and commands, and hook into the system prompt, your messages, every tool call (allow, ask, deny or
rewrite it) and the end of a turn. External plugins run as separate processes with time limits and never see the
key. See [PLUGINS.md](PLUGINS.md) and the example in [examples/plugins/guard](examples/plugins/guard).

## Hooks

Hooks use Claude Code's format, so its hook scripts work as they are:

```json
"hooks": {
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.bla/hooks/check.sh", "timeout": 30}]}],
  "PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "cargo fmt"}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "./scripts/tests-pass.sh"}]}]
}
```

The events are SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop and SessionEnd.

- **Input:** the hook gets JSON on stdin (`session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`,
  `tool_response`, `prompt`).
- **Blocking:** exit code 2 blocks, with stderr as the reason. A blocking Stop hook sends the reason back to the
  model and the turn goes on.
- **Exit 0:** stdout may be JSON (`{"decision": "block", "reason": …}`, or
  `{"hookSpecificOutput": {"permissionDecision": "allow" | "ask" | "deny"}}`). Plain stdout from SessionStart and
  UserPromptSubmit is added as context.

## Building

```sh
cd cli
cargo test
cargo build --release      # target/release/bla
```

On Linux the microphone needs the ALSA headers: `sudo apt-get install libasound2-dev`.

The Mac app's build runs `scripts/embed-cli.sh`, which builds a universal `bla` and puts it in the app's Resources.
