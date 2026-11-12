#!/usr/bin/env python3
"""An example bla plugin: JSON-RPC 2.0, one message per line on stdin/stdout. See cli/PLUGINS.md.

It refuses `git push --force`, adds a line to the system prompt and offers a `word_count` tool.
Install it by copying this folder to ~/.bla/plugins/guard.
"""
import json
import sys


def initialize(params):
    return {
        "description": "Refuses force pushes; counts words",
        "hooks": ["pre_tool", "system_prompt"],
        "tools": [{
            "name": "word_count",
            "description": "Count the words in a text.",
            "kind": "read",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
        }],
        "commands": [{"name": "guard", "help": "say what the guard plugin does"}],
    }


def pre_tool(params):
    command = params["arguments"].get("command", "") if params["tool"] == "bash" else ""
    if "git push" in command and ("--force" in command or " -f" in command):
        return {"decision": "deny", "reason": "force pushes are off; push normally or ask the user"}
    return {"decision": "allow"}


def system_prompt(params):
    return {"text": "Never force-push; the guard plugin refuses it."}


def tool(params):
    if params["name"] == "word_count":
        return {"content": f"{len(params['arguments'].get('text', '').split())} words"}
    return {"content": f"unknown tool {params['name']}", "is_error": True}


def command(params):
    return {"output": "guard: refuses git push --force and offers word_count."}


HANDLERS = {"initialize": initialize, "pre_tool": pre_tool, "system_prompt": system_prompt, "tool": tool, "command": command}

for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue  # a notification (session_start, session_end)
    handler = HANDLERS.get(message["method"])
    if handler is None:
        reply = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "unknown method"}}
    else:
        reply = {"jsonrpc": "2.0", "id": message["id"], "result": handler(message.get("params") or {})}
    print(json.dumps(reply), flush=True)
