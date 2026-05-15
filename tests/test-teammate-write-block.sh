#!/usr/bin/env bash
# test-teammate-write-block.sh — Test suite for v5.9.0 §15 mechanical enforcement
#
# EMPIRICALLY VERIFIED ENV VARS (2026-04-19 via `strings claude-binary | grep -oE 'CLAUDE_[A-Z_]+'`):
#   CLAUDE_CODE_TEAMMATE_COMMAND — present in binary; only set for real team-mode teammates (positive signal)
#   CLAUDE_CODE_TEAM_NAME       — present in binary; set for team context
#   CLAUDE_INTERNAL_ASSISTANT_TEAM_NAME — present in binary; set for internal team members
#   FABRICATED (not in binary): CLAUDE_TEAM_NAME, CLAUDE_TEAM_ROLE — were our invented names, caused silent dead-code
#
# Tests:
#   TC-TW-1: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Write → blocked (exit 2) with "team-mode" in stderr
#   TC-TW-2: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Edit → blocked (exit 2)
#   TC-TW-3: team-mode teammate + NotebookEdit → exit 0 (NotebookEdit not in authority-enforce.sh shell dispatcher)
#   TC-TW-4: no CLAUDE_CODE_TEAMMATE_COMMAND (coordinator/team-lead context) + Write → exit 0 (not blocked)
#   TC-TW-5: subagent-mode spawn (no CLAUDE_CODE_TEAMMATE_COMMAND) + Write → exit 0 (subagent mode unaffected)
#   TC-TW-6: no spawn context (main session, no CLAUDE_CODE_TEAMMATE_COMMAND) + Write → NOT blocked by TEAM_MATE_WRITE_DENY
#   TC-TW-7: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + Write → exit 0 (falsy, not a teammate marker)
#   TC-TW-8: default session (no teammate env vars at all) + Write → exit 0, no false-positive TEAM_MATE_WRITE_DENY
#
# Run: bash tests/test-teammate-write-block.sh
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
TMPDIR_BASE=$(mktemp -d /tmp/test-teammate-write-block.XXXXXX)
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

FAKE_SESSION_ID="test-session-teammate-block"
# A safe target file within the developer baseline that is NOT a provenance surface.
# journal.md is a provenance surface and requires a provenance block — use memory.md instead,
# which is within .claude/ainous-roles/developer/ and matches the developer baseline but is
# not a provenance-gated surface.
TARGET_FILE="$FAKE_HOME/.claude/ainous-roles/developer/memory.md"

# Nonce setup (needed so _validate_taint_field doesn't fail-closed on missing nonce)
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"
HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$FAKE_SESSION_ID" 2>/dev/null)
NONCE_FILE="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
printf 'deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234' > "$NONCE_FILE"
chmod 600 "$NONCE_FILE"

# Helper: build Write tool JSON input
_write_json() {
    local file_path="$1"
    local content="$2"
    python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2],'content':sys.argv[3]}))" \
        "$FAKE_SESSION_ID" "$file_path" "$content" 2>/dev/null
}

# Helper: run authority-enforce.sh Write with explicit env vars
# Usage: _run_write_hook <file> <content> <teammate_command> <role>
# Pass "" for teammate_command to leave unset (not a teammate).
# REAL env vars (empirically verified 2026-04-19):
#   CLAUDE_CODE_TEAMMATE_COMMAND — positive signal: set only for real team-mode teammates
#   CLAUDE_CODE_TEAM_NAME       — corroborating signal: set for team context
# FABRICATED (not in binary, never set by Claude Code — do NOT use in tests):
#   CLAUDE_TEAM_NAME, CLAUDE_TEAM_ROLE
_run_write_hook() {
    local file_path="$1"
    local content="$2"
    local teammate_command="${3:-}"
    local role="${4:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_write_json "$file_path" "$content")

    (
        cd "$FAKE_PROJECT"
        # Only export CLAUDE_CODE_TEAMMATE_COMMAND if non-empty
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Helper: run authority-enforce.sh Edit with explicit env vars
_run_edit_hook() {
    local file_path="$1"
    local old_string="$2"
    local new_string="$3"
    local teammate_command="${4:-}"
    local role="${5:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(python3 -c "
import json, sys
print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2],'old_string':sys.argv[3],'new_string':sys.argv[4]}))
" "$FAKE_SESSION_ID" "$file_path" "$old_string" "$new_string" 2>/dev/null)

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Edit" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Helper: capture stderr from authority-enforce.sh Write call
_run_write_hook_stderr() {
    local file_path="$1"
    local content="$2"
    local teammate_command="${3:-}"
    local role="${4:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(_write_json "$file_path" "$content")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
    )
}

SAMPLE_CONTENT="# memory content for teammate-write-block tests"

# ---------------------------------------------------------------------------
# TC-TW-1: Team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Write → blocked (exit 2)
#           Verify "team-mode" (or "TEAM_MATE_WRITE_DENY") appears in stderr
#           CLAUDE_CODE_TEAMMATE_COMMAND is the REAL positive signal (empirically verified).
# ---------------------------------------------------------------------------
_run_write_hook "$TARGET_FILE" "$SAMPLE_CONTENT" "claude-code-team-mate-cmd" "developer" 2>/dev/null
TW1_EXIT=$?

TW1_STDERR=$(_run_write_hook_stderr "$TARGET_FILE" "$SAMPLE_CONTENT" "claude-code-team-mate-cmd" "developer")
TW1_HAS_KEYWORD=0
echo "$TW1_STDERR" | grep -qi "team.mode\|TEAM_MATE_WRITE_DENY" && TW1_HAS_KEYWORD=1 || true

if [ $TW1_EXIT -eq 2 ] && [ $TW1_HAS_KEYWORD -eq 1 ]; then
    _pass "TC-TW-1: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Write → blocked (exit 2) with team-mode keyword in stderr"
elif [ $TW1_EXIT -ne 2 ]; then
    _fail "TC-TW-1: expected exit 2 for team-mode teammate Write" "Got exit $TW1_EXIT"
else
    _fail "TC-TW-1: blocked (exit 2) but 'team-mode' keyword not in stderr" "stderr: $TW1_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TW-2: Team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Edit → blocked (exit 2)
# ---------------------------------------------------------------------------
_run_edit_hook "$TARGET_FILE" "# memory content" "# memory content (edited)" "claude-code-team-mate-cmd" "developer" 2>/dev/null
TW2_EXIT=$?

if [ $TW2_EXIT -eq 2 ]; then
    _pass "TC-TW-2: team-mode teammate (CLAUDE_CODE_TEAMMATE_COMMAND set) + Edit → blocked (exit 2)"
else
    _fail "TC-TW-2: expected exit 2 for team-mode teammate Edit" "Got exit $TW2_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TW-3: Team-mode teammate + NotebookEdit → check block
# authority-enforce.sh only handles Write, Edit, Bash, Read — NotebookEdit
# exits 0 via the early pass-through. The TEAM_MATE_WRITE_DENY block checks
# tool in ("Write", "Edit", "NotebookEdit") so if NotebookEdit were to reach
# authority-enforce.sh, it would be blocked. However, the outer shell case
# statement only dispatches Write|Edit|Bash|Read.
# Therefore NotebookEdit PASSES (exit 0) at the shell level — but the Python
# block IS configured to block it. We test the Python-layer behavior by
# injecting TOOL_USE_NAME=NotebookEdit and verifying the gate logic.
# ---------------------------------------------------------------------------
echo "developer" > "$FAKE_HOME/.claude/.session-role"
NE_JSON=$(python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'file_path':sys.argv[2],'content':'test'}))" \
    "$FAKE_SESSION_ID" "$TARGET_FILE" 2>/dev/null)

TW3_EXIT=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND="claude-code-team-mate-cmd"
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="NotebookEdit" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$NE_JSON" 2>/dev/null; echo $?
)
# NotebookEdit is not in the Write|Edit|Bash|Read case — so it exits 0 at shell level.
# The Python layer has "NotebookEdit" in the block check but the shell-level dispatch
# prevents Python from running. Exit 0 is the expected result.
if [ "$TW3_EXIT" = "0" ]; then
    _pass "TC-TW-3: NotebookEdit + team-mode → exit 0 (shell dispatch excludes NotebookEdit from Python path; Python-layer block is a defense-in-depth if dispatch changes)"
else
    _fail "TC-TW-3: unexpected exit $TW3_EXIT for NotebookEdit in team-mode" "expected exit 0 (shell dispatch)"
fi

# ---------------------------------------------------------------------------
# TC-TW-4: No CLAUDE_CODE_TEAMMATE_COMMAND (coordinator context) + Write → exit 0 (not blocked)
# Coordinators/team-leads do NOT have CLAUDE_CODE_TEAMMATE_COMMAND set (empirically verified).
# The old CLAUDE_TEAM_ROLE=team-lead exemption was a fabricated var — dropped in v5.9.0 patch.
# ---------------------------------------------------------------------------
_run_write_hook "$TARGET_FILE" "$SAMPLE_CONTENT" "" "developer" 2>/dev/null
TW4_EXIT=$?

if [ $TW4_EXIT -eq 0 ]; then
    _pass "TC-TW-4: coordinator (no CLAUDE_CODE_TEAMMATE_COMMAND) + Write → exit 0 (not a teammate, not blocked)"
else
    _fail "TC-TW-4: expected exit 0 for coordinator Write (no CLAUDE_CODE_TEAMMATE_COMMAND)" "Got exit $TW4_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TW-5: Subagent-mode spawn (CLAUDE_CODE_TEAMMATE_COMMAND NOT set) + Write → exit 0
# Subagent spawns (Agent(subagent_type=...) without team_name) are unaffected.
# ---------------------------------------------------------------------------
_run_write_hook "$TARGET_FILE" "$SAMPLE_CONTENT" "" "developer" 2>/dev/null
TW5_EXIT=$?

if [ $TW5_EXIT -eq 0 ]; then
    _pass "TC-TW-5: subagent-mode spawn (no CLAUDE_CODE_TEAMMATE_COMMAND) + Write → exit 0 (unaffected)"
else
    _fail "TC-TW-5: expected exit 0 for subagent Write (no CLAUDE_CODE_TEAMMATE_COMMAND set)" "Got exit $TW5_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TW-6: No spawn context (main session, no CLAUDE_CODE_TEAMMATE_COMMAND) + Write →
#           not blocked by TEAM_MATE_WRITE_DENY gate.
# We test this by running with developer role (no teammate env) and capturing
# stderr — it must NOT contain "TEAM_MATE_WRITE_DENY" regardless of other outcomes.
# ---------------------------------------------------------------------------
_run_write_hook "$TARGET_FILE" "$SAMPLE_CONTENT" "" "developer" 2>/dev/null
TW6_EXIT=$?

TW6_STDERR=$(_run_write_hook_stderr "$TARGET_FILE" "$SAMPLE_CONTENT" "" "developer")
TW6_HAS_TEAMMATE_DENY=0
echo "$TW6_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TW6_HAS_TEAMMATE_DENY=1 || true

if [ $TW6_HAS_TEAMMATE_DENY -eq 0 ]; then
    _pass "TC-TW-6: no spawn context (no CLAUDE_CODE_TEAMMATE_COMMAND) + Write → NOT blocked by TEAM_MATE_WRITE_DENY (main session unaffected; exit=$TW6_EXIT from other gates is irrelevant)"
else
    _fail "TC-TW-6: TEAM_MATE_WRITE_DENY fired for a non-team-mode session (should not trigger)" \
        "stderr: $TW6_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TW-7: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + Write → exit 0
# Empty CLAUDE_CODE_TEAMMATE_COMMAND is falsy; should not trigger the teammate block.
# ---------------------------------------------------------------------------
TW7_EXIT=$(
    cd "$FAKE_PROJECT"
    export CLAUDE_CODE_TEAMMATE_COMMAND=""
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(_write_json "$TARGET_FILE" "$SAMPLE_CONTENT")
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>/dev/null; echo $?
)

if [ "$TW7_EXIT" = "0" ]; then
    _pass "TC-TW-7: CLAUDE_CODE_TEAMMATE_COMMAND='' (empty string) + Write → exit 0 (empty string is not a teammate indicator)"
else
    _fail "TC-TW-7: expected exit 0 when CLAUDE_CODE_TEAMMATE_COMMAND is empty string" "Got exit $TW7_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TW-8: Default session — no teammate env vars set at all — Write → no false-positive
# This pins the invariant: defense only fires when the real CLAUDE_CODE_TEAMMATE_COMMAND
# marker is present. Env is completely clean of both real and fabricated teammate vars.
# Empirical basis: CLAUDE_TEAM_NAME/CLAUDE_TEAM_ROLE were fabricated (not in binary),
# so unsetting them is the correct default state for a non-team session.
# ---------------------------------------------------------------------------
TW8_EXIT=$(
    cd "$FAKE_PROJECT"
    unset CLAUDE_CODE_TEAMMATE_COMMAND CLAUDE_CODE_TEAM_NAME CLAUDE_INTERNAL_ASSISTANT_TEAM_NAME 2>/dev/null || true
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(_write_json "$TARGET_FILE" "$SAMPLE_CONTENT")
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>/dev/null; echo $?
)
TW8_STDERR=$(
    cd "$FAKE_PROJECT"
    unset CLAUDE_CODE_TEAMMATE_COMMAND CLAUDE_CODE_TEAM_NAME CLAUDE_INTERNAL_ASSISTANT_TEAM_NAME 2>/dev/null || true
    unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
    json_input=$(_write_json "$TARGET_FILE" "$SAMPLE_CONTENT")
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
)
TW8_HAS_DENY=0
echo "$TW8_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TW8_HAS_DENY=1 || true

if [ $TW8_HAS_DENY -eq 0 ]; then
    _pass "TC-TW-8: default session (no teammate env vars at all) + Write → no false-positive TEAM_MATE_WRITE_DENY (exit=$TW8_EXIT; empirical invariant pinned)"
else
    _fail "TC-TW-8: TEAM_MATE_WRITE_DENY false-positive on clean session (no teammate env vars)" \
        "stderr: $TW8_STDERR"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed (of $((TESTS_PASS + TESTS_FAIL)) tests) — env-var fix: CLAUDE_CODE_TEAMMATE_COMMAND (empirically verified 2026-04-19)"

if [ $TESTS_FAIL -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILURES: $TESTS_FAIL test(s) failed." >&2
    exit 1
fi
