---
name: sandboxed-execution
description: Use when running shell commands that may not be auto-approved — prefix with sandbox-run for read-only sandboxed execution without permission prompts
---

# Sandboxed Command Execution

## When to Use

When you need to run a shell command that might not be in the auto-approved allowlist, prefix it with `sandbox-run`:

```bash
sandbox-run <command> [args...]
```

## What the Sandbox Enforces (OS-level)

- **File reads**: allowed (except credential paths)
- **Credential reads**: blocked (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, etc.)
- **File writes**: blocked (EPERM — kernel-enforced)
- **Network access**: blocked

## Examples

```bash
# Exploration and inspection
sandbox-run git status
sandbox-run git log --oneline -20
sandbox-run python3 -c "import os; print(os.getcwd())"
sandbox-run find . -name '*.py' -type f
sandbox-run wc -l src/**/*.ts
sandbox-run du -sh node_modules/

# These will fail inside the sandbox (as expected)
sandbox-run git commit -m "test"     # EPERM — can't write .git/
sandbox-run npm install              # EPERM — can't write node_modules/
sandbox-run curl https://example.com # network denied
```

## When NOT to Use

Do **not** sandbox commands that need to write files or access the network:

- `git add`, `git commit`, `git push`
- `npm install`, `pip install`, `brew install`
- `make`, `npm run build` (if writing output files)
- `curl`, `wget`, `npm publish`

These should go through the normal permission flow.

## Key Detail

`sandbox-run` is auto-approved — no permission prompt will appear. This is safe because the OS kernel enforces the read-only and no-network constraints regardless of what command is run inside.
