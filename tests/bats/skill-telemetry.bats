#!/usr/bin/env bats
# skill-telemetry.bats — Tests for hooks/skill-telemetry and session-end aggregation
#
# Coverage:
#   Test 1: hook emits correct event for Skill tool invocation
#   Test 2: hook emits correct event for Agent tool invocation with subagent_type
#   Test 3: hook falls back to "unknown" role when no role marker exists
#   Test 4: hook is fail-open — malformed stdin exits 0
#   Test 5: session-end aggregation appends skills_invoked correctly
#   Test 6: session-end fail-open — missing task-history.jsonl does not error
#
# Run: bats tests/bats/skill-telemetry.bats
# Exit 0 = all tests pass.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/skill-telemetry"
SESSION_END="$PROJECT_ROOT/hooks/session-end"

setup() {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    FAKE_PROJECT="$BATS_TEST_TMPDIR/project"

    mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"

    # Default role marker
    printf 'developer\n' > "$FAKE_HOME/.claude/.session-role"

    TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
}

teardown() {
    : # bats-core cleans BATS_TEST_TMPDIR
}

# ---------------------------------------------------------------------------
# Helper: invoke skill-telemetry hook with a JSON payload
# ---------------------------------------------------------------------------
_invoke_telemetry() {
    local json_input="$1"
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="test-session-123" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
}

# ---------------------------------------------------------------------------
# Helper: invoke session-end hook
# ---------------------------------------------------------------------------
_invoke_session_end() {
    local session_id="${1:-test-session-123}"
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="$session_id" \
        bash "$SESSION_END" 2>/dev/null
    )
}

# ---------------------------------------------------------------------------
# Test 1: Skill tool invocation emits correct event
# ---------------------------------------------------------------------------
@test "Test 1: Skill tool emits skill-invoked event with correct fields" {
    local payload
    payload='{"tool_name":"Skill","tool_input":{"skill":"defensive-coding"},"session_id":"test-session-123"}'

    run _invoke_telemetry "$payload"
    [ "$status" -eq 0 ]

    # Event should be in task-history.jsonl
    [ -f "$TASK_HISTORY" ]

    # Parse the emitted event
    local event
    event=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        ev = json.loads(line.strip())
        if ev.get('event') == 'skill-invoked':
            print(json.dumps(ev))
            break
" "$TASK_HISTORY")

    [ -n "$event" ]

    # Verify required fields
    python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
assert ev['event']  == 'skill-invoked',   f'event: {ev[\"event\"]}'
assert ev['skill']  == 'defensive-coding', f'skill: {ev[\"skill\"]}'
assert ev['tool']   == 'Skill',           f'tool: {ev[\"tool\"]}'
assert ev['source'] == 'hook-auto',       f'source: {ev[\"source\"]}'
assert ev['role']   == 'developer',       f'role: {ev[\"role\"]}'
assert 'timestamp'  in ev,                'missing timestamp'
assert 'session'    in ev,                'missing session'
assert 'session_id' in ev,                'missing session_id'
" "$event"
}

# ---------------------------------------------------------------------------
# Test 2: Agent tool invocation emits correct event with subagent_type
# ---------------------------------------------------------------------------
@test "Test 2: Agent tool emits skill-invoked event with subagent_type as skill" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"fix the bug"},"session_id":"test-session-123"}'

    run _invoke_telemetry "$payload"
    [ "$status" -eq 0 ]

    [ -f "$TASK_HISTORY" ]

    local event
    event=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        ev = json.loads(line.strip())
        if ev.get('event') == 'skill-invoked':
            print(json.dumps(ev))
            break
" "$TASK_HISTORY")

    [ -n "$event" ]

    python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
assert ev['event']  == 'skill-invoked',             f'event: {ev[\"event\"]}'
assert ev['skill']  == 'ainous-team:developer',     f'skill: {ev[\"skill\"]}'
assert ev['tool']   == 'Agent',                      f'tool: {ev[\"tool\"]}'
assert ev['source'] == 'hook-auto',                  f'source: {ev[\"source\"]}'
assert ev['role']   == 'developer',                  f'role: {ev[\"role\"]}'
" "$event"
}

# ---------------------------------------------------------------------------
# Test 3: No role marker present → role falls back to "unknown", no crash
# ---------------------------------------------------------------------------
@test "Test 3: Missing role marker falls back to unknown role, exit 0" {
    # Remove both role markers
    rm -f "$FAKE_HOME/.claude/.session-role"
    rm -f "$FAKE_HOME/.claude/.session-role-"*  2>/dev/null || true

    local payload
    payload='{"tool_name":"Skill","tool_input":{"skill":"some-skill"},"session_id":"test-session-123"}'

    run _invoke_telemetry "$payload"
    [ "$status" -eq 0 ]

    # Event should still be written with role=unknown
    if [ -f "$TASK_HISTORY" ]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        ev = json.loads(line)
        if ev.get('event') == 'skill-invoked':
            assert ev['role'] == 'unknown', f'expected unknown, got {ev[\"role\"]}'
            break
" "$TASK_HISTORY"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: Malformed stdin — hook is fail-open, exits 0
# ---------------------------------------------------------------------------
@test "Test 4: Malformed stdin exits 0 (fail-open)" {
    run _invoke_telemetry "this is not json {{{"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: session-end aggregation appends skills_invoked to growth.json
# ---------------------------------------------------------------------------
@test "Test 5: session-end aggregation writes skills_invoked to growth.json" {
    local session_id="test-session-agg"

    # Pre-populate task-history.jsonl with hook-auto events for this session
    python3 -c "
import json, sys
from datetime import datetime, timezone
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
events = [
    {'timestamp': '2026-04-17T10:00:00Z', 'event': 'skill-invoked', 'role': 'developer',
     'skill': 'defensive-coding', 'tool': 'Skill', 'session': today,
     'session_id': sys.argv[1], 'source': 'hook-auto'},
    {'timestamp': '2026-04-17T10:01:00Z', 'event': 'skill-invoked', 'role': 'developer',
     'skill': 'tdd-workflow', 'tool': 'Skill', 'session': today,
     'session_id': sys.argv[1], 'source': 'hook-auto'},
]
path = sys.argv[2]
with open(path, 'w') as f:
    for ev in events:
        f.write(json.dumps(ev) + '\n')
" "$session_id" "$TASK_HISTORY"

    # Create a growth.json with an existing session entry
    python3 -c "
import json, sys
growth = {
    'trust': {'level': 'senior'},
    'sessions': [
        {'date': '2026-04-17', 'skills_invoked': [], 'sessions_completed': 1}
    ]
}
with open(sys.argv[1], 'w') as f:
    json.dump(growth, f, indent=2)
" "$FAKE_HOME/.claude/ainous-roles/developer/growth.json"

    run _invoke_session_end "$session_id"
    [ "$status" -eq 0 ]

    # Verify skills_invoked was populated
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    growth = json.load(f)
sessions = growth.get('sessions', [])
assert sessions, 'no sessions in growth.json'
latest = sessions[-1]
skills = sorted(latest.get('skills_invoked', []))
expected = ['defensive-coding', 'tdd-workflow']
assert skills == expected, f'expected {expected}, got {skills}'
" "$FAKE_HOME/.claude/ainous-roles/developer/growth.json"
}

# ---------------------------------------------------------------------------
# Test 6: session-end fail-open — missing task-history.jsonl does not error
# ---------------------------------------------------------------------------
@test "Test 6: session-end with missing task-history.jsonl exits 0" {
    # Ensure no task-history.jsonl exists
    rm -f "$TASK_HISTORY"

    run _invoke_session_end "test-session-missing"
    [ "$status" -eq 0 ]
}
