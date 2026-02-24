#!/usr/bin/env bash
set -euo pipefail

# Platform-specific checks
case "$(uname -s)" in
  Darwin)
    if ! command -v sandbox-exec &>/dev/null; then
      echo "Warning: sandbox-exec not found. Expected on macOS." >&2
    fi
    ;;
  Linux)
    if ! command -v bwrap &>/dev/null; then
      echo "Warning: bwrap (bubblewrap) not installed." >&2
      echo "Install with: sudo apt install bubblewrap" >&2
    fi
    ;;
esac

echo "claude-spectator: setup complete"
