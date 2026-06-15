#!/usr/bin/env bats
# spawn-telemetry-outcome.bats — Test suite for the v5.21.0 subagent-outcome telemetry feature
#
# Coverage:
#   T1: tool_result with session_id + is_error:false → tool_status=returned, child_session_id set
#   T2: no tool_result (absent) → tool_status=unknown, child_session_id null, exit 0 (fail-open)
#   T3: tool_result.is_error:true → tool_status=error, is_error true in event
#   T4: team_name spawn mode → spawn_mode=team_name in subagent-outcome
#   T5: every emitted subagent-outcome has all schema required fields with valid enum values
#   T6: exactly ONE spawn + ONE subagent-outcome emitted per invocation (no duplicates)
#   T7: spawn event key set unchanged from pre-v5.21.0 baseline (additive only)
#   T8: empty tool_result {} → tool_status=unknown (not "returned")
#   T9: partial tool_result (is_error present, no session_id) → tool_status=returned, child_session_id null
#   T10: role without "ainous-team:" prefix → role logged as-is in both events
#   ADVERSARIAL-1: is_error as string "false" → tool_status=returned [FIXED: strict identity check]
#   ADVERSARIAL-2: tool_result.session_id is integer → child_session_id is STRING "12345" [FIXED: str() coercion]
#   ADVERSARIAL-3: tool_result is a JSON list → fail-open to tool_status=unknown, exit 0
#   ADVERSARIAL-4: child_session_id == parent session_id → child_session_id null [FIXED: self-join guard]
#   FORGERY-1: role attempting to write subagent-outcome to task-history via Write tool → BLOCKED
#
# Run: bats tests/bats/spawn-telemetry-outcome.bats
# Exit 0 = all tests pass.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/spawn-telemetry"
AUTHORITY_HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"

setup() {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    FAKE_PROJECT="$BATS_TEST_TMPDIR/project"

    mkdir -p "$FAKE_HOME/.claude"
    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"

    TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
}

teardown() {
    : # bats-core cleans BATS_TEST_TMPDIR
}

# ---------------------------------------------------------------------------
# Helper: run spawn-telemetry with a JSON payload, return exit code
# The task-history.jsonl is reset for each invocation.
# ---------------------------------------------------------------------------
_invoke_hook() {
    local json_input="$1"
    rm -f "$TASK_HISTORY"
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="test-session-st-01" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
}

# ---------------------------------------------------------------------------
# Helper: extract all events of a given type from task-history.jsonl
# Outputs one JSON object per line.
# ---------------------------------------------------------------------------
_events_of_type() {
    local event_type="$1"
    python3 -c "
import json, sys
path = sys.argv[1]
etype = sys.argv[2]
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            if ev.get('event') == etype:
                print(json.dumps(ev))
except FileNotFoundError:
    pass
" "$TASK_HISTORY" "$event_type"
}

# ---------------------------------------------------------------------------
# Helper: validate a single subagent-outcome JSON line against the schema
# Exits non-zero with a diagnostic message if validation fails.
# ---------------------------------------------------------------------------
_validate_outcome_schema() {
    local event_json="$1"
    python3 - <<PYEOF
import json, sys
ev = json.loads('''$event_json''')

REQUIRED = ["ts", "schema", "event", "role", "tool_status"]
TOOL_STATUS_ENUM = {"returned", "error", "unknown"}
SPAWN_MODE_ENUM  = {"agent", "team_name"}

errors = []

for field in REQUIRED:
    if field not in ev:
        errors.append(f"missing required field: {field!r}")

if "tool_status" in ev and ev["tool_status"] not in TOOL_STATUS_ENUM:
    errors.append(f"tool_status enum violation: {ev['tool_status']!r} not in {TOOL_STATUS_ENUM}")

if "spawn_mode" in ev and ev["spawn_mode"] is not None and ev["spawn_mode"] not in SPAWN_MODE_ENUM:
    errors.append(f"spawn_mode enum violation: {ev['spawn_mode']!r} not in {SPAWN_MODE_ENUM}")

if "event" in ev and ev["event"] != "subagent-outcome":
    errors.append(f"event field must be 'subagent-outcome', got {ev['event']!r}")

if errors:
    for e in errors:
        print(f"SCHEMA FAIL: {e}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
}

# ===========================================================================
# T1: tool_result with session_id + is_error:false → returned
# ===========================================================================

@test "T1: tool_result{session_id, is_error:false} → tool_status=returned, child_session_id set, schema=1, source=hook-auto, role=developer" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"do the thing"},"session_id":"parent-session-t1","tool_result":{"session_id":"child-session-t1","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]
    [ -f "$TASK_HISTORY" ]

    local outcome_count spawn_count
    outcome_count=$(_events_of_type "subagent-outcome" | wc -l | tr -d ' ')
    spawn_count=$(_events_of_type "spawn" | wc -l | tr -d ' ')
    [ "$outcome_count" -eq 1 ]
    [ "$spawn_count" -eq 1 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
assert ev.get("tool_status")      == "returned",          f"tool_status: {ev.get('tool_status')!r}"
assert ev.get("child_session_id") == "child-session-t1",  f"child_session_id: {ev.get('child_session_id')!r}"
assert ev.get("schema")           == "1",                  f"schema: {ev.get('schema')!r}"
assert ev.get("source")           == "hook-auto",          f"source: {ev.get('source')!r}"
assert ev.get("role")             == "developer",          f"role: {ev.get('role')!r}"
assert ev.get("event")            == "subagent-outcome",   f"event: {ev.get('event')!r}"
assert ev.get("is_error")         == False,                f"is_error: {ev.get('is_error')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# T2: no tool_result (absent key) → unknown, fail-open
# ===========================================================================

@test "T2: no tool_result key → tool_status=unknown, child_session_id null, exit 0, spawn event still present" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:tester","prompt":"run tests"},"session_id":"parent-session-t2"}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]
    [ -f "$TASK_HISTORY" ]

    local outcome spawn_count
    outcome=$(_events_of_type "subagent-outcome")
    spawn_count=$(_events_of_type "spawn" | wc -l | tr -d ' ')

    [ -n "$outcome" ]
    [ "$spawn_count" -eq 1 ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
assert ev.get("tool_status")      == "unknown", f"tool_status: {ev.get('tool_status')!r}"
assert ev.get("child_session_id") is None,      f"child_session_id: {ev.get('child_session_id')!r}"
assert ev.get("role")             == "tester",  f"role: {ev.get('role')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# T3: tool_result.is_error:true → tool_status=error
# ===========================================================================

@test "T3: tool_result.is_error:true → tool_status=error, is_error true in event" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:security","prompt":"scan"},"session_id":"parent-session-t3","tool_result":{"session_id":"child-err-t3","is_error":true}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
assert ev.get("tool_status")      == "error",          f"tool_status: {ev.get('tool_status')!r}"
assert ev.get("is_error")         == True,             f"is_error: {ev.get('is_error')!r}"
assert ev.get("child_session_id") == "child-err-t3",   f"child_session_id: {ev.get('child_session_id')!r}"
assert ev.get("role")             == "security",       f"role: {ev.get('role')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# T4: team_name spawn mode → subagent-outcome carries spawn_mode=team_name
# ===========================================================================

@test "T4: team_name spawn mode → spawn_mode=team_name in subagent-outcome with valid field set" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","name":"ainous-team:developer(feat-x)","team_name":"my-team","prompt":"implement feature"},"session_id":"parent-session-t4","tool_result":{"session_id":"child-team-t4","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
assert ev.get("spawn_mode")       == "team_name",          f"spawn_mode: {ev.get('spawn_mode')!r}"
assert ev.get("team_name")        == "my-team",            f"team_name: {ev.get('team_name')!r}"
assert ev.get("tool_status")      == "returned",           f"tool_status: {ev.get('tool_status')!r}"
assert ev.get("child_session_id") == "child-team-t4",      f"child_session_id: {ev.get('child_session_id')!r}"
# Required fields must be present
for field in ["ts", "schema", "event", "role", "tool_status"]:
    assert field in ev, f"missing required field: {field!r}"
sys.exit(0)
PYEOF

    # Additionally validate schema conformance
    _validate_outcome_schema "$outcome"
}

# ===========================================================================
# T5: Schema conformance for all four tool_status paths
# ===========================================================================

@test "T5: subagent-outcome schema conformance — all required fields present, no enum violations" {
    # Test all three tool_status values
    declare -a payloads=(
        '{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"sch-1","tool_result":{"session_id":"c-sch-1","is_error":false}}'
        '{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"sch-2","tool_result":{"session_id":"c-sch-2","is_error":true}}'
        '{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"sch-3"}'
    )

    for payload in "${payloads[@]}"; do
        run _invoke_hook "$payload"
        [ "$status" -eq 0 ]

        local outcome
        outcome=$(_events_of_type "subagent-outcome")
        [ -n "$outcome" ]
        _validate_outcome_schema "$outcome"
    done
}

# ===========================================================================
# T6: Exactly ONE spawn + ONE subagent-outcome per invocation
# ===========================================================================

@test "T6: exactly one spawn event and one subagent-outcome event emitted per invocation" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:architect","prompt":"design"},"session_id":"count-test","tool_result":{"session_id":"c-count","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local spawn_count outcome_count total_lines
    spawn_count=$(_events_of_type "spawn" | wc -l | tr -d ' ')
    outcome_count=$(_events_of_type "subagent-outcome" | wc -l | tr -d ' ')
    total_lines=$(wc -l < "$TASK_HISTORY" 2>/dev/null | tr -d ' ')

    [ "$spawn_count" -eq 1 ]
    [ "$outcome_count" -eq 1 ]
    # Only two lines total — spawn then subagent-outcome
    [ "$total_lines" -eq 2 ]
}

# ===========================================================================
# T7: Spawn event key set unchanged from pre-v5.21.0 baseline (additive only)
# ===========================================================================

@test "T7: spawn event key set is byte-for-byte consistent with pre-v5.21.0 baseline (no extra keys)" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","name":"alice","team_name":"myteam","run_in_background":true,"prompt":"work"},"session_id":"baseline-check","tool_result":{"session_id":"c-base","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local spawn
    spawn=$(_events_of_type "spawn")
    [ -n "$spawn" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$spawn''')

EXPECTED_KEYS = {
    "ts", "schema", "event", "source", "role", "session_id",
    "teammate_name", "team_name", "spawn_mode", "background",
    "prompt_bytes", "write_proxy_nonce_sha256"
}

actual_keys = set(ev.keys())
extra = actual_keys - EXPECTED_KEYS
missing = EXPECTED_KEYS - actual_keys

if extra:
    print(f"FAIL: spawn has NEW keys not in baseline: {extra}", file=sys.stderr)
    sys.exit(1)
if missing:
    print(f"FAIL: spawn missing expected baseline keys: {missing}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
}

# ===========================================================================
# T8: Empty tool_result ({}) → tool_status=unknown (fail-open boundary)
# ===========================================================================

@test "T8: empty tool_result {} → tool_status=unknown (not 'returned')" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"t8","tool_result":{}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
# Empty {} is falsy: `payload.get("tool_result") or {}` → {} or {} = {} (falsy).
# Then: `not isinstance({}, dict) or not {}` → False or True → True → "unknown"
assert ev.get("tool_status") == "unknown", \
    f"Empty tool_result should yield 'unknown', got {ev.get('tool_status')!r}"
assert ev.get("child_session_id") is None, \
    f"child_session_id should be None for empty tool_result, got {ev.get('child_session_id')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# T9: Partial tool_result (is_error present, no session_id) → returned, child null
# ===========================================================================

@test "T9: partial tool_result (is_error:false but no session_id) → tool_status=returned, child_session_id null" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"t9","tool_result":{"is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
assert ev.get("tool_status")      == "returned", f"tool_status: {ev.get('tool_status')!r}"
assert ev.get("child_session_id") is None,       f"child_session_id: {ev.get('child_session_id')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# T10: Non-ainous-team subagent_type → role logged as-is in both events
# ===========================================================================

@test "T10: non-ainous-team subagent_type → role=general-purpose in both spawn and outcome events" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"help"},"session_id":"t10","tool_result":{"session_id":"c-t10","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json, sys
with open("$TASK_HISTORY") as f:
    lines = [json.loads(l) for l in f if l.strip()]

spawn_events  = [l for l in lines if l.get("event") == "spawn"]
outcome_events = [l for l in lines if l.get("event") == "subagent-outcome"]

assert len(spawn_events)  == 1, f"Expected 1 spawn, got {len(spawn_events)}"
assert len(outcome_events) == 1, f"Expected 1 outcome, got {len(outcome_events)}"
assert spawn_events[0].get("role")   == "general-purpose", f"spawn role: {spawn_events[0].get('role')!r}"
assert outcome_events[0].get("role") == "general-purpose", f"outcome role: {outcome_events[0].get('role')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# ADVERSARIAL-1 (BUG): is_error as Python-truthy string "false" → misclassified as error
#
# This test DOCUMENTS a real defect in the implementation.
# The code uses bool(_tool_result.get("is_error", False)) — string "false" is
# truthy in Python (bool("false") == True), so it produces tool_status="error"
# when the caller intended "returned".
#
# Claude Code sends actual JSON booleans, so this is not a real-world attack
# vector for normally-functioning integrations. However it is an adversarial
# surface: a crafted PostToolUse payload with is_error="false" would corrupt
# the telemetry record. Severity: LOW (not externally exploitable in practice).
# Fix: replace bool(...) with `_tool_result.get("is_error") is True`
# ===========================================================================

@test "ADVERSARIAL-1 [FIXED]: is_error string 'false' → tool_status='returned' (strict identity check)" {
    # Previously KNOWN-BUG: bool("false") == True in Python → tool_status="error" (misclassification).
    # FIXED in v5.21.0 fix-up: changed to (_tool_result.get("is_error") is True) (strict identity).
    # String "false" is NOT True → _is_error=False → tool_status="returned" (correct behavior).
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"adv1","tool_result":{"session_id":"c-adv1","is_error":"false"}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
# FIXED: strict identity check — string "false" is not True → tool_status="returned"
actual = ev.get("tool_status")
assert actual == "returned", f"Expected tool_status='returned', got {actual!r} (bug may have regressed)"
assert ev.get("is_error") == False, f"Expected is_error=False, got {ev.get('is_error')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# ADVERSARIAL-2 (FINDING): tool_result.session_id is integer → child_session_id is integer
#
# The schema (subagent-outcome.json) does not constrain child_session_id type.
# The implementation passes through whatever Python extracts from JSON — an integer
# 12345 passes through as child_session_id=12345, which is a schema mismatch
# (should be string or null for a session ID). The consolidator join on
# child_session_id would never match a completed event (which has a string session_id).
# Severity: LOW (Claude Code sends string session IDs; not a practical attack).
# ===========================================================================

@test "ADVERSARIAL-2 [FIXED]: tool_result.session_id as integer → child_session_id is STRING (coerced)" {
    # Previously FINDING: integer session_id passed through as-is (int) → consolidator join never matches.
    # FIXED in v5.21.0 fix-up: coerce via str(... or "") or None → integer 12345 becomes string "12345".
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"adv2","tool_result":{"session_id":12345,"is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
csi = ev.get("child_session_id")
# FIXED: integer is coerced to string "12345" so the consolidator join works correctly
assert isinstance(csi, str), f"Expected child_session_id to be a string, got {type(csi).__name__}: {csi!r}"
assert csi == "12345", f"Expected child_session_id='12345', got {csi!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# ADVERSARIAL-3: tool_result is a JSON list → fail-open to tool_status=unknown, exit 0
# ===========================================================================

@test "ADVERSARIAL-3: tool_result is a JSON list (not object) → fail-open tool_status=unknown, exit 0" {
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"adv3","tool_result":["returned","child-session-xyz"]}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]
    [ -f "$TASK_HISTORY" ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
# list is truthy: `payload.get("tool_result") or {}` returns the list.
# isinstance(list, dict) is False → "unknown" branch fires.
assert ev.get("tool_status") == "unknown", \
    f"list tool_result should → 'unknown', got {ev.get('tool_status')!r}"
assert ev.get("child_session_id") is None, \
    f"child_session_id should be None for list tool_result, got {ev.get('child_session_id')!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# ADVERSARIAL-4 (FINDING): child_session_id == parent session_id → self-join risk
#
# When the tool_result carries a session_id that equals the parent session_id
# (e.g., a misbehaving Claude Code version or a crafted payload), the
# consolidator's join of subagent-outcome.child_session_id against
# completed/failed event session_id fields could match the parent's own
# completed/failed events — a self-join that produces false "silently-closed
# delegation" detections. This is a data-integrity finding, not a security vuln.
# ===========================================================================

@test "ADVERSARIAL-4 [FIXED]: child_session_id == parent session_id → nulled by self-join guard" {
    # Previously FINDING: no guard prevented child_session_id == parent session_id.
    # FIXED in v5.21.0 fix-up: after str() coercion, if child_session_id == session_id, set to None.
    # The consolidator's child_session_id<->completed.session_id join can no longer match parent events.
    local payload
    payload='{"tool_name":"Agent","tool_input":{"subagent_type":"ainous-team:developer","prompt":"x"},"session_id":"parent-self-join","tool_result":{"session_id":"parent-self-join","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    local outcome
    outcome=$(_events_of_type "subagent-outcome")
    [ -n "$outcome" ]

    python3 - <<PYEOF
import json, sys
ev = json.loads('''$outcome''')
sid = ev.get("session_id")
csi = ev.get("child_session_id")
# FIXED: self-join guard sets child_session_id to None when it equals parent session_id
assert csi is None, f"Expected child_session_id=None (self-join guard), got {csi!r} (sid={sid!r})"
assert sid == "parent-self-join", f"Expected session_id='parent-self-join', got {sid!r}"
sys.exit(0)
PYEOF
}

# ===========================================================================
# FORGERY-1: TASK_HISTORY_WRITE_DENY blocks role writing subagent-outcome via tool surface
# ===========================================================================

@test "FORGERY-1: role cannot forge a subagent-outcome line via Write tool (TASK_HISTORY_WRITE_DENY)" {
    # Setup authority-enforce prerequisites
    mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
    mkdir -p "$FAKE_HOME/.claude/.taint-nonces"
    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"

    # Write growth.json (senior trust for developer)
    python3 -c "import json; print(json.dumps({'trust':{'level':'senior'}}))" \
        > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json"

    # Write session role
    printf 'developer\n' > "$FAKE_HOME/.claude/.session-role"

    # Write developer baselines
    python3 -c "import json; print(json.dumps({'developer':['journal.md','playbook.md','learnings.jsonl']}))" \
        > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json"

    # Setup taint nonce for the test session
    local HASHED_SID
    HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "forge-test-session")
    local NONCE_BYTES="deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234"
    printf '%s' "$NONCE_BYTES" > "$FAKE_HOME/.claude/.taint-nonces/${HASHED_SID}.nonce"
    chmod 600 "$FAKE_HOME/.claude/.taint-nonces/${HASHED_SID}.nonce"

    # Attempt to write a forged subagent-outcome to task-history.jsonl
    local TARGET="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
    local FORGED_EVENT='{"ts":"2026-06-15T00:00:00Z","schema":"1","event":"subagent-outcome","source":"hook-auto","role":"developer","tool_status":"returned"}'
    local json_input
    json_input=$(python3 -c "
import json, sys
fp = sys.argv[1]; content = sys.argv[2]
print(json.dumps({'file_path': fp, 'content': content}))
" "$TARGET" "$FORGED_EVENT")

    # Use bats `run` to capture exit code and output together
    run bash -c "
        cd '$FAKE_PROJECT'
        HOME='$FAKE_HOME' \
        TOOL_USE_NAME='Write' \
        CLAUDE_SESSION_ID='forge-test-session' \
        CLAUDE_PROJECT_DIR='$FAKE_PROJECT' \
        bash '$AUTHORITY_HOOK' <<< '$json_input' 2>&1
    "

    [ "$status" -eq 2 ]
    [[ "$output" == *"TASK_HISTORY_WRITE_DENY"* ]] || [[ "$output" == *"BLOCKED"* ]]
}

# ===========================================================================
# REGRESSION: Non-Agent tool names are silently ignored (no event emitted)
# ===========================================================================

@test "REGRESSION: non-Agent tool_name (e.g. Skill) does not emit subagent-outcome" {
    local payload
    payload='{"tool_name":"Skill","tool_input":{"skill":"tdd"},"session_id":"reg-1","tool_result":{"session_id":"c-reg1","is_error":false}}'

    run _invoke_hook "$payload"
    [ "$status" -eq 0 ]

    # No history written for non-Agent tools
    local outcome_count spawn_count
    outcome_count=$(_events_of_type "subagent-outcome" | wc -l | tr -d ' ')
    spawn_count=$(_events_of_type "spawn" | wc -l | tr -d ' ')
    [ "$outcome_count" -eq 0 ]
    [ "$spawn_count" -eq 0 ]
}
