# Writing a bla plugin

bla's own features are plugins compiled into it (see `src/plugins/`). Anything else is an **external plugin**: a
program in any language that bla starts when a session begins and talks to with
[JSON-RPC 2.0](https://www.jsonrpc.org/specification), one JSON object per line, on the program's stdin and
stdout.

The rules:

- **Its own process:** an external plugin is never loaded into bla. A crash or a hang can't take bla down.
- **Time limits:** a call that doesn't answer within its time limit (30 s for hooks, 10 min for tools) stops the
  plugin.
- **No key:** `BLABLADOR_API_KEY` is removed from its environment.
- **stderr:** discarded, unless `BLA_PLUGIN_DEBUG=1` is set.
- **Project plugins:** a project's plugins (`.bla/plugins`, or `plugins.external` in `.bla/settings.json`) are
  only started after `bla trust`.

## Installing

Either a folder in `~/.bla/plugins/<name>/` with a `plugin.json` (the command runs in that folder):

```json
{"name": "guard", "description": "Refuses force pushes", "command": ["python3", "guard.py"]}
```

or an entry in `~/.bla/settings.json`:

```json
"plugins": {"external": [{"name": "guard", "command": ["python3", "/path/to/guard.py"]}]}
```

`bla plugins` shows what is installed; `--no-plugin guard` or `"plugins": {"disabled": ["guard"]}` turns one off.

## The conversation

bla sends requests (with an `id`, expecting a response with the same `id`) and notifications (no `id`, no
response). Lines that aren't JSON, or responses to other ids, are ignored. An error response
(`{"error": {"message": …}}`) is shown to the model or the user.

### initialize (request, once)

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocol": 1, "bla": "3.8.0", "cwd": "/work/project"}}
```

The result declares what the plugin does; every field is optional:

```json
{
  "description": "Refuses force pushes; counts words",
  "hooks": ["system_prompt", "user_prompt", "pre_tool", "post_tool", "turn_end", "session_start", "session_end"],
  "tools": [{"name": "word_count", "description": "Count words", "kind": "read",
             "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}],
  "commands": [{"name": "guard", "help": "what the guard does"}]
}
```

Only the hooks listed are called. A tool's `kind` decides how permissions treat it:

| `kind` | Permissions | In parallel with other reads | In plan mode |
|---|---|---|---|
| `read` | allowed | yes | allowed |
| `write` | treated like file changes | no | refused |
| `exec` (default) | asks | no | refused |
| `internal` | allowed without asking | no | allowed |

A tool whose name another plugin already provides is skipped, with a warning.

### Requests

| Method | Params | Result |
|---|---|---|
| `tool` | `name`, `arguments`, `cwd` | `{"content": "…", "is_error": false}` |
| `system_prompt` | `session_id`, `cwd` | `{"text": "a section for the system prompt"}`, once per session |
| `user_prompt` | `session_id`, `text` | `{"text": "rewritten"}`, or `{"block": "reason"}` to refuse the message |
| `pre_tool` | `session_id`, `tool`, `kind`, `arguments` | `{"decision": "allow" \| "ask" \| "deny", "reason": "…", "arguments": {…}}` (`arguments` rewrites the call) |
| `post_tool` | `session_id`, `tool`, `arguments`, `content`, `is_error` | `{"content": "…", "is_error": …}` to change what the model sees, or `{}` |
| `turn_end` | `session_id`, `last_message` | `{"continue": "message"}` keeps the turn going with that message, or `{}` |
| `command` | `name`, `args` | `{"output": "shown to the user"}` or `{"prompt": "sent to the model"}` |

When a plugin rewrites the arguments, every plugin (hooks included) judges the call again with the final arguments,
at most three rounds. So `pre_tool` can run more than once for one call; keep it free of side effects.

The decisions of all plugins combine strictly: any deny wins, then any ask, then allow. If a plugin with
`pre_tool` fails to answer, bla asks the user rather than letting the call through unseen. A `turn_end`
continuation is limited to eight per message, so a plugin can't keep a turn going forever.

### Notifications

`session_start` (`session_id`, `cwd`) and `session_end` (`session_id`), for plugins that listed them.

## Example

[examples/plugins/guard/guard.py](examples/plugins/guard/guard.py) refuses `git push --force`, adds a line to the
system prompt, offers a `word_count` tool and a `/guard` command, in about 60 lines of Python. Copy the folder to
`~/.bla/plugins/guard` to try it.

## Built-in plugins

The built-in plugins implement the `Plugin` trait in `src/plugin.rs`. It has the same hooks with Rust types, plus
`providers` (model adapters, see `llm::Provider`) and `before_request` (rewriting the history, used by
compaction). Adding one means writing the module in `src/plugins/` and listing it in `src/plugins/mod.rs`.
