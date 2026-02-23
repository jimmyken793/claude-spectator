#!/usr/bin/env bash
set -euo pipefail

# Read the permission request from stdin
INPUT=$(cat)

# Extract tool_name and command using python3 (available on macOS and Linux)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
COMMAND=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
SANDBOX_BIN="${PLUGIN_ROOT}/bin/sandbox-run"

if [[ "$TOOL_NAME" == "Bash" && ( "$COMMAND" == "sandbox-run "* || "$COMMAND" == "sandbox-run" ) ]]; then
  # Rewrite bare sandbox-run to use the plugin's own binary
  REWRITTEN="${SANDBOX_BIN}${COMMAND#sandbox-run}"
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"},\"updatedInput\":{\"command\":\"${REWRITTEN}\"}}}"
elif [[ "$TOOL_NAME" == "Bash" && ( "$COMMAND" == "${SANDBOX_BIN} "* || "$COMMAND" == "$SANDBOX_BIN" ) ]]; then
  # Already using full path — approve as-is
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
else
  # Fall through to normal permission flow
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
fi
