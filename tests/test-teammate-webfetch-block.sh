#!/usr/bin/env bash
# test-teammate-webfetch-block.sh — Test suite for v5.9.3 M-new-2: WebFetch/WebSearch teammate block
#
# EMPIRICALLY VERIFIED ENV VARS (2026-04-19 via `strings claude-binary | grep -oE 'CLAUDE_[A-Z_]+'`):
#   CLAUDE_CODE_TEAMMATE_COMMAND — present in binary; only set for real team-mode teammates (positive signal)
#   CLAUDE_CODE_TEAM_NAME       — present in binary; set for team context
#   FABRICATED (not in binary): CLAUDE_TEAM_NAME, CLAUDE_TEAM_ROLE — were our invented names, caused silent dead-code
#
# Problem solved: WebFetch/WebSearch trigger Claude Code's permission-explainer path
# (Tl7/Uf8 → getAppState crash) when called from a team-mode teammate subprocess.
# The hook exits 2 BEFORE the approval-prompt machinery fires, preventing the crash.
#
# Tests:
#   TC-TWF-1: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebFetch → exit 2 with TEAM_MATE_TOOL_DENY
#   TC-TWF-2: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebSearch → exit 2 with TEAM_MATE_TOOL_DENY
#   TC-TWF-3: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebFetch → exit 0 (not blocked)
#   TC-TWF-4: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebSearch → exit 0 (not blocked)
#   TC-TWF-5: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + WebFetch → exit 0 (falsy, not a teammate marker)
#   TC-TWF-6: default session (no teammate env vars at all) + WebFetch → no false-positive TEAM_MATE_TOOL_DENY
#   TC-TWF-7: team-mode teammate + Read (non-credential path) → no TEAM_MATE_TOOL_DENY (Read is not in this block)
#   TC-TWF-8: team-mode teammate + Write → exit 2 with TEAM_MATE_WRITE_DENY (existing block unaffected)
#
# Run: bash tests/test-teammate-webfetch-block.sh
# Exit 0 = all tests pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-teammate-webfetch-block.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"

mkdir -p "$FAKE_HOME/.claude"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/authority"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"

cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
touch "$FAKE_HOME/.claude/ainous-roles/authority/decisions.md"
echo "developer" > "$FAKE_HOME/.claude/.session-role"

cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["journal.md","playbook.md","learnings.jsonl","memory.md"]}
EOF

FAKE_SESSION_ID="test-session-teammate-webfetch-block"

# Nonce setup (needed so _validate_taint_field doesn't fail-closed on missing nonce)
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"
HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$FAKE_SESSION_ID" 2>/dev/null)
NONCE_FILE="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
printf 'deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234' > "$NONCE_FILE"
chmod 600 "$NONCE_FILE"

FAKE_TEAMMATE_CMD="claude-code-team-mate-cmd"

# Helper: build WebFetch tool JSON input
_webfetch_json() {
    local url="${1:-https://example.com}"
    python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'url':sys.argv[2],'prompt':'Fetch this page'}))" \
        "$FAKE_SESSION_ID" "$url" 2>/dev/null
}

# Helper: build WebSearch tool JSON input
_websearch_json() {
    local query="${1:-test query}"
    python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'query':sys.argv[2]}))" \
        "$FAKE_SESSION_ID" "$query" 2>/dev/null
}

# Helper: run authority-enforce.sh WebFetch with explicit env vars
# Usage: _run_webfetch_hook <url> <teammate_command> <role>
_run_webfetch_hook() {
    local url="${1:-https://example.com}"
    local teammate_command="${2:-}"
    local role="${3:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_webfetch_json "$url")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="WebFetch" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Helper: capture stderr from WebFetch hook
_run_webfetch_hook_stderr() {
    local url="${1:-https://example.com}"
    local teammate_command="${2:-}"
    local role="${3:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_webfetch_json "$url")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="WebFetch" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
    )
}

# Helper: run authority-enforce.sh WebSearch with explicit env vars
# Usage: _run_websearch_hook <query> <teammate_command> <role>
_run_websearch_hook() {
    local query="${1:-test query}"
    local teammate_command="${2:-}"
    local role="${3:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_websearch_json "$query")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="WebSearch" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Helper: capture stderr from WebSearch hook
_run_websearch_hook_stderr() {
    local query="${1:-test query}"
    local teammate_command="${2:-}"
    local role="${3:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_websearch_json "$query")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="WebSearch" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
    )
}

# ---------------------------------------------------------------------------
# TC-TWF-1: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebFetch → exit 2
#            with TEAM_MATE_TOOL_DENY in stderr
# CLAUDE_CODE_TEAMMATE_COMMAND is the REAL positive signal (empirically verified 2026-04-19).
# ---------------------------------------------------------------------------
_run_webfetch_hook "https://example.com" "$FAKE_TEAMMATE_CMD" "developer" 2>/dev/null
TWF1_EXIT=$?
TWF1_STDERR=$(_run_webfetch_hook_stderr "https://example.com" "$FAKE_TEAMMATE_CMD" "developer")
TWF1_HAS_KEYWORD=0
echo "$TWF1_STDERR" | grep -qi "TEAM_MATE_TOOL_DENY" && TWF1_HAS_KEYWORD=1 || true

if [ $TWF1_EXIT -eq 2 ] && [ $TWF1_HAS_KEYWORD -eq 1 ]; then
    _pass "TC-TWF-1: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebFetch → exit 2 with TEAM_MATE_TOOL_DENY"
elif [ $TWF1_EXIT -ne 2 ]; then
    _fail "TC-TWF-1: expected exit 2 for team-mode teammate WebFetch" "Got exit $TWF1_EXIT; stderr: $TWF1_STDERR"
else
    _fail "TC-TWF-1: blocked (exit 2) but TEAM_MATE_TOOL_DENY not in stderr" "stderr: $TWF1_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TWF-2: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebSearch → exit 2
#            with TEAM_MATE_TOOL_DENY in stderr
# ---------------------------------------------------------------------------
_run_websearch_hook "test query" "$FAKE_TEAMMATE_CMD" "developer" 2>/dev/null
TWF2_EXIT=$?
TWF2_STDERR=$(_run_websearch_hook_stderr "test query" "$FAKE_TEAMMATE_CMD" "developer")
TWF2_HAS_KEYWORD=0
echo "$TWF2_STDERR" | grep -qi "TEAM_MATE_TOOL_DENY" && TWF2_HAS_KEYWORD=1 || true

if [ $TWF2_EXIT -eq 2 ] && [ $TWF2_HAS_KEYWORD -eq 1 ]; then
    _pass "TC-TWF-2: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + WebSearch → exit 2 with TEAM_MATE_TOOL_DENY"
elif [ $TWF2_EXIT -ne 2 ]; then
    _fail "TC-TWF-2: expected exit 2 for team-mode teammate WebSearch" "Got exit $TWF2_EXIT; stderr: $TWF2_STDERR"
else
    _fail "TC-TWF-2: blocked (exit 2) but TEAM_MATE_TOOL_DENY not in stderr" "stderr: $TWF2_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TWF-3: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebFetch → exit 0 (no false positive)
# Coordinators and subagents do NOT have CLAUDE_CODE_TEAMMATE_COMMAND set.
# ---------------------------------------------------------------------------
_run_webfetch_hook "https://example.com" "" "developer" 2>/dev/null
TWF3_EXIT=$?

if [ $TWF3_EXIT -eq 0 ]; then
    _pass "TC-TWF-3: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebFetch → exit 0 (not blocked)"
else
    _fail "TC-TWF-3: expected exit 0 for non-teammate WebFetch" "Got exit $TWF3_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TWF-4: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebSearch → exit 0 (no false positive)
# ---------------------------------------------------------------------------
_run_websearch_hook "test query" "" "developer" 2>/dev/null
TWF4_EXIT=$?

if [ $TWF4_EXIT -eq 0 ]; then
    _pass "TC-TWF-4: non-teammate (no CLAUDE_CODE_TEAMMATE_COMMAND) + WebSearch → exit 0 (not blocked)"
else
    _fail "TC-TWF-4: expected exit 0 for non-teammate WebSearch" "Got exit $TWF4_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TWF-5: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + WebFetch → exit 0
# Empty string is falsy — should not trigger the teammate block.
# ---------------------------------------------------------------------------
TWF5_EXIT=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND=""
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(_webfetch_json "https://example.com")
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="WebFetch" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>/dev/null; echo $?
)

if [ "$TWF5_EXIT" = "0" ]; then
    _pass "TC-TWF-5: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + WebFetch → exit 0 (empty string is not a teammate indicator)"
else
    _fail "TC-TWF-5: expected exit 0 when CLAUDE_CODE_TEAMMATE_COMMAND is empty string" "Got exit $TWF5_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TWF-6: default session (no teammate env vars at all) + WebFetch → no false-positive TEAM_MATE_TOOL_DENY
# Pins the invariant: block only fires when the real CLAUDE_CODE_TEAMMATE_COMMAND is present.
# ---------------------------------------------------------------------------
TWF6_STDERR=$(
    cd "$FAKE_PROJECT"
    unset CLAUDE_CODE_TEAMMATE_COMMAND CLAUDE_CODE_TEAM_NAME CLAUDE_INTERNAL_ASSISTANT_TEAM_NAME 2>/dev/null || true
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(_webfetch_json "https://example.com")
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="WebFetch" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
)
TWF6_HAS_DENY=0
echo "$TWF6_STDERR" | grep -qi "TEAM_MATE_TOOL_DENY" && TWF6_HAS_DENY=1 || true

if [ $TWF6_HAS_DENY -eq 0 ]; then
    _pass "TC-TWF-6: default session (no teammate env vars) + WebFetch → no false-positive TEAM_MATE_TOOL_DENY"
else
    _fail "TC-TWF-6: TEAM_MATE_TOOL_DENY false-positive for clean default session" "stderr: $TWF6_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TWF-7: team-mode teammate + Read (non-credential path) → no TEAM_MATE_TOOL_DENY
# Confirms the WebFetch/WebSearch block does not affect Read or other tools.
# (Read may still be subject to other gates, but TEAM_MATE_TOOL_DENY must not fire.)
# ---------------------------------------------------------------------------
TARGET_FILE="$FAKE_HOME/.claude/ainous-roles/developer/memory.md"
touch "$TARGET_FILE"
TWF7_STDERR=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND="$FAKE_TEAMMATE_CMD"
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2]}))" \
        "$FAKE_SESSION_ID" "$TARGET_FILE" 2>/dev/null)
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Read" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
)
TWF7_HAS_TOOL_DENY=0
echo "$TWF7_STDERR" | grep -qi "TEAM_MATE_TOOL_DENY" && TWF7_HAS_TOOL_DENY=1 || true

if [ $TWF7_HAS_TOOL_DENY -eq 0 ]; then
    _pass "TC-TWF-7: team-mode teammate + Read → no TEAM_MATE_TOOL_DENY (WebFetch/WebSearch block does not affect Read)"
else
    _fail "TC-TWF-7: TEAM_MATE_TOOL_DENY fired for Read — should only fire for WebFetch/WebSearch" "stderr: $TWF7_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TWF-8: team-mode teammate + Write → exit 2 with TEAM_MATE_WRITE_DENY (existing v5.9.0 block unaffected)
# Regression test: confirm the new block does not interfere with the existing Write block.
# ---------------------------------------------------------------------------
TARGET_FILE="$FAKE_HOME/.claude/ainous-roles/developer/memory.md"
TWF8_STDERR=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND="$FAKE_TEAMMATE_CMD"
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2],'content':'test'}))" \
        "$FAKE_SESSION_ID" "$TARGET_FILE" 2>/dev/null)
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
)
TWF8_EXIT=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND="$FAKE_TEAMMATE_CMD"
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2],'content':'test'}))" \
        "$FAKE_SESSION_ID" "$TARGET_FILE" 2>/dev/null)
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>/dev/null; echo $?
)
TWF8_HAS_WRITE_DENY=0
echo "$TWF8_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TWF8_HAS_WRITE_DENY=1 || true

if [ "$TWF8_EXIT" = "2" ] && [ $TWF8_HAS_WRITE_DENY -eq 1 ]; then
    _pass "TC-TWF-8: team-mode teammate + Write → exit 2 with TEAM_MATE_WRITE_DENY (v5.9.0 block unaffected by new block)"
elif [ "$TWF8_EXIT" != "2" ]; then
    _fail "TC-TWF-8: expected exit 2 for team-mode teammate Write (regression)" "Got exit $TWF8_EXIT"
else
    _fail "TC-TWF-8: exit 2 but TEAM_MATE_WRITE_DENY not in stderr (regression)" "stderr: $TWF8_STDERR"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed (of $((TESTS_PASS + TESTS_FAIL)) tests) — M-new-2 WebFetch/WebSearch teammate block (v5.9.3)"

if [ $TESTS_FAIL -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILURES: $TESTS_FAIL test(s) failed." >&2
    exit 1
fi
