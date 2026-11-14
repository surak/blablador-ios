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
- **Linux, Windows, Raspberry Pi, Mac without the app:** download `Blablador-<version>-bla-<platform>` from the
  [latest release](https://github.com/surak/blablador-ios/releases/latest) and put `bla` on your PATH.
- **From source:** `cargo install --path cli`.

Then `bla login` and paste your [Blablador API key](https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/).
It goes into the system keyring (the same entry the desktop app uses), or `~/.bla/.apikey` readable only by you
where there is no keyring. `BLABLADOR_API_KEY` overrides it.

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

In one-shot mode only the answer goes to stdout; tool lines and questions go to stderr, so `bla … > file` works.

The chat is a full-screen view with the Blablador logo at the top. Scroll back with the mouse wheel, the scroll
bar or Page Up/Down; drag over text to select and copy it; click a tool call or the thinking to open or close
it (Ctrl-O opens all). `/` suggests commands, Tab completes `@path`, Shift-Enter (or `\` then Enter) starts a
new line, Up/Down go through earlier messages. You can type while the answer is written: messages wait their
turn above the input. Esc stops the answer; Ctrl-C twice quits.

In a chat: `/help` lists the commands (`/new`, `/resume`, `/model`, `/effort`, `/mode`, `/compact`, `/undo`,
`/skills`, `/memory`, `/tools`, `/plugins`, and one per skill); `!command` runs a shell command and shows the
model its output; `@path` attaches a file; Esc or Ctrl-C stops the answer; Ctrl-C twice or Ctrl-D quits.

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
| default | allowed (outside the folder: ask) | allowed inside the folder | ask, except looking and "always" |
| careful | allowed (outside the folder: ask) | ask | ask |
| plan | allowed | refused | refused |
| yolo | allowed | allowed | allowed |

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
| memory | the long-term memory shared with the Blablador apps (on the Mac through the app, `Blablador --memory`; on Linux and Windows the desktop app's encrypted `memories.json`), frozen into each session's prompt; `/memory`. Facts in the old `~/.bla/memory` are moved over once |
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

The Mac app's build runs `scripts/embed-cli.sh`, which builds a universal `bla` and puts it in the app's Resources.
