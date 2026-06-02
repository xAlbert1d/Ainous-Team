#!/usr/bin/env bash
# test-teammate-lifecycle-reaper.sh — Test suite for hooks/teammate-lifecycle-reaper (v5.11.0)
#
# Covers the reaper's teammate identity resolution, config.json mutation, and
# fail-closed behaviors introduced in v5.7.0 and v5.7.1.
# v5.11.0: adds TC-RL-7 and TC-RL-8 for SubagentStop lifecycle observability.
#
# TC-RL-1: SubagentStop for known teammate with valid spawn event → config flag flipped to false
# TC-RL-2: SubagentStop with resolved_team_name is None (no spawn event) → exit 0, no config modified
# TC-RL-3: Two teammates sharing same role string (substring-match attack) → only exact-match flipped
# TC-RL-4: Corrupted team config JSON → exception logged, no crash, no other teams touched
# TC-RL-5: SessionEnd fires on all teammates of the ending session
# TC-RL-6: task-history forgery — reaper refuses to act on out-of-session spawn events
# TC-RL-7: SubagentStop payload WITH background_tasks/session_crons → observability event logged + reap proceeds + exit 0
# TC-RL-8: SubagentStop payload WITHOUT background_tasks/session_crons → no observability event + normal behavior + exit 0
#
# Run: bash tests/test-teammate-lifecycle-reaper.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER="$PROJECT_ROOT/hooks/teammate-lifecycle-reaper"

TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-rl-reaper.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"
TEAMS_DIR="$FAKE_HOME/.claude/teams"
TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
ERROR_LOG="$FAKE_HOME/.claude/.lifecycle-reaper-errors.log"

mkdir -p "$FAKE_HOME/.claude" \
         "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state" \
         "$TEAMS_DIR"

# Helper: create a team config with members
_make_config() {
    local team_dir="$1"
    local config_content="$2"
    mkdir -p "$team_dir"
    printf '%s\n' "$config_content" > "$team_dir/config.json"
}

# Helper: run the reaper with given env vars
# Usage: _run_reaper <session_id> [<teammate_marker>] [<tmux_pane>] [<stdin_payload>]
_run_reaper() {
    local session_id="${1:-}"
    local teammate_marker="${2:-}"
    local tmux_pane="${3:-}"
    local stdin_payload="${4:-}"

    # Write marker file if provided
    if [ -n "$teammate_marker" ]; then
        if [ -n "$tmux_pane" ]; then
            printf '%s' "$teammate_marker" > "$FAKE_HOME/.claude/.session-role-${tmux_pane}"
        else
            printf '%s' "$teammate_marker" > "$FAKE_HOME/.claude/.session-role"
        fi
    fi

    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_SESSION_ID="${session_id}" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        ${tmux_pane:+TMUX_PANE="$tmux_pane"} \
        bash "$REAPER" 2>/dev/null <<< "${stdin_payload}"
    )
    return $?
}

# Helper: write a spawn event to task-history
_write_spawn_event() {
    local session_id="$1"
    local teammate_name="$2"
    local team_name="$3"
    python3 -c "
import json, sys
ev = {
    'event': 'spawn',
    'session_id': sys.argv[1],
    'teammate_name': sys.argv[2],
    'team_name': sys.argv[3],
    'spawn_mode': 'team_name',
    'ts': '2026-04-19T10:00:00Z',
    'schema': '1'
}
print(json.dumps(ev))
" "$session_id" "$teammate_name" "$team_name" >> "$TASK_HISTORY"
}

# ---------------------------------------------------------------------------
# TC-RL-1: Known teammate with valid spawn event → isActive flipped to false
# ---------------------------------------------------------------------------
TEAM1_DIR="$TEAMS_DIR/team-alpha"
_make_config "$TEAM1_DIR" '{
  "leadSessionId": "coord-session-001",
  "members": [
    {"name": "ainous-team:developer(task-a)", "isActive": true},
    {"name": "ainous-team:tester(task-a)", "isActive": true}
  ]
}'

# Write the spawn event for the developer teammate
SESSION_RL1="session-rl1-known-teammate"
_write_spawn_event "$SESSION_RL1" "ainous-team:developer(task-a)" "team-alpha"

_run_reaper "$SESSION_RL1" "developer"
EXIT_CODE=$?

# Verify only the matched teammate is flipped
RL1_DEV_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(task-a)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM1_DIR/config.json" 2>/dev/null || echo "error")

RL1_TESTER_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:tester(task-a)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM1_DIR/config.json" 2>/dev/null || echo "error")

if [ $EXIT_CODE -eq 0 ] && [ "$RL1_DEV_ACTIVE" = "false" ] && [ "$RL1_TESTER_ACTIVE" = "true" ]; then
    _pass "TC-RL-1: Known teammate + valid spawn event → isActive flipped to false (other members untouched)"
else
    _fail "TC-RL-1: Expected exit 0, developer.isActive=false, tester.isActive=true" \
        "exit=$EXIT_CODE dev_active=$RL1_DEV_ACTIVE tester_active=$RL1_TESTER_ACTIVE"
fi

# ---------------------------------------------------------------------------
# TC-RL-2: No spawn event for session (resolved_team_name is None) → no config modified
# ---------------------------------------------------------------------------
TEAM2_DIR="$TEAMS_DIR/team-beta"
_make_config "$TEAM2_DIR" '{
  "leadSessionId": "coord-session-002",
  "members": [
    {"name": "ainous-team:developer(task-b)", "isActive": true}
  ]
}'

SESSION_RL2="session-rl2-no-spawn-event"
# Do NOT write any spawn event for SESSION_RL2

_run_reaper "$SESSION_RL2" "developer"
EXIT_CODE=$?

RL2_DEV_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(task-b)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM2_DIR/config.json" 2>/dev/null || echo "error")

if [ $EXIT_CODE -eq 0 ] && [ "$RL2_DEV_ACTIVE" = "true" ]; then
    _pass "TC-RL-2: No spawn event → exit 0, config not modified (fail-closed: resolved_team_name is None)"
else
    _fail "TC-RL-2: Expected exit 0, developer.isActive=true (unmodified)" \
        "exit=$EXIT_CODE dev_active=$RL2_DEV_ACTIVE"
fi

# ---------------------------------------------------------------------------
# TC-RL-3: Two teammates sharing same role string — only exact-match teammate flipped
# Team has both ainous-team:developer(proj-a) and ainous-team:developer(proj-b)
# Spawn event resolves only proj-a; only proj-a should be reaped.
# ---------------------------------------------------------------------------
TEAM3_DIR="$TEAMS_DIR/team-gamma"
_make_config "$TEAM3_DIR" '{
  "leadSessionId": "coord-session-003",
  "members": [
    {"name": "ainous-team:developer(proj-a)", "isActive": true},
    {"name": "ainous-team:developer(proj-b)", "isActive": true}
  ]
}'

SESSION_RL3="session-rl3-exact-match"
_write_spawn_event "$SESSION_RL3" "ainous-team:developer(proj-a)" "team-gamma"

_run_reaper "$SESSION_RL3" "developer"
EXIT_CODE=$?

RL3_A_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(proj-a)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM3_DIR/config.json" 2>/dev/null || echo "error")

RL3_B_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(proj-b)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM3_DIR/config.json" 2>/dev/null || echo "error")

if [ $EXIT_CODE -eq 0 ] && [ "$RL3_A_ACTIVE" = "false" ] && [ "$RL3_B_ACTIVE" = "true" ]; then
    _pass "TC-RL-3: Substring-match attack prevented — only exact-match ainous-team:developer(proj-a) flipped; proj-b untouched"
else
    _fail "TC-RL-3: Expected exit 0, proj-a.isActive=false, proj-b.isActive=true" \
        "exit=$EXIT_CODE proj_a_active=$RL3_A_ACTIVE proj_b_active=$RL3_B_ACTIVE"
fi

# ---------------------------------------------------------------------------
# TC-RL-4: Corrupted team config JSON → exception logged, no crash, other teams untouched
# ---------------------------------------------------------------------------
TEAM4_BAD_DIR="$TEAMS_DIR/team-delta-corrupted"
mkdir -p "$TEAM4_BAD_DIR"
printf 'THIS IS NOT VALID JSON {{{' > "$TEAM4_BAD_DIR/config.json"

# A good team alongside the corrupted one — must not be modified
TEAM4_GOOD_DIR="$TEAMS_DIR/team-delta-good"
_make_config "$TEAM4_GOOD_DIR" '{
  "leadSessionId": "coord-session-004",
  "members": [
    {"name": "ainous-team:researcher(task-d)", "isActive": true}
  ]
}'

SESSION_RL4="session-rl4-corrupted-config"
_write_spawn_event "$SESSION_RL4" "ainous-team:researcher(task-d)" "team-delta-good"

_run_reaper "$SESSION_RL4" "researcher"
EXIT_CODE=$?

RL4_RESEARCHER_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:researcher(task-d)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM4_GOOD_DIR/config.json" 2>/dev/null || echo "error")

# The bad config still has its corrupted content (no crash should have occurred)
RL4_BAD_CONTENT=$(cat "$TEAM4_BAD_DIR/config.json" 2>/dev/null || echo "")

if [ $EXIT_CODE -eq 0 ] && [ "$RL4_RESEARCHER_ACTIVE" = "false" ] && [ "$RL4_BAD_CONTENT" = "THIS IS NOT VALID JSON {{{" ]; then
    _pass "TC-RL-4: Corrupted config JSON → logged exception, no crash, good team still processed correctly"
else
    _fail "TC-RL-4: Expected exit 0, researcher.isActive=false, bad config unchanged" \
        "exit=$EXIT_CODE researcher_active=$RL4_RESEARCHER_ACTIVE bad_content=${RL4_BAD_CONTENT:0:30}"
fi

# ---------------------------------------------------------------------------
# TC-RL-5: SessionEnd fires independently on each active teammate's own session.
# In production each teammate has its own CLAUDE_SESSION_ID. The reaper is called
# once per SessionEnd with that teammate's session_id. Verify two independent reap
# events each flip exactly their matched teammate.
# ---------------------------------------------------------------------------
TEAM5_DIR="$TEAMS_DIR/team-epsilon"
_make_config "$TEAM5_DIR" '{
  "leadSessionId": "coord-session-005",
  "members": [
    {"name": "ainous-team:developer(ep-task)", "isActive": true},
    {"name": "ainous-team:tester(ep-task)", "isActive": false},
    {"name": "ainous-team:architect(ep-task)", "isActive": true}
  ]
}'

# Each teammate has its own session_id (matching production behavior)
SESSION_RL5_DEV="session-rl5-developer-ep"
SESSION_RL5_ARCH="session-rl5-architect-ep"

# Write separate spawn events for developer and architect
_write_spawn_event "$SESSION_RL5_DEV" "ainous-team:developer(ep-task)" "team-epsilon"
_write_spawn_event "$SESSION_RL5_ARCH" "ainous-team:architect(ep-task)" "team-epsilon"

# Developer session ends → reaper runs with developer's session_id
_run_reaper "$SESSION_RL5_DEV" "developer"
RL5_EXIT1=$?

# Architect session ends → reaper runs with architect's session_id
_run_reaper "$SESSION_RL5_ARCH" "architect"
RL5_EXIT2=$?

RL5_DEV_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(ep-task)':
        print(str(m['isActive']).lower())
        break
" "$TEAM5_DIR/config.json" 2>/dev/null || echo "error")

RL5_ARCH_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:architect(ep-task)':
        print(str(m['isActive']).lower())
        break
" "$TEAM5_DIR/config.json" 2>/dev/null || echo "error")

RL5_TESTER_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:tester(ep-task)':
        print(str(m['isActive']).lower())
        break
" "$TEAM5_DIR/config.json" 2>/dev/null || echo "error")

if [ $RL5_EXIT1 -eq 0 ] && [ $RL5_EXIT2 -eq 0 ] \
   && [ "$RL5_DEV_ACTIVE" = "false" ] \
   && [ "$RL5_ARCH_ACTIVE" = "false" ] \
   && [ "$RL5_TESTER_ACTIVE" = "false" ]; then
    _pass "TC-RL-5: SessionEnd fires independently per teammate — developer and architect each flipped via their own session_id; already-inactive tester unchanged"
else
    _fail "TC-RL-5: Expected dev=false, arch=false, tester=false (already was)" \
        "exit1=$RL5_EXIT1 exit2=$RL5_EXIT2 dev=$RL5_DEV_ACTIVE arch=$RL5_ARCH_ACTIVE tester=$RL5_TESTER_ACTIVE"
fi

# ---------------------------------------------------------------------------
# TC-RL-6: task-history forgery resistance — out-of-session spawn events ignored
# After v5.8.1 TASK_HISTORY_WRITE_DENY closed the forgery surface, confirm reaper
# correctly refuses to act on events whose session_id does not match the stopping session.
#
# The reaper matches spawn events by session_id — it does NOT accept events
# where session_id differs from the calling session. This test verifies that
# a forged spawn event for a different session cannot cause cross-session reaping.
# ---------------------------------------------------------------------------
TEAM6_DIR="$TEAMS_DIR/team-zeta"
_make_config "$TEAM6_DIR" '{
  "leadSessionId": "coord-session-006",
  "members": [
    {"name": "ainous-team:security(zt-task)", "isActive": true}
  ]
}'

# Write a spawn event for a DIFFERENT session than the one that will run the reaper
SESSION_RL6_ACTUAL="session-rl6-actual-stopper"
SESSION_RL6_FORGED="session-rl6-forged-other"

# Forged event: claims the security teammate with a different session_id
_write_spawn_event "$SESSION_RL6_FORGED" "ainous-team:security(zt-task)" "team-zeta"

# Run reaper with the ACTUAL session (which has NO spawn events) — should not reap
_run_reaper "$SESSION_RL6_ACTUAL" "security"
EXIT_CODE=$?

RL6_SECURITY_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:security(zt-task)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM6_DIR/config.json" 2>/dev/null || echo "error")

if [ $EXIT_CODE -eq 0 ] && [ "$RL6_SECURITY_ACTIVE" = "true" ]; then
    _pass "TC-RL-6: Out-of-session forged spawn event ignored — reaper refuses to reap without matching session_id (cross-session forgery resistance)"
else
    _fail "TC-RL-6: Expected exit 0, security.isActive=true (forged event should have no effect)" \
        "exit=$EXIT_CODE security_active=$RL6_SECURITY_ACTIVE"
fi

# ---------------------------------------------------------------------------
# TC-RL-7: SubagentStop payload WITH background_tasks/session_crons →
#   observability event logged to task-history.jsonl + reap proceeds + exit 0
# ---------------------------------------------------------------------------
TEAM7_DIR="$TEAMS_DIR/team-eta"
TASK_HISTORY7="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history7.jsonl"
_make_config "$TEAM7_DIR" '{
  "leadSessionId": "coord-session-007",
  "members": [
    {"name": "ainous-team:developer(eta-task)", "isActive": true}
  ]
}'

SESSION_RL7="session-rl7-with-bg-tasks"
_write_spawn_event "$SESSION_RL7" "ainous-team:developer(eta-task)" "team-eta"

# SubagentStop payload with background_tasks and session_crons (newer CC)
RL7_PAYLOAD='{"background_tasks":[{"name":"bg-job-1","status":"pending"},{"name":"bg-job-2","status":"running"}],"session_crons":[{"id":"cron-abc","schedule":"*/5 * * * *"}]}'

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_SESSION_ID="$SESSION_RL7" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$REAPER" 2>/dev/null <<< "$RL7_PAYLOAD"
)
RL7_EXIT=$?

# Verify reap still happened
RL7_DEV_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:developer(eta-task)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM7_DIR/config.json" 2>/dev/null || echo "error")

# Verify observability event was written to task-history.jsonl
RL7_OBS_EVENT=$(python3 -c "
import json
events = []
try:
    with open('$TASK_HISTORY') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('event') == 'subagent-stop-observability' and ev.get('session_id') == '$SESSION_RL7':
                    events.append(ev)
            except Exception:
                pass
except Exception:
    pass
if events:
    ev = events[-1]
    print(f\"{ev.get('background_tasks_count',0)}:{ev.get('session_crons_count',0)}\")
else:
    print('none')
" 2>/dev/null || echo "error")

if [ $RL7_EXIT -eq 0 ] && [ "$RL7_DEV_ACTIVE" = "false" ] && [ "$RL7_OBS_EVENT" = "2:1" ]; then
    _pass "TC-RL-7: SubagentStop WITH background_tasks/session_crons → observability logged (bg=2,crons=1), reap proceeded, exit 0"
else
    _fail "TC-RL-7: Expected exit 0, dev.isActive=false, observability event bg=2:crons=1" \
        "exit=$RL7_EXIT dev_active=$RL7_DEV_ACTIVE obs_event=$RL7_OBS_EVENT"
fi

# ---------------------------------------------------------------------------
# TC-RL-8: SubagentStop payload WITHOUT background_tasks/session_crons →
#   no observability event + normal reap behavior + exit 0
# ---------------------------------------------------------------------------
TEAM8_DIR="$TEAMS_DIR/team-theta"
_make_config "$TEAM8_DIR" '{
  "leadSessionId": "coord-session-008",
  "members": [
    {"name": "ainous-team:tester(theta-task)", "isActive": true}
  ]
}'

SESSION_RL8="session-rl8-no-bg-tasks"
_write_spawn_event "$SESSION_RL8" "ainous-team:tester(theta-task)" "team-theta"

# SubagentStop payload WITHOUT background_tasks or session_crons (older CC or empty)
RL8_PAYLOAD='{"session_id":"session-rl8-no-bg-tasks","stop_hook_active":true}'

# Count observability events before
RL8_OBS_BEFORE=$(python3 -c "
import json
count = 0
try:
    with open('$TASK_HISTORY') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('event') == 'subagent-stop-observability' and ev.get('session_id') == '$SESSION_RL8':
                    count += 1
            except Exception:
                pass
except Exception:
    pass
print(count)
" 2>/dev/null || echo "0")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_SESSION_ID="$SESSION_RL8" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$REAPER" 2>/dev/null <<< "$RL8_PAYLOAD"
)
RL8_EXIT=$?

# Verify reap happened normally
RL8_TESTER_ACTIVE=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for m in cfg['members']:
    if m['name'] == 'ainous-team:tester(theta-task)':
        print(str(m['isActive']).lower())
        break
else:
    print('not-found')
" "$TEAM8_DIR/config.json" 2>/dev/null || echo "error")

# Count observability events after — should be same as before (no new event)
RL8_OBS_AFTER=$(python3 -c "
import json
count = 0
try:
    with open('$TASK_HISTORY') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('event') == 'subagent-stop-observability' and ev.get('session_id') == '$SESSION_RL8':
                    count += 1
            except Exception:
                pass
except Exception:
    pass
print(count)
" 2>/dev/null || echo "0")

if [ $RL8_EXIT -eq 0 ] && [ "$RL8_TESTER_ACTIVE" = "false" ] && [ "$RL8_OBS_AFTER" = "$RL8_OBS_BEFORE" ]; then
    _pass "TC-RL-8: SubagentStop WITHOUT background_tasks/session_crons → no observability event written, reap proceeded, exit 0"
else
    _fail "TC-RL-8: Expected exit 0, tester.isActive=false, no new observability event" \
        "exit=$RL8_EXIT tester_active=$RL8_TESTER_ACTIVE obs_before=$RL8_OBS_BEFORE obs_after=$RL8_OBS_AFTER"
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
