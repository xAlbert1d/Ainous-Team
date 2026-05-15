#!/usr/bin/env bats
# event-schema.bats — Tests for scripts/log-event.sh (PR 5b: session-log schema)
#
# Coverage (7 cases per architect test plan):
#   1. Valid spawn event → well-formed JSONL with schema:"1"
#   2. Missing required field in enforce mode → exit 2, nothing appended
#   3. Invalid enum value in enforce mode → exit 2
#   4. Old-format line (no schema field) is still readable by grep-based reader
#   5. Warn mode: invalid event → exit 0, warn logged, event still appended
#   6. Skill-telemetry hook path → emitted event matches skill-invoked schema
#   7. Pre-existing malformed JSONL lines → reader tolerates (regression check)
#
# Run: bats tests/bats/event-schema.bats
# Exit 0 = all tests pass.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LOG_EVENT="$PROJECT_ROOT/scripts/log-event.sh"
SKILL_TELEMETRY="$PROJECT_ROOT/hooks/skill-telemetry"

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------
setup() {
    FAKE_PROJECT="$BATS_TEST_TMPDIR/project"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"

    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"
    mkdir -p "$FAKE_HOME/.claude"

    # Symlink schemas so log-event.sh can find them
    ln -s "$PROJECT_ROOT/schemas" "$FAKE_PROJECT/schemas"
    # Symlink scripts dir (needed when log-event calls itself for hook test)
    ln -s "$PROJECT_ROOT/scripts" "$FAKE_PROJECT/scripts"

    TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
    TELEMETRY_LOG="$FAKE_HOME/.claude/ainous-team-telemetry.log"

    printf 'developer\n' > "$FAKE_HOME/.claude/.session-role"
}

teardown() {
    : # bats-core cleans BATS_TEST_TMPDIR
}

# ---------------------------------------------------------------------------
# Helper: invoke log-event.sh within the fake project context
# ---------------------------------------------------------------------------
_log_event() {
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$LOG_EVENT" "$@"
    )
}

# ---------------------------------------------------------------------------
# Test 1: Valid spawn event writes well-formed JSONL with schema:"1"
# ---------------------------------------------------------------------------
@test "Test 1: valid spawn event appends well-formed JSONL with schema:1" {
    run _log_event spawn role=developer phase=implement detail=test scope=src/,tests/ mode=agent

    [ "$status" -eq 0 ]
    [ -f "$TASK_HISTORY" ]

    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        ev = json.loads(line)
        if ev.get('event') == 'spawn':
            assert ev.get('schema') == '1', f'expected schema=1, got {ev.get(\"schema\")}'
            assert ev.get('role') == 'developer', f'role mismatch: {ev.get(\"role\")}'
            assert ev.get('phase') == 'implement', f'phase mismatch'
            assert ev.get('mode') == 'agent', f'mode mismatch'
            assert isinstance(ev.get('scope'), list), 'scope should be a list'
            assert 'timestamp' in ev, 'missing timestamp'
            print('ok')
            sys.exit(0)
sys.exit(1)
" "$TASK_HISTORY"
}

# ---------------------------------------------------------------------------
# Test 2: Missing required field in enforce mode → exit 2, nothing appended
# ---------------------------------------------------------------------------
@test "Test 2: enforce mode rejects missing required field, nothing appended" {
    run bash -c "
        cd '$FAKE_PROJECT'
        HOME='$FAKE_HOME' CLAUDE_PROJECT_DIR='$FAKE_PROJECT' LOG_EVENT_MODE=enforce \
        bash '$LOG_EVENT' spawn role=dev
    "

    [ "$status" -eq 2 ]

    # File should not exist or be empty (no spawn event appended)
    if [ -f "$TASK_HISTORY" ]; then
        count=$(python3 -c "
import json, sys
count = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
            if ev.get('event') == 'spawn':
                count += 1
        except: pass
print(count)
" "$TASK_HISTORY")
        [ "$count" -eq 0 ]
    fi
}

# ---------------------------------------------------------------------------
# Test 3: Invalid enum value in enforce mode → exit 2
# ---------------------------------------------------------------------------
@test "Test 3: enforce mode rejects invalid enum value" {
    run bash -c "
        cd '$FAKE_PROJECT'
        HOME='$FAKE_HOME' CLAUDE_PROJECT_DIR='$FAKE_PROJECT' LOG_EVENT_MODE=enforce \
        bash '$LOG_EVENT' spawn role=developer phase=implement detail=test scope=src/ mode=bogus
    "

    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 4: Old-format line (no schema field) is readable by grep-based reader
# ---------------------------------------------------------------------------
@test "Test 4: pre-schema event readable by grep-based reader (Layer-2 compat)" {
    # Write a legacy event manually (no schema field)
    python3 -c "
import json
ev = {'timestamp': '2026-01-01T00:00:00Z', 'event': 'spawn', 'role': 'developer',
      'phase': 'implement', 'detail': 'legacy task', 'scope': ['src/'], 'mode': 'agent'}
with open('$TASK_HISTORY', 'a') as f:
    f.write(json.dumps(ev) + '\n')
"

    # Simulate Layer-2 reader: grep for spawn event and parse with json.loads
    result=$(python3 -c "
import json
found = False
with open('$TASK_HISTORY') as f:
    for line in reversed(list(f)):
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
            if ev.get('event') == 'spawn' and ev.get('role') == 'developer':
                # Old format: no schema field — reader must tolerate
                assert ev.get('schema', '0') in ('0', '1', None, ''), \
                    f'unexpected schema: {ev.get(\"schema\")}'
                found = True
                break
        except json.JSONDecodeError:
            continue
print('ok' if found else 'not-found')
")

    [ "$result" = "ok" ]
}

# ---------------------------------------------------------------------------
# Test 5: Warn mode: invalid event → exit 0, warn logged, event still appended
# ---------------------------------------------------------------------------
@test "Test 5: warn mode appends event despite validation failure, logs warning" {
    # warn mode is the default; use incomplete spawn (missing mode)
    run _log_event spawn role=developer phase=implement detail=test scope=src/

    [ "$status" -eq 0 ]

    # Event must be appended
    [ -f "$TASK_HISTORY" ]
    count=$(python3 -c "
import json, sys
count = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
            if ev.get('event') == 'spawn':
                count += 1
        except: pass
print(count)
" "$TASK_HISTORY")
    [ "$count" -ge 1 ]

    # Warning must be logged to telemetry log
    [ -f "$TELEMETRY_LOG" ]
    grep -q "schema-validation-warn" "$TELEMETRY_LOG"
}

# ---------------------------------------------------------------------------
# Test 6: skill-telemetry hook emits event matching skill-invoked schema
# ---------------------------------------------------------------------------
@test "Test 6: skill-telemetry hook emits event satisfying skill-invoked schema" {
    local payload='{"tool_name":"Skill","tool_input":{"skill":"defensive-coding"},"session_id":"test-123"}'

    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="test-123" \
        bash "$SKILL_TELEMETRY" <<< "$payload" 2>/dev/null
    )
    [ "$?" -eq 0 ]

    [ -f "$TASK_HISTORY" ]

    python3 -c "
import json, sys
schema_required = ['timestamp', 'event', 'role', 'skill', 'session', 'source']
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
        except: continue
        if ev.get('event') == 'skill-invoked' and ev.get('skill') == 'defensive-coding':
            missing = [f for f in schema_required if f not in ev]
            assert not missing, f'missing fields: {missing}'
            assert ev['source'] == 'hook-auto', f'source: {ev[\"source\"]}'
            print('ok')
            sys.exit(0)
print('event not found', file=sys.stderr)
sys.exit(1)
" "$TASK_HISTORY"
}

# ---------------------------------------------------------------------------
# Test 7: Pre-existing malformed JSONL lines don't break reader (regression)
# ---------------------------------------------------------------------------
@test "Test 7: reader tolerates pre-existing malformed JSONL lines" {
    # Seed the file with malformed lines followed by valid ones
    python3 -c "
import json
lines = [
    'this is not json\n',
    '{broken: true}\n',
    json.dumps({'timestamp': '2026-04-17T00:00:00Z', 'event': 'spawn', 'role': 'developer',
                'phase': 'implement', 'detail': 'prior task', 'scope': ['src/'], 'mode': 'agent'}) + '\n',
    'another bad line\n',
]
with open('$TASK_HISTORY', 'w') as f:
    f.writelines(lines)
"

    # Reader must tolerate bad lines and still find the valid spawn event
    result=$(python3 -c "
import json
found = False
with open('$TASK_HISTORY') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
            if ev.get('event') == 'spawn':
                found = True
        except json.JSONDecodeError:
            continue
print('ok' if found else 'not-found')
")

    [ "$result" = "ok" ]
}
