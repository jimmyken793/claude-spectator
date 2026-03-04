#!/usr/bin/env python3
"""
Permission hook for claude-spectator sandbox.

Rewrites sandbox-run commands to use the plugin's binary and wraps
arguments in bash -c with shlex.quote() so shell metacharacters
(pipes, redirections, semicolons, etc.) execute INSIDE the sandbox.

Uses PermissionRequest event (not PreToolUse) because:
1. PermissionRequest has a different decision format where updatedInput
   is nested inside decision{}, potentially avoiding the multi-hook
   aggregation bug (github.com/anthropics/claude-code/issues/15897)
2. PermissionRequest fires when permission dialog would appear, which
   is exactly when sandbox-run needs auto-approval
"""

import json
import os
import shlex
import sys


def get_plugin_root():
    """Resolve the plugin root directory."""
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(script_dir)


DEBUG = False
LOG_FILE = os.path.join(os.path.expanduser("~"), ".claude", "spectator-debug.log")


def debug(msg):
    """Write debug message to stderr AND a log file for diagnosis."""
    if not DEBUG:
        return
    print(f"[claude-spectator] {msg}", file=sys.stderr)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[claude-spectator] {msg}\n")
    except OSError:
        pass


def main():
    try:
        raw = sys.stdin.read()
        debug(f"stdin: {raw[:200]}")
        request = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        debug(f"JSON parse error: {e}")
        return

    tool_name = request.get("tool_name", "")
    command = request.get("tool_input", {}).get("command", "")

    debug(f"tool_name={tool_name!r} command={command[:100]!r}")

    if tool_name != "Bash":
        return

    plugin_root = get_plugin_root()
    if not plugin_root:
        debug("no plugin_root resolved, skipping")
        return
    sandbox_bin = os.path.join(plugin_root, "bin", "sandbox-run")

    # Check if this is a sandbox-run command and extract the arguments
    prefixes = ("sandbox-run", sandbox_bin)
    sandbox_args = None
    for prefix in prefixes:
        if command == prefix:
            sandbox_args = ""
            break
        if command.startswith(prefix + " "):
            sandbox_args = command[len(prefix) + 1:]
            break

    if sandbox_args is None:
        debug("not a sandbox-run command")
        return

    # Build the rewritten command
    if sandbox_args:
        rewritten = sandbox_bin + " bash -c " + shlex.quote(sandbox_args)
    else:
        rewritten = sandbox_bin

    # PermissionRequest format: decision.behavior + decision.updatedInput
    result = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow",
                "updatedInput": {"command": rewritten},
            },
        }
    }
    output = json.dumps(result)
    debug(f"ALLOWING via PermissionRequest: {rewritten[:100]}")
    debug(f"stdout JSON: {output}")
    sys.stdout.write(output + "\n")
    sys.stdout.flush()


try:
    main()
finally:
    sys.exit(0)
