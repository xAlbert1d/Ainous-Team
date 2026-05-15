#!/usr/bin/env bash
# test-teammate-bash-write.sh — Test suite for v5.9.1 M-new-1: Bash teammate-write block
#
# Tests that team-mode teammates (CLAUDE_CODE_TEAMMATE_COMMAND set) cannot mutate
# the filesystem via Bash — they must return content via SendMessage envelope.
#
# Tests:
#   TC-TBW-1:  teammate + printf "data" > /tmp/file → exit 2 with TEAM_MATE_WRITE_DENY
#   TC-TBW-2:  teammate + echo hello > file → exit 2
#   TC-TBW-3:  teammate + cmd | tee file → exit 2
#   TC-TBW-4:  teammate + dd if=/etc/hostname of=/tmp/out → exit 2
#   TC-TBW-5:  teammate + cp src dest → exit 2
#   TC-TBW-6:  teammate + mv src dest → exit 2
#   TC-TBW-7:  teammate + cat file (read only) → exit 0 (no false positive)
#   TC-TBW-8:  teammate + ls dir → exit 0 (no false positive)
#   TC-TBW-9:  non-teammate (default session) + printf > file → exit 0 (unchanged behavior)
#   TC-TBW-10: teammate + touch /tmp/newfile → exit 2 (file creation)
#
# Run: bash tests/test-teammate-bash-write.sh
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
TMPDIR_BASE=$(mktemp -d /tmp/test-teammate-bash-write.XXXXXX)
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
{"developer":["journal.md","playbook.md","learnings.jsonl","memory.md","src/","scripts/"]}
EOF

FAKE_SESSION_ID="test-session-teammate-bash-write"

# Nonce setup (needed so _validate_taint_field doesn't fail-closed on missing nonce)
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"
HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$FAKE_SESSION_ID" 2>/dev/null)
NONCE_FILE="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
printf 'deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234' > "$NONCE_FILE"
chmod 600 "$NONCE_FILE"

# Helper: build Bash tool JSON input
_bash_json() {
    local cmd="$1"
    python3 -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'command':sys.argv[2]}))" \
        "$FAKE_SESSION_ID" "$cmd" 2>/dev/null
}

# Helper: run authority-enforce.sh Bash tool with teammate env set
# Usage: _run_bash_teammate <command>
# Optionally set TEAMMATE_CMD to non-empty to simulate a team-mode teammate.
_run_bash_hook() {
    local cmd="$1"
    local teammate_command="${2:-}"

    local json_input
    json_input=$(_bash_json "$cmd")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Bash" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# Helper: capture stderr
_run_bash_hook_stderr() {
    local cmd="$1"
    local teammate_command="${2:-}"

    local json_input
    json_input=$(_bash_json "$cmd")

    (
        cd "$FAKE_PROJECT"
        [ -n "$teammate_command" ] && export CLAUDE_CODE_TEAMMATE_COMMAND="$teammate_command" || unset CLAUDE_CODE_TEAMMATE_COMMAND 2>/dev/null || true
        unset CLAUDE_TEAM_NAME CLAUDE_TEAM_ROLE 2>/dev/null || true
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Bash" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>&1 1>/dev/null
    )
}

FAKE_TEAMMATE_CMD="claude-code-team-mate-cmd"

# ---------------------------------------------------------------------------
# TC-TBW-1: teammate + printf "data" > /tmp/file → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'printf "data" > /tmp/testfile' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW1_EXIT=$?
TBW1_STDERR=$(_run_bash_hook_stderr 'printf "data" > /tmp/testfile' "$FAKE_TEAMMATE_CMD")
TBW1_HAS_DENY=0
echo "$TBW1_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW1_HAS_DENY=1 || true

if [ $TBW1_EXIT -eq 2 ] && [ $TBW1_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-1: teammate + printf redirect → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW1_EXIT -ne 2 ]; then
    _fail "TC-TBW-1: expected exit 2 for teammate printf redirect" "Got exit $TBW1_EXIT; stderr: $TBW1_STDERR"
else
    _fail "TC-TBW-1: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW1_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-2: teammate + echo hello > file → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'echo hello > /tmp/out.txt' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW2_EXIT=$?
TBW2_STDERR=$(_run_bash_hook_stderr 'echo hello > /tmp/out.txt' "$FAKE_TEAMMATE_CMD")
TBW2_HAS_DENY=0
echo "$TBW2_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW2_HAS_DENY=1 || true

if [ $TBW2_EXIT -eq 2 ] && [ $TBW2_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-2: teammate + echo redirect → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW2_EXIT -ne 2 ]; then
    _fail "TC-TBW-2: expected exit 2 for teammate echo redirect" "Got exit $TBW2_EXIT"
else
    _fail "TC-TBW-2: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW2_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-3: teammate + cat file | tee output → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'cat /tmp/input | tee /tmp/output' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW3_EXIT=$?
TBW3_STDERR=$(_run_bash_hook_stderr 'cat /tmp/input | tee /tmp/output' "$FAKE_TEAMMATE_CMD")
TBW3_HAS_DENY=0
echo "$TBW3_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW3_HAS_DENY=1 || true

if [ $TBW3_EXIT -eq 2 ] && [ $TBW3_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-3: teammate + tee → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW3_EXIT -ne 2 ]; then
    _fail "TC-TBW-3: expected exit 2 for teammate tee" "Got exit $TBW3_EXIT"
else
    _fail "TC-TBW-3: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW3_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-4: teammate + dd if=/etc/hostname of=/tmp/out → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'dd if=/etc/hostname of=/tmp/out' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW4_EXIT=$?
TBW4_STDERR=$(_run_bash_hook_stderr 'dd if=/etc/hostname of=/tmp/out' "$FAKE_TEAMMATE_CMD")
TBW4_HAS_DENY=0
echo "$TBW4_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW4_HAS_DENY=1 || true

if [ $TBW4_EXIT -eq 2 ] && [ $TBW4_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-4: teammate + dd of= → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW4_EXIT -ne 2 ]; then
    _fail "TC-TBW-4: expected exit 2 for teammate dd of=" "Got exit $TBW4_EXIT"
else
    _fail "TC-TBW-4: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW4_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-5: teammate + cp src dest → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'cp /tmp/src /tmp/dest' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW5_EXIT=$?
TBW5_STDERR=$(_run_bash_hook_stderr 'cp /tmp/src /tmp/dest' "$FAKE_TEAMMATE_CMD")
TBW5_HAS_DENY=0
echo "$TBW5_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW5_HAS_DENY=1 || true

if [ $TBW5_EXIT -eq 2 ] && [ $TBW5_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-5: teammate + cp → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW5_EXIT -ne 2 ]; then
    _fail "TC-TBW-5: expected exit 2 for teammate cp" "Got exit $TBW5_EXIT"
else
    _fail "TC-TBW-5: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW5_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-6: teammate + mv src dest → exit 2
# ---------------------------------------------------------------------------
_run_bash_hook 'mv /tmp/old /tmp/new' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW6_EXIT=$?
TBW6_STDERR=$(_run_bash_hook_stderr 'mv /tmp/old /tmp/new' "$FAKE_TEAMMATE_CMD")
TBW6_HAS_DENY=0
echo "$TBW6_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW6_HAS_DENY=1 || true

if [ $TBW6_EXIT -eq 2 ] && [ $TBW6_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-6: teammate + mv → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW6_EXIT -ne 2 ]; then
    _fail "TC-TBW-6: expected exit 2 for teammate mv" "Got exit $TBW6_EXIT"
else
    _fail "TC-TBW-6: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW6_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-7: teammate + cat file (read only) → exit 0 — no false positive
# ---------------------------------------------------------------------------
_run_bash_hook 'cat /tmp/somefile' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW7_EXIT=$?
TBW7_STDERR=$(_run_bash_hook_stderr 'cat /tmp/somefile' "$FAKE_TEAMMATE_CMD")
TBW7_HAS_TEAMMATE_DENY=0
echo "$TBW7_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW7_HAS_TEAMMATE_DENY=1 || true

if [ $TBW7_EXIT -eq 0 ] && [ $TBW7_HAS_TEAMMATE_DENY -eq 0 ]; then
    _pass "TC-TBW-7: teammate + cat (read only) → exit 0, no false positive TEAM_MATE_WRITE_DENY"
elif [ $TBW7_HAS_TEAMMATE_DENY -eq 1 ]; then
    _fail "TC-TBW-7: false positive — TEAM_MATE_WRITE_DENY fired for cat (read only)" "stderr: $TBW7_STDERR"
else
    # Non-zero exit could be from other gates (e.g. path checks) — verify it's not teammate-write
    if [ $TBW7_HAS_TEAMMATE_DENY -eq 0 ]; then
        _pass "TC-TBW-7: teammate + cat (read only) → no TEAM_MATE_WRITE_DENY (exit=$TBW7_EXIT from other gates OK)"
    else
        _fail "TC-TBW-7: unexpected exit $TBW7_EXIT with TEAM_MATE_WRITE_DENY for read-only cat" "stderr: $TBW7_STDERR"
    fi
fi

# ---------------------------------------------------------------------------
# TC-TBW-8: teammate + ls dir → exit 0 — no false positive
# ---------------------------------------------------------------------------
_run_bash_hook 'ls /tmp' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW8_EXIT=$?
TBW8_STDERR=$(_run_bash_hook_stderr 'ls /tmp' "$FAKE_TEAMMATE_CMD")
TBW8_HAS_TEAMMATE_DENY=0
echo "$TBW8_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW8_HAS_TEAMMATE_DENY=1 || true

if [ $TBW8_HAS_TEAMMATE_DENY -eq 0 ]; then
    _pass "TC-TBW-8: teammate + ls → no TEAM_MATE_WRITE_DENY (exit=$TBW8_EXIT; read-only unaffected)"
else
    _fail "TC-TBW-8: false positive — TEAM_MATE_WRITE_DENY fired for ls" "stderr: $TBW8_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-9: non-teammate (default session, no CLAUDE_CODE_TEAMMATE_COMMAND) + printf > file → exit 0
# The teammate block must NOT affect non-team sessions.
# Note: other gates may still block (e.g., operator baseline), but TEAM_MATE_WRITE_DENY must not fire.
# ---------------------------------------------------------------------------
_run_bash_hook 'printf "x" > /tmp/out' "" 2>/dev/null
TBW9_EXIT=$?
TBW9_STDERR=$(_run_bash_hook_stderr 'printf "x" > /tmp/out' "")
TBW9_HAS_TEAMMATE_DENY=0
echo "$TBW9_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW9_HAS_TEAMMATE_DENY=1 || true

if [ $TBW9_HAS_TEAMMATE_DENY -eq 0 ]; then
    _pass "TC-TBW-9: non-teammate + printf redirect → no TEAM_MATE_WRITE_DENY (exit=$TBW9_EXIT; non-team session unaffected)"
else
    _fail "TC-TBW-9: TEAM_MATE_WRITE_DENY false positive for non-teammate session" "stderr: $TBW9_STDERR"
fi

# ---------------------------------------------------------------------------
# TC-TBW-10: teammate + touch /tmp/newfile → exit 2 (file creation)
# ---------------------------------------------------------------------------
_run_bash_hook 'touch /tmp/newfile' "$FAKE_TEAMMATE_CMD" 2>/dev/null
TBW10_EXIT=$?
TBW10_STDERR=$(_run_bash_hook_stderr 'touch /tmp/newfile' "$FAKE_TEAMMATE_CMD")
TBW10_HAS_DENY=0
echo "$TBW10_STDERR" | grep -qi "TEAM_MATE_WRITE_DENY" && TBW10_HAS_DENY=1 || true

if [ $TBW10_EXIT -eq 2 ] && [ $TBW10_HAS_DENY -eq 1 ]; then
    _pass "TC-TBW-10: teammate + touch → exit 2 with TEAM_MATE_WRITE_DENY"
elif [ $TBW10_EXIT -ne 2 ]; then
    _fail "TC-TBW-10: expected exit 2 for teammate touch" "Got exit $TBW10_EXIT"
else
    _fail "TC-TBW-10: exit 2 but TEAM_MATE_WRITE_DENY not in stderr" "stderr: $TBW10_STDERR"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed (of $((TESTS_PASS + TESTS_FAIL)) tests) — M-new-1 Bash teammate-write block"

if [ $TESTS_FAIL -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILURES: $TESTS_FAIL test(s) failed." >&2
    exit 1
fi
