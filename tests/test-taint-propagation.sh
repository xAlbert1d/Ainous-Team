#!/usr/bin/env bash
# test-taint-propagation.sh — Test suite for v5.9.0 Agent-boundary taint propagation (Option A)
#
# Tests:
#   TC-TP-1: parent NOT tainted + Agent spawn → child session flag file NOT created
#   TC-TP-2: parent tainted + Agent spawn + child_sid in tool_result → child flag file CREATED
#             with parent hashed_sid in upstream_chain
#   TC-TP-3: tainted parent spawns child; child Write to provenance surface → upstream_chain
#             auto-injected by _validate_taint_field (end-to-end path)
#   TC-TP-4: role-initiated Write to taint-flags/ under a child-session key → blocked
#             by TAINT_FLAG_WRITE_DENY (existing invariant preserved)
#
# Run: bash tests/test-taint-propagation.sh
# Exit 0 = all tests pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPAWN_HOOK="$PROJECT_ROOT/hooks/spawn-telemetry"
AUTHORITY_HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-taint-propagation.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"

mkdir -p "$FAKE_HOME/.claude"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/authority"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"

cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
touch "$FAKE_HOME/.claude/ainous-roles/authority/decisions.md"
echo "developer" > "$FAKE_HOME/.claude/.session-role"

cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["journal.md","playbook.md","learnings.jsonl","team-knowledge.md","user-corrections.md"]}
EOF

# Nonce setup for PARENT session
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"

PARENT_SESSION_ID="parent-session-abc123"
PARENT_HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$PARENT_SESSION_ID" 2>/dev/null)
PARENT_NONCE_BYTES="deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234"
PARENT_NONCE_FILE="$FAKE_NONCE_DIR/${PARENT_HASHED_SID}.nonce"
printf '%s' "$PARENT_NONCE_BYTES" > "$PARENT_NONCE_FILE"
chmod 600 "$PARENT_NONCE_FILE"

# Compute parent's taint-flag file path: sha256(parent_sid || parent_nonce_bytes)
PARENT_HASHED_FLAG=$(python3 -c "
import hashlib, sys
sid = sys.argv[1]
nonce = sys.argv[2].encode()
combined = sid.encode() + nonce
print(hashlib.sha256(combined).hexdigest())
" "$PARENT_SESSION_ID" "$PARENT_NONCE_BYTES" 2>/dev/null)

TAINT_FLAGS_DIR="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
PARENT_FLAG_FILE="$TAINT_FLAGS_DIR/${PARENT_HASHED_FLAG}.jsonl"
PARENT_SAMPLE_RECORD='{"ts":"2026-04-19T10:00:00Z","tool":"WebFetch","url":"https://evil.example/inject","content_hash":"abc123","role":"developer","schema":"1"}'

# Nonce setup for CHILD session
CHILD_SESSION_ID="child-session-xyz789"
CHILD_HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$CHILD_SESSION_ID" 2>/dev/null)
CHILD_NONCE_BYTES="cafebabe1234567890cafebabe1234567890cafebabe1234567890cafebabe12"
CHILD_NONCE_FILE="$FAKE_NONCE_DIR/${CHILD_HASHED_SID}.nonce"
printf '%s' "$CHILD_NONCE_BYTES" > "$CHILD_NONCE_FILE"
chmod 600 "$CHILD_NONCE_FILE"

# Compute child's expected taint-flag file path: sha256(child_sid || child_nonce_bytes)
CHILD_HASHED_FLAG=$(python3 -c "
import hashlib, sys
sid = sys.argv[1]
nonce = sys.argv[2].encode()
combined = sid.encode() + nonce
print(hashlib.sha256(combined).hexdigest())
" "$CHILD_SESSION_ID" "$CHILD_NONCE_BYTES" 2>/dev/null)

CHILD_FLAG_FILE="$TAINT_FLAGS_DIR/${CHILD_HASHED_FLAG}.jsonl"

TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"

# Helper: run spawn-telemetry hook with a given payload
_run_spawn_hook() {
    local payload="$1"
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$SPAWN_HOOK" <<< "$payload" 2>/dev/null
    )
    return $?
}

# Helper: build spawn-telemetry PostToolUse payload
_make_spawn_payload() {
    local parent_sid="$1"
    local child_sid="${2:-}"  # Optional: child session_id in tool_result
    python3 -c "
import json, sys
parent_sid = sys.argv[1]
child_sid = sys.argv[2] if len(sys.argv) > 2 else ''
tool_result = {'session_id': child_sid} if child_sid else {}
print(json.dumps({
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': 'ainous-team:developer',
        'prompt': 'do the work',
        'run_in_background': False,
    },
    'tool_result': tool_result,
    'session_id': parent_sid,
}))
" "$parent_sid" "$child_sid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# TC-TP-1: Parent session NOT tainted + Agent spawn → child flag file NOT created
# ---------------------------------------------------------------------------
rm -f "$PARENT_FLAG_FILE" "$CHILD_FLAG_FILE" "$TASK_HISTORY"

PAYLOAD_TP1=$(_make_spawn_payload "$PARENT_SESSION_ID" "$CHILD_SESSION_ID")
_run_spawn_hook "$PAYLOAD_TP1"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && [ ! -f "$CHILD_FLAG_FILE" ]; then
    _pass "TC-TP-1: parent NOT tainted + Agent spawn → child session flag file NOT created (exit 0)"
elif [ $EXIT_CODE -ne 0 ]; then
    _fail "TC-TP-1: spawn hook should exit 0 (fail-open)" "Got exit $EXIT_CODE"
else
    _fail "TC-TP-1: child flag file should NOT be created when parent is untainted" \
        "Child flag file unexpectedly found: $CHILD_FLAG_FILE"
fi

# ---------------------------------------------------------------------------
# TC-TP-2: Parent session TAINTED + Agent spawn + child_sid in tool_result →
# child flag file CREATED with parent hashed_sid in upstream_chain
# ---------------------------------------------------------------------------
rm -f "$CHILD_FLAG_FILE" "$TASK_HISTORY"
echo "$PARENT_SAMPLE_RECORD" > "$PARENT_FLAG_FILE"

PAYLOAD_TP2=$(_make_spawn_payload "$PARENT_SESSION_ID" "$CHILD_SESSION_ID")
_run_spawn_hook "$PAYLOAD_TP2"
EXIT_CODE=$?

TP2_CREATED=0
TP2_HAS_PARENT_SID=0
if [ -f "$CHILD_FLAG_FILE" ]; then
    TP2_CREATED=1
    # Verify parent hashed_sid appears in the child flag record's upstream_chain or url
    TP2_HAS_PARENT_SID=$(python3 -c "
import json, hashlib, sys
child_flag = sys.argv[1]
parent_sid = sys.argv[2]
parent_hashed = hashlib.sha256(parent_sid.encode()).hexdigest()
found = False
for line in open(child_flag):
    line = line.strip()
    if not line: continue
    try:
        rec = json.loads(line)
        url = rec.get('url', '')
        if parent_hashed in url:
            found = True
            break
        chain = rec.get('upstream_chain', [])
        if isinstance(chain, list):
            for entry in chain:
                if isinstance(entry, dict) and entry.get('parent_hashed_sid') == parent_hashed:
                    found = True
                    break
    except Exception:
        pass
print('1' if found else '0')
" "$CHILD_FLAG_FILE" "$PARENT_SESSION_ID" 2>/dev/null || echo "0")
fi

if [ $EXIT_CODE -eq 0 ] && [ $TP2_CREATED -eq 1 ] && [ "$TP2_HAS_PARENT_SID" = "1" ]; then
    _pass "TC-TP-2: parent tainted + Agent spawn → child flag file CREATED with parent hashed_sid in upstream_chain"
elif [ $EXIT_CODE -ne 0 ]; then
    _fail "TC-TP-2: spawn hook should exit 0" "Got exit $EXIT_CODE"
elif [ $TP2_CREATED -eq 0 ]; then
    _fail "TC-TP-2: child flag file should be CREATED when parent is tainted" \
        "Child flag file not found: $CHILD_FLAG_FILE"
else
    _fail "TC-TP-2: child flag file exists but parent hashed_sid not in upstream_chain" \
        "Expected parent_hashed_sid=$(python3 -c "import hashlib; print(hashlib.sha256('$PARENT_SESSION_ID'.encode()).hexdigest())")"
fi

# ---------------------------------------------------------------------------
# TC-TP-3: Tainted parent spawns child; child Write to provenance surface →
# _validate_taint_field auto-injects upstream_chain (end-to-end path)
# ---------------------------------------------------------------------------
# Child flag file was created in TC-TP-2. Now run the Write hook as the child session
# and verify that upstream_chain is injected.

TARGET_PLAYBOOK="$FAKE_HOME/.claude/ainous-roles/developer/playbook.md"
rm -f "$TARGET_PLAYBOOK"

VALID_PROV_NO_CHAIN='---
role: developer
session: 2026-04-19T10:00:00Z
source: observed
discovered: 2026-04-19
verified: null
---
# Playbook content
'

# Run Write hook as CHILD session (child flag file has inherited taint from TC-TP-2)
WRITE_JSON=$(python3 -c "import json,sys; print(json.dumps({
    'session_id': sys.argv[1],
    'file_path': sys.argv[2],
    'content': sys.argv[3]
}))" "$CHILD_SESSION_ID" "$TARGET_PLAYBOOK" "$VALID_PROV_NO_CHAIN" 2>/dev/null)

TP3_STDOUT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$CHILD_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$AUTHORITY_HOOK" <<< "$WRITE_JSON" 2>/dev/null
)
TP3_EXIT=$?

# Verify: exit 0 (injection allowed), and hookSpecificOutput.updatedInput.content has upstream_chain
TP3_HAS_INJECTION="NO"
if [ $TP3_EXIT -eq 0 ]; then
    TP3_HAS_INJECTION=$(echo "$TP3_STDOUT" | python3 -c "
import json, sys, re
try:
    data = json.load(sys.stdin)
    content = data.get('hookSpecificOutput', {}).get('updatedInput', {}).get('content', '')
    if re.search(r'upstream_chain\s*:', content):
        print('YES')
    else:
        print('NO')
except Exception:
    print('NO')
" 2>/dev/null)
fi

if [ $TP3_EXIT -eq 0 ] && [ "$TP3_HAS_INJECTION" = "YES" ]; then
    _pass "TC-TP-3: child Write with inherited taint → _validate_taint_field injects upstream_chain (end-to-end propagation path)"
elif [ $TP3_EXIT -ne 0 ]; then
    _fail "TC-TP-3: child Write should succeed with injection (exit 0)" "Got exit $TP3_EXIT"
else
    _fail "TC-TP-3: child Write allowed but upstream_chain not in hookSpecificOutput.updatedInput.content" \
        "TP3_STDOUT=$TP3_STDOUT"
fi

# ---------------------------------------------------------------------------
# TC-TP-4: Role-initiated write to taint-flags/ under a child-session key → blocked
# by TAINT_FLAG_WRITE_DENY (existing invariant preserved)
# ---------------------------------------------------------------------------
CHILD_FLAG_TARGET="$TAINT_FLAGS_DIR/${CHILD_HASHED_FLAG}.jsonl"
FORGE_INPUT=$(python3 -c "import json,sys; print(json.dumps({
    'session_id': sys.argv[1],
    'file_path': sys.argv[2],
    'content': 'forged content'
}))" "$CHILD_SESSION_ID" "$CHILD_FLAG_TARGET" 2>/dev/null)

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    TOOL_USE_NAME="Write" \
    CLAUDE_SESSION_ID="$CHILD_SESSION_ID" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    bash "$AUTHORITY_HOOK" <<< "$FORGE_INPUT" 2>/dev/null
)
TP4_EXIT=$?

if [ $TP4_EXIT -eq 2 ]; then
    _pass "TC-TP-4: role-initiated Write to taint-flags/ under child-session key → blocked by TAINT_FLAG_WRITE_DENY (exit 2)"
else
    _fail "TC-TP-4: Write to taint-flags/ should be blocked regardless of session" "Got exit $TP4_EXIT"
fi

# ---------------------------------------------------------------------------
# TC-TP-5: Parent tainted + Agent spawn WITHOUT child_sid in tool_result →
# propagation deferred (fail-open), hook still exits 0, no child flag created
# ---------------------------------------------------------------------------
rm -f "$CHILD_FLAG_FILE" "$TASK_HISTORY"
echo "$PARENT_SAMPLE_RECORD" > "$PARENT_FLAG_FILE"

# No child_sid — tool_result is empty
PAYLOAD_TP5=$(_make_spawn_payload "$PARENT_SESSION_ID" "")
_run_spawn_hook "$PAYLOAD_TP5"
TP5_EXIT=$?

if [ $TP5_EXIT -eq 0 ] && [ ! -f "$CHILD_FLAG_FILE" ]; then
    _pass "TC-TP-5: parent tainted + Agent spawn without child_sid → propagation deferred (fail-open), exit 0, no child flag"
elif [ $TP5_EXIT -ne 0 ]; then
    _fail "TC-TP-5: spawn hook should exit 0 even when propagation defers" "Got exit $TP5_EXIT"
else
    _fail "TC-TP-5: child flag file should NOT be created when child_sid unavailable" \
        "Unexpected child flag: $CHILD_FLAG_FILE"
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
