#!/usr/bin/env bash
# test-spawn-telemetry.sh — Test suite for hooks/spawn-telemetry (Phase 3a / v5.4.0)
#
# TC-ST-1: ainous-team:developer → role=developer, source=hook-auto, schema/ts/session_id correct
# TC-ST-2: team_name + name fields → spawn_mode=team_name, teammate_name/team_name populated
# TC-ST-3: subagent_type without ainous-team: prefix → role logged as-is
# TC-ST-4: malformed JSON envelope → exit 0, error in .spawn-telemetry-errors.log, no history write
# TC-ST-5: empty CLAUDE_SESSION_ID → session_id is empty string (not "UNKNOWN")
# TC-ST-6 (C1): session-start warns on zero spawn events in last 7 days
#
# Run: bash tests/test-spawn-telemetry.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/spawn-telemetry"
SESSION_START="$PROJECT_ROOT/hooks/session-start"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-spawn-telemetry.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"
TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
ERROR_LOG="$FAKE_HOME/.claude/.spawn-telemetry-errors.log"

mkdir -p "$FAKE_HOME/.claude"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles"

# Helper: build a PostToolUse payload JSON (injects session_id into JSON body)
_make_payload() {
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sid = sys.argv[2] if len(sys.argv) > 2 else ''
print(json.dumps({'tool_name': 'Agent', 'tool_input': d, 'session_id': sid}))
" "$1" "${2:-}"
}

# Helper: run hook with given tool_input JSON object string, optional session_id
_run_hook() {
    local tool_input_json="$1"
    local session_id="${2:-test-session-123}"
    local payload
    payload=$(_make_payload "$tool_input_json" "$session_id")

    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="$session_id" \
        bash "$HOOK" <<< "$payload" 2>/dev/null
    )
    return $?
}

# ---------------------------------------------------------------------------
# TC-ST-1: ainous-team:developer → role=developer, source=hook-auto, schema=1
# ---------------------------------------------------------------------------
rm -f "$TASK_HISTORY" "$ERROR_LOG"
_run_hook '{"subagent_type":"ainous-team:developer","prompt":"do the thing"}'
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    _fail "TC-ST-1: hook exit code" "Got exit $EXIT_CODE"
else
    if [ ! -f "$TASK_HISTORY" ]; then
        _fail "TC-ST-1: task-history.jsonl not created" "File missing"
    else
        # Select the spawn event explicitly (spawn-telemetry now also appends a subagent-outcome line)
        SPAWN_LINE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                d = json.loads(line)
                if d.get('event') == 'spawn':
                    print(line)
                    break
            except Exception:
                pass
" "$TASK_HISTORY" 2>/dev/null || echo "")
        LAST_LINE="$SPAWN_LINE"
        ROLE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('role',''))" "$LAST_LINE" 2>/dev/null || echo "")
        SOURCE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('source',''))" "$LAST_LINE" 2>/dev/null || echo "")
        SCHEMA=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('schema',''))" "$LAST_LINE" 2>/dev/null || echo "")
        SID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('session_id',''))" "$LAST_LINE" 2>/dev/null || echo "")
        EVENT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('event',''))" "$LAST_LINE" 2>/dev/null || echo "")

        if [ "$ROLE" = "developer" ] && [ "$SOURCE" = "hook-auto" ] && [ "$SCHEMA" = "1" ] && [ "$SID" = "test-session-123" ] && [ "$EVENT" = "spawn" ]; then
            _pass "TC-ST-1: ainous-team:developer → role=developer source=hook-auto schema=1"
        else
            _fail "TC-ST-1: field mismatch" "role=$ROLE source=$SOURCE schema=$SCHEMA session_id=$SID event=$EVENT"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TC-ST-2: team_name + name → spawn_mode=team_name, teammate_name/team_name set
# ---------------------------------------------------------------------------
rm -f "$TASK_HISTORY"
_run_hook '{"subagent_type":"ainous-team:developer","name":"alice","team_name":"foo","run_in_background":true,"prompt":"work"}'
# Select the spawn event explicitly (spawn-telemetry now also appends a subagent-outcome line)
ST2_SPAWN_LINE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                d = json.loads(line)
                if d.get('event') == 'spawn':
                    print(line)
                    break
            except Exception:
                pass
" "$TASK_HISTORY" 2>/dev/null || echo "{}")
LAST_LINE="$ST2_SPAWN_LINE"
SPAWN_MODE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('spawn_mode',''))" "$LAST_LINE" 2>/dev/null || echo "")
TN=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('teammate_name',''))" "$LAST_LINE" 2>/dev/null || echo "")
TEAM=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('team_name',''))" "$LAST_LINE" 2>/dev/null || echo "")
BG=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('background',''))" "$LAST_LINE" 2>/dev/null || echo "")

if [ "$SPAWN_MODE" = "team_name" ] && [ "$TN" = "alice" ] && [ "$TEAM" = "foo" ] && [ "$BG" = "True" ]; then
    _pass "TC-ST-2: team_name present → spawn_mode=team_name, teammate_name=alice, team_name=foo"
else
    _fail "TC-ST-2: field mismatch" "spawn_mode=$SPAWN_MODE teammate_name=$TN team_name=$TEAM background=$BG"
fi

# ---------------------------------------------------------------------------
# TC-ST-3: subagent_type without ainous-team: prefix → logged as-is
# ---------------------------------------------------------------------------
rm -f "$TASK_HISTORY"
_run_hook '{"subagent_type":"general-purpose","prompt":"help"}'
LAST_LINE=$(tail -1 "$TASK_HISTORY" 2>/dev/null || echo "{}")
ROLE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('role',''))" "$LAST_LINE" 2>/dev/null || echo "")

if [ "$ROLE" = "general-purpose" ]; then
    _pass "TC-ST-3: non-ainous-team subagent_type logged as-is"
else
    _fail "TC-ST-3: expected role=general-purpose" "Got role=$ROLE"
fi

# ---------------------------------------------------------------------------
# TC-ST-4: Malformed JSON → exit 0, error logged, no history append
# ---------------------------------------------------------------------------
rm -f "$TASK_HISTORY" "$ERROR_LOG"
HISTORY_BEFORE_SIZE=0
MALFORMED="{not valid json at all"
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-123" \
    bash "$HOOK" <<< "$MALFORMED" 2>/dev/null
)
EXIT_CODE=$?
HISTORY_AFTER_SIZE=0
[ -f "$TASK_HISTORY" ] && HISTORY_AFTER_SIZE=$(wc -c < "$TASK_HISTORY" 2>/dev/null || echo "0")
ERROR_LOGGED=0
[ -f "$ERROR_LOG" ] && [ -s "$ERROR_LOG" ] && ERROR_LOGGED=1

if [ $EXIT_CODE -eq 0 ] && [ "$HISTORY_AFTER_SIZE" -eq 0 ] && [ $ERROR_LOGGED -eq 1 ]; then
    _pass "TC-ST-4: malformed JSON → exit 0, error logged, no history append"
else
    _fail "TC-ST-4: malformed JSON handling" "exit=$EXIT_CODE history_size=$HISTORY_AFTER_SIZE error_logged=$ERROR_LOGGED"
fi

# ---------------------------------------------------------------------------
# TC-ST-5: Empty CLAUDE_SESSION_ID → session_id is empty string (not "UNKNOWN")
# ---------------------------------------------------------------------------
rm -f "$TASK_HISTORY"
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="" \
    bash "$HOOK" <<< '{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:tester","prompt":"t"}}' 2>/dev/null
)
LAST_LINE=$(tail -1 "$TASK_HISTORY" 2>/dev/null || echo "{}")
SID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(repr(d.get('session_id','MISSING')))" "$LAST_LINE" 2>/dev/null || echo "MISSING")

if [ "$SID" = "''" ]; then
    _pass "TC-ST-5: empty CLAUDE_SESSION_ID → session_id is empty string"
else
    _fail "TC-ST-5: session_id should be empty string" "Got $SID"
fi

# ---------------------------------------------------------------------------
# TC-ST-6 (C1): session-start warns on zero spawn events in last 7 days
# ---------------------------------------------------------------------------
# Create a minimal ainous-team project layout with empty/no task-history
C1_HOME="$TMPDIR_BASE/c1-home"
C1_PROJECT="$TMPDIR_BASE/c1-project"
mkdir -p "$C1_HOME/.claude"
mkdir -p "$C1_PROJECT/.claude/ainous-roles/team-sync/state"
# task-history.jsonl exists but has no spawn events (only a skill-invoked)
echo '{"event":"skill-invoked","role":"developer","skill":"tdd","source":"hook-auto"}' > \
    "$C1_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"

STDERR_OUTPUT=$(
    cd "$C1_PROJECT"
    HOME="$C1_HOME" \
    CLAUDE_PROJECT_DIR="$C1_PROJECT" \
    CLAUDE_SESSION_ID="c1-test-session" \
    bash "$SESSION_START" 2>&1 1>/dev/null
)

if [ -n "$STDERR_OUTPUT" ]; then
    _pass "TC-ST-6: session-start emits warning on zero spawn events (non-empty stderr)"
else
    _fail "TC-ST-6: expected non-empty stderr warning from session-start" "Got empty stderr"
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
