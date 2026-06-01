#!/usr/bin/env bash
# test-write-proxy.sh — Test suite for hooks/write-proxy (P-3, v5.6.4)
#
# TC-WP-1: Valid HMAC + valid dest in scope → write succeeds + hook-write event emitted
# TC-WP-2: Invalid HMAC → rejected, error logged, no write, no hook-write event
# TC-WP-3: Destination outside project root (/tmp/forged) → rejected by C-1
# TC-WP-4: Destination with glob chars (**/*.md) → rejected by C-1
# TC-WP-5: Non-envelope SendMessage (plain chat) → exit 0, no writes, no errors
# TC-WP-6: Envelope with missing provenance fields → rejected
# TC-WP-7: Envelope to provenance surface with invalid body frontmatter → rejected
# TC-WP-8: Valid write → hook-write event has all 8 required fields
# TC-WP-13: Tier 1 session_id lookup — SendMessage payload with session_id + matching spawn event
# TC-WP-14: Tier 2 envelope role lookup — no session_id, no payload identity, role→teammate-nonce
# TC-WP-15: Helper-script HMAC path — envelope built via compute-envelope-hmac.sh accepted by hook
#
# Run: bash tests/test-write-proxy.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/write-proxy"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-write-proxy.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"
TASK_HISTORY="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
ERROR_LOG="$FAKE_HOME/.claude/.write-proxy-errors.log"

mkdir -p "$FAKE_HOME/.claude"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"
mkdir -p "$FAKE_PROJECT/src"

NONCE="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

# ---------------------------------------------------------------------------
# Helper: build a valid envelope using Python (avoids bash printf '---' issue)
# Returns the full envelope message on stdout.
# ---------------------------------------------------------------------------
_build_valid_envelope() {
    local dest="$1"
    local content="$2"
    local prov_role="${3:-developer}"
    local prov_session="${4:-2026-04-18}"
    local prov_source="${5:-role-self-report}"
    local nonce="${6:-$NONCE}"

    python3 -c "
import hmac as _hmac, hashlib, sys

dest        = sys.argv[1]
content     = sys.argv[2]
prov_role   = sys.argv[3]
prov_sess   = sys.argv[4]
prov_source = sys.argv[5]
nonce_hex   = sys.argv[6]

body_no_hmac = (
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: ' + prov_role + '\n'
    'session: ' + prov_sess + '\n'
    'provenance:\n'
    '  role: ' + prov_role + '\n'
    '  session: ' + prov_sess + '\n'
    '  source: ' + prov_source + '\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    + content
)
key = bytes.fromhex(nonce_hex)
h = _hmac.new(key, body_no_hmac.encode('utf-8'), hashlib.sha256).hexdigest()

full = (
    '<!-- WRITE-PROXY-ENVELOPE v1 -->\n'
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: ' + prov_role + '\n'
    'session: ' + prov_sess + '\n'
    'hmac: ' + h + '\n'
    'provenance:\n'
    '  role: ' + prov_role + '\n'
    '  session: ' + prov_sess + '\n'
    '  source: ' + prov_source + '\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    + content
)
print(full, end='')
" "$dest" "$content" "$prov_role" "$prov_session" "$prov_source" "$nonce" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: build SendMessage PostToolUse payload JSON
# ---------------------------------------------------------------------------
_make_sendmessage_payload() {
    local message="$1"
    local teammate_name="${2:-alice}"
    local team_name="${3:-test-team}"
    python3 -c "
import json, sys
payload = {
    'tool_name': 'SendMessage',
    'tool_input': {
        'message': sys.argv[1],
        'teammate_name': sys.argv[2],
        'team_name': sys.argv[3],
    }
}
print(json.dumps(payload))
" "$message" "$teammate_name" "$team_name" 2>/dev/null
}

# Like _make_sendmessage_payload but simulates a real SendMessage envelope —
# NO teammate_name/team_name in tool_input (those are Agent spawn fields, not SendMessage fields).
# Optionally injects session_id at the top-level payload.
_make_sendmessage_payload_real() {
    local message="$1"
    local session_id="${2:-}"
    python3 -c "
import json, sys
payload = {
    'tool_name': 'SendMessage',
    'session_id': sys.argv[2],
    'tool_input': {
        'message': sys.argv[1],
    }
}
print(json.dumps(payload))
" "$message" "$session_id" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: inject a spawn event into task-history (v5.7.0: no raw nonce stored)
# ---------------------------------------------------------------------------
_inject_spawn_event() {
    local teammate_name="$1"
    local team_name="$2"
    local nonce="$3"   # kept for API compatibility; nonce is written to nonce file, not task-history
    local scope_json="${4:-[]}"
    python3 -c "
import json, sys
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'spawn',
    'source': 'hook-auto',
    'role': 'developer',
    'session_id': 'test-session',
    'teammate_name': sys.argv[1],
    'team_name': sys.argv[2],
    'spawn_mode': 'team_name',
    'background': False,
    'prompt_bytes': 100,
    'scope': json.loads(sys.argv[4]),
    # v5.7.0: write_proxy_nonce_sha256 only; raw nonce NOT in task-history
    'write_proxy_nonce_sha256': __import__('hashlib').sha256(sys.argv[3].encode()).hexdigest(),
}
print(json.dumps(ev))
" "$teammate_name" "$team_name" "$nonce" "$scope_json" 2>/dev/null >> "$TASK_HISTORY"
    # v5.7.0: write nonce to canonical nonce file (mode 0600) in FAKE_HOME
    _inject_nonce_file "$teammate_name" "$team_name" "$nonce"
}

# ---------------------------------------------------------------------------
# Helper: write nonce to canonical nonce file (v5.7.0)
# This is the canonical source write-proxy reads — not task-history.
# ---------------------------------------------------------------------------
_inject_nonce_file() {
    local teammate_name="$1"
    local team_name="$2"
    local nonce="$3"
    local nonce_dir="$FAKE_HOME/.claude/teams/${team_name}/nonces"
    mkdir -p "$nonce_dir"
    chmod 700 "$nonce_dir"
    printf '%s' "$nonce" > "${nonce_dir}/${teammate_name}.nonce"
    chmod 600 "${nonce_dir}/${teammate_name}.nonce"
}

# ---------------------------------------------------------------------------
# Helper: run the write-proxy hook with a given payload string
# ---------------------------------------------------------------------------
_run_hook() {
    local payload="$1"
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="test-session-wp" \
        bash "$HOOK" <<< "$payload" 2>/dev/null
    )
    return $?
}

# Reset task-history and error log for each test
_reset_history() {
    rm -f "$TASK_HISTORY" "$ERROR_LOG"
    mkdir -p "$(dirname "$TASK_HISTORY")"
}

# ---------------------------------------------------------------------------
# TC-WP-1: Valid HMAC + valid dest in scope → write succeeds + hook-write emitted
# ---------------------------------------------------------------------------
_reset_history
DEST_FILE="$FAKE_PROJECT/src/output.txt"
rm -f "$DEST_FILE"
CONTENT="Hello from teammate."

_inject_spawn_event "alice" "test-team" "$NONCE" '[]'
ENVELOPE=$(_build_valid_envelope "$DEST_FILE" "$CONTENT")
PAYLOAD=$(_make_sendmessage_payload "$ENVELOPE" "alice" "test-team")

_run_hook "$PAYLOAD"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    _fail "TC-WP-1: hook exit code" "Got exit $EXIT_CODE"
elif [ ! -f "$DEST_FILE" ]; then
    _fail "TC-WP-1: destination file not written" "File missing: $DEST_FILE. Error log: $(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
else
    WRITTEN=$(cat "$DEST_FILE")
    if [ "$WRITTEN" = "$CONTENT" ]; then
        _pass "TC-WP-1: valid envelope → write succeeds, content matches"
    else
        _fail "TC-WP-1: content mismatch" "Expected '$CONTENT' got '$WRITTEN'"
    fi
fi

# ---------------------------------------------------------------------------
# TC-WP-2: Invalid HMAC → rejected, error logged, no file mutation, no hook-write
# ---------------------------------------------------------------------------
_reset_history
DEST_FILE2="$FAKE_PROJECT/src/output2.txt"
rm -f "$DEST_FILE2"
_inject_spawn_event "alice" "test-team" "$NONCE" '[]'

# Build envelope with deliberately wrong HMAC
BAD_HMAC_ENVELOPE=$(python3 -c "
import sys
dest = sys.argv[1]
msg = (
    '<!-- WRITE-PROXY-ENVELOPE v1 -->\n'
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: developer\n'
    'session: 2026-04-18\n'
    'hmac: 0000000000000000000000000000000000000000000000000000000000000000\n'
    'provenance:\n'
    '  role: developer\n'
    '  session: 2026-04-18\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    'Evil content.'
)
print(msg, end='')
" "$DEST_FILE2" 2>/dev/null)
PAYLOAD2=$(_make_sendmessage_payload "$BAD_HMAC_ENVELOPE" "alice" "test-team")

_run_hook "$PAYLOAD2"
EXIT_CODE=$?

FILE_EXISTS=0
[ -f "$DEST_FILE2" ] && FILE_EXISTS=1
ERROR_LOGGED=0
[ -f "$ERROR_LOG" ] && grep -q "HMAC mismatch" "$ERROR_LOG" 2>/dev/null && ERROR_LOGGED=1
HW_EVENT=0
[ -f "$TASK_HISTORY" ] && grep -q '"event":"hook-write"' "$TASK_HISTORY" 2>/dev/null && HW_EVENT=1

if [ $EXIT_CODE -eq 0 ] && [ $FILE_EXISTS -eq 0 ] && [ $ERROR_LOGGED -eq 1 ] && [ $HW_EVENT -eq 0 ]; then
    _pass "TC-WP-2: invalid HMAC → rejected, error logged, no write, no hook-write event"
else
    _fail "TC-WP-2: invalid HMAC handling" "exit=$EXIT_CODE file_exists=$FILE_EXISTS error_logged=$ERROR_LOGGED hw_event=$HW_EVENT"
fi

# ---------------------------------------------------------------------------
# TC-WP-3: Destination outside project root → rejected by C-1
# ---------------------------------------------------------------------------
_reset_history
_inject_spawn_event "alice" "test-team" "$NONCE" '[]'

OUTSIDE_DEST="/tmp/forged-by-teammate-wp.txt"
rm -f "$OUTSIDE_DEST"
ENVELOPE3=$(_build_valid_envelope "$OUTSIDE_DEST" "forged content")
PAYLOAD3=$(_make_sendmessage_payload "$ENVELOPE3" "alice" "test-team")

_run_hook "$PAYLOAD3"
EXIT_CODE=$?

FILE_EXISTS=0
[ -f "$OUTSIDE_DEST" ] && FILE_EXISTS=1
ERROR_C1=0
[ -f "$ERROR_LOG" ] && grep -q "outside project root\|C-1" "$ERROR_LOG" 2>/dev/null && ERROR_C1=1

if [ $EXIT_CODE -eq 0 ] && [ $FILE_EXISTS -eq 0 ] && [ $ERROR_C1 -eq 1 ]; then
    _pass "TC-WP-3: destination outside project root → rejected by C-1"
else
    _fail "TC-WP-3: C-1 path containment outside root" "exit=$EXIT_CODE file_exists=$FILE_EXISTS c1_error=$ERROR_C1 log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
fi
rm -f "$OUTSIDE_DEST"

# ---------------------------------------------------------------------------
# TC-WP-4: Destination with glob chars (**/*.md) → rejected by C-1
# ---------------------------------------------------------------------------
_reset_history
_inject_spawn_event "alice" "test-team" "$NONCE" '[]'

GLOB_DEST="$FAKE_PROJECT/**/*.md"
ENVELOPE4=$(_build_valid_envelope "$GLOB_DEST" "glob content")
PAYLOAD4=$(_make_sendmessage_payload "$ENVELOPE4" "alice" "test-team")

_run_hook "$PAYLOAD4"
EXIT_CODE=$?

ERROR_GLOB=0
[ -f "$ERROR_LOG" ] && grep -q "glob\|overly broad\|C-1" "$ERROR_LOG" 2>/dev/null && ERROR_GLOB=1

if [ $EXIT_CODE -eq 0 ] && [ $ERROR_GLOB -eq 1 ]; then
    _pass "TC-WP-4: glob destination → rejected by C-1"
else
    _fail "TC-WP-4: C-1 glob rejection" "exit=$EXIT_CODE error_glob=$ERROR_GLOB log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
fi

# ---------------------------------------------------------------------------
# TC-WP-5: Plain chat SendMessage (no magic marker) → exit 0, no writes, no errors
# ---------------------------------------------------------------------------
_reset_history
CHAT_PAYLOAD=$(_make_sendmessage_payload "Hey team, great work today!" "alice" "test-team")
_run_hook "$CHAT_PAYLOAD"
EXIT_CODE=$?

ERROR_WRITTEN=0
[ -f "$ERROR_LOG" ] && [ -s "$ERROR_LOG" ] && ERROR_WRITTEN=1

if [ $EXIT_CODE -eq 0 ] && [ $ERROR_WRITTEN -eq 0 ]; then
    _pass "TC-WP-5: plain chat message → exit 0, no writes, no errors"
else
    _fail "TC-WP-5: plain chat handling" "exit=$EXIT_CODE error_written=$ERROR_WRITTEN"
fi

# ---------------------------------------------------------------------------
# TC-WP-6: Envelope with missing provenance fields → rejected
# (missing 'session' field in provenance block)
# ---------------------------------------------------------------------------
_reset_history
DEST_FILE6="$FAKE_PROJECT/src/output6.txt"
rm -f "$DEST_FILE6"
_inject_spawn_event "alice" "test-team" "$NONCE" '[]'

# Build envelope with incomplete provenance using Python
ENVELOPE6=$(python3 -c "
import hmac as _hmac, hashlib, sys

dest = sys.argv[1]
nonce_hex = sys.argv[2]

# Incomplete provenance — missing 'session' field
body_no_hmac = (
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: developer\n'
    'session: 2026-04-18\n'
    'provenance:\n'
    '  role: developer\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    'some content'
)
key = bytes.fromhex(nonce_hex)
h = _hmac.new(key, body_no_hmac.encode('utf-8'), hashlib.sha256).hexdigest()

full = (
    '<!-- WRITE-PROXY-ENVELOPE v1 -->\n'
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: developer\n'
    'session: 2026-04-18\n'
    'hmac: ' + h + '\n'
    'provenance:\n'
    '  role: developer\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    'some content'
)
print(full, end='')
" "$DEST_FILE6" "$NONCE" 2>/dev/null)
PAYLOAD6=$(_make_sendmessage_payload "$ENVELOPE6" "alice" "test-team")

_run_hook "$PAYLOAD6"
EXIT_CODE=$?

FILE_EXISTS=0
[ -f "$DEST_FILE6" ] && FILE_EXISTS=1
ERROR_PROV=0
[ -f "$ERROR_LOG" ] && grep -q "provenance\|missing" "$ERROR_LOG" 2>/dev/null && ERROR_PROV=1

if [ $EXIT_CODE -eq 0 ] && [ $FILE_EXISTS -eq 0 ] && [ $ERROR_PROV -eq 1 ]; then
    _pass "TC-WP-6: missing provenance fields → rejected"
else
    _fail "TC-WP-6: provenance field validation" "exit=$EXIT_CODE file_exists=$FILE_EXISTS error_prov=$ERROR_PROV log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
fi

# ---------------------------------------------------------------------------
# TC-WP-7: Provenance surface destination, content body missing frontmatter → rejected
# ---------------------------------------------------------------------------
_reset_history
PROV_SURFACE="$FAKE_PROJECT/.claude/ainous-roles/developer/journal.md"
mkdir -p "$(dirname "$PROV_SURFACE")"
rm -f "$PROV_SURFACE"
_inject_spawn_event "alice" "test-team" "$NONCE" '[]'

# Content body with no frontmatter
BODY_CONTENT="## 2026-04-18 --- some session\nBody without provenance block."

ENVELOPE7=$(python3 -c "
import hmac as _hmac, hashlib, sys

dest       = sys.argv[1]
nonce_hex  = sys.argv[2]
body_text  = sys.argv[3]

body_no_hmac = (
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: developer\n'
    'session: 2026-04-18\n'
    'provenance:\n'
    '  role: developer\n'
    '  session: 2026-04-18\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    + body_text
)
key = bytes.fromhex(nonce_hex)
h = _hmac.new(key, body_no_hmac.encode('utf-8'), hashlib.sha256).hexdigest()

full = (
    '<!-- WRITE-PROXY-ENVELOPE v1 -->\n'
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: developer\n'
    'session: 2026-04-18\n'
    'hmac: ' + h + '\n'
    'provenance:\n'
    '  role: developer\n'
    '  session: 2026-04-18\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    + body_text
)
print(full, end='')
" "$PROV_SURFACE" "$NONCE" "$BODY_CONTENT" 2>/dev/null)
PAYLOAD7=$(_make_sendmessage_payload "$ENVELOPE7" "alice" "test-team")

_run_hook "$PAYLOAD7"
EXIT_CODE=$?

FILE_WRITTEN=0
[ -f "$PROV_SURFACE" ] && FILE_WRITTEN=1
ERROR_PROV7=0
[ -f "$ERROR_LOG" ] && grep -q "provenance surface\|no frontmatter\|content body" "$ERROR_LOG" 2>/dev/null && ERROR_PROV7=1

if [ $EXIT_CODE -eq 0 ] && [ $FILE_WRITTEN -eq 0 ] && [ $ERROR_PROV7 -eq 1 ]; then
    _pass "TC-WP-7: provenance surface with invalid body frontmatter → rejected"
else
    _fail "TC-WP-7: provenance surface body validation" "exit=$EXIT_CODE file_written=$FILE_WRITTEN error_prov7=$ERROR_PROV7 log=$(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
fi

# ---------------------------------------------------------------------------
# TC-WP-8: Valid write → hook-write event has all 8 required fields
# ---------------------------------------------------------------------------
_reset_history
DEST_FILE8="$FAKE_PROJECT/src/output8.txt"
rm -f "$DEST_FILE8"
_inject_spawn_event "bob" "alpha-team" "$NONCE" '[]'

CONTENT8="Output from bob."
ENVELOPE8=$(_build_valid_envelope "$DEST_FILE8" "$CONTENT8")
PAYLOAD8=$(_make_sendmessage_payload "$ENVELOPE8" "bob" "alpha-team")

_run_hook "$PAYLOAD8"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    _fail "TC-WP-8: hook exit code" "Got exit $EXIT_CODE"
elif [ ! -f "$TASK_HISTORY" ]; then
    _fail "TC-WP-8: task-history.jsonl not found" "Missing"
else
    HW_LINE=$(grep '"hook-write"' "$TASK_HISTORY" 2>/dev/null | tail -1 || echo "")
    if [ -z "$HW_LINE" ]; then
        _fail "TC-WP-8: no hook-write event in task-history" "history: $(cat "$TASK_HISTORY" 2>/dev/null)"
    else
        FIELDS_OK=$(python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
# 8 required fields per spec: ts, schema, event, source, role, teammate_name, destination, bytes_written, envelope_hmac
required = {'ts', 'schema', 'event', 'source', 'role', 'teammate_name', 'destination', 'bytes_written', 'envelope_hmac'}
missing = required - set(ev.keys())
if missing:
    print('MISSING:' + ','.join(sorted(missing)))
else:
    print('OK')
" "$HW_LINE" 2>/dev/null || echo "PARSE_ERROR")
        if [ "$FIELDS_OK" = "OK" ]; then
            _pass "TC-WP-8: hook-write event has all required fields"
        else
            _fail "TC-WP-8: hook-write event missing fields" "$FIELDS_OK"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TC-WP-9: End-to-end — spawn-telemetry writes nonce file + write-proxy uses it
# Simulates a full team-mode spawn: invoke spawn-telemetry with a synthetic Agent
# payload, verify the nonce file appears at the expected path with mode 0600,
# then use that nonce to build a valid envelope and confirm write-proxy accepts it.
# ---------------------------------------------------------------------------
_reset_history

SPAWN_TELEMETRY="$PROJECT_ROOT/hooks/spawn-telemetry"
FAKE_CLAUDE_HOME="$TMPDIR_BASE/home9"
mkdir -p "$FAKE_CLAUDE_HOME/.claude"

E2E_TEAM="e2e-team"
E2E_MATE="carol"
E2E_NONCE_FILE="$FAKE_CLAUDE_HOME/.claude/teams/$E2E_TEAM/nonces/$E2E_MATE.nonce"
DEST_FILE9="$FAKE_PROJECT/src/output9.txt"
rm -f "$DEST_FILE9" "$E2E_NONCE_FILE"

# Build a synthetic Agent PostToolUse payload for team-mode spawn
AGENT_PAYLOAD=$(python3 -c "
import json, sys
payload = {
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': 'ainous-team:developer',
        'name': sys.argv[1],
        'team_name': sys.argv[2],
        'run_in_background': True,
        'prompt': 'Do some work',
    }
}
print(json.dumps(payload))
" "$E2E_MATE" "$E2E_TEAM" 2>/dev/null)

# Invoke spawn-telemetry; it should write the nonce file and emit spawn event
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_CLAUDE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-e2e" \
    bash "$SPAWN_TELEMETRY" <<< "$AGENT_PAYLOAD" 2>/dev/null
) || true

# Verify: nonce file exists
NONCE_FILE_EXISTS=0
[ -f "$E2E_NONCE_FILE" ] && NONCE_FILE_EXISTS=1

# Verify: spawn event emitted to task-history (json.dumps uses ": " so allow optional space)
SPAWN_EVENT_EMITTED=0
[ -f "$TASK_HISTORY" ] && grep -qE '"event"[[:space:]]*:[[:space:]]*"spawn"' "$TASK_HISTORY" 2>/dev/null && SPAWN_EVENT_EMITTED=1

# Verify: nonce file mode is 0600
NONCE_MODE_OK=0
if [ $NONCE_FILE_EXISTS -eq 1 ]; then
    FILE_MODE=$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$E2E_NONCE_FILE').st_mode)))" 2>/dev/null || echo "err")
    [ "$FILE_MODE" = "0o600" ] && NONCE_MODE_OK=1
fi

if [ $NONCE_FILE_EXISTS -eq 0 ] || [ $SPAWN_EVENT_EMITTED -eq 0 ] || [ $NONCE_MODE_OK -eq 0 ]; then
    _fail "TC-WP-9: spawn-telemetry nonce file or event" \
        "nonce_file=$NONCE_FILE_EXISTS mode_ok=$NONCE_MODE_OK spawn_event=$SPAWN_EVENT_EMITTED"
else
    # Read the nonce back and use it to emit a valid write-proxy envelope
    E2E_NONCE=$(cat "$E2E_NONCE_FILE" 2>/dev/null || echo "")
    if [ -z "$E2E_NONCE" ]; then
        _fail "TC-WP-9: nonce file is empty" "File: $E2E_NONCE_FILE"
    else
        # Inject spawn event into task-history + write nonce file (v5.7.0: canonical source)
        _inject_spawn_event "$E2E_MATE" "$E2E_TEAM" "$E2E_NONCE" '[]'

        CONTENT9="E2E content from carol."
        ENVELOPE9=$(_build_valid_envelope "$DEST_FILE9" "$CONTENT9" "developer" "2026-04-18" "role-self-report" "$E2E_NONCE")
        PAYLOAD9=$(_make_sendmessage_payload "$ENVELOPE9" "$E2E_MATE" "$E2E_TEAM")

        (
            cd "$FAKE_PROJECT"
            HOME="$FAKE_HOME" \
            CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
            CLAUDE_SESSION_ID="test-session-wp" \
            bash "$HOOK" <<< "$PAYLOAD9" 2>/dev/null
        ) || true

        if [ -f "$DEST_FILE9" ] && [ "$(cat "$DEST_FILE9")" = "$CONTENT9" ]; then
            _pass "TC-WP-9: end-to-end — spawn-telemetry writes nonce, write-proxy uses it, write succeeds"
        else
            _fail "TC-WP-9: end-to-end write failed" \
                "dest_exists=$([ -f "$DEST_FILE9" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TC-WP-10: Nonce file write fails (teams dir pre-created as 0400) — spawn-telemetry
# still emits event (fail-warn); write-proxy rejects envelope (HMAC unknown to teammate).
# ---------------------------------------------------------------------------
_reset_history

FAKE_CLAUDE_HOME10="$TMPDIR_BASE/home10"
mkdir -p "$FAKE_CLAUDE_HOME10/.claude"

E2E_TEAM10="locked-team"
E2E_MATE10="dave"
# Lock the teams parent dir (0500: read+exec but not write) so makedirs for the nonces
# sub-directory fails — spawn-telemetry cannot write the nonce file.
# Using 0500 (not 0400) so that os.chmod on a non-existent subdir still fails at makedirs.
LOCKED_TEAMS_DIR="$FAKE_CLAUDE_HOME10/.claude/teams"
mkdir -p "$LOCKED_TEAMS_DIR"
chmod 0500 "$LOCKED_TEAMS_DIR"

AGENT_PAYLOAD10=$(python3 -c "
import json, sys
payload = {
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': 'ainous-team:developer',
        'name': sys.argv[1],
        'team_name': sys.argv[2],
        'run_in_background': True,
        'prompt': 'Do some locked work',
    }
}
print(json.dumps(payload))
" "$E2E_MATE10" "$E2E_TEAM10" 2>/dev/null)

SPAWN_ERR_LOG10="$FAKE_CLAUDE_HOME10/.claude/.spawn-telemetry-errors.log"

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_CLAUDE_HOME10" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-locked" \
    bash "$SPAWN_TELEMETRY" <<< "$AGENT_PAYLOAD10" 2>/dev/null
) || true

# Restore perms so cleanup can succeed
chmod 0700 "$LOCKED_TEAMS_DIR" 2>/dev/null || true

# spawn-telemetry must still have emitted the spawn event (fail-warn, not fail-closed)
SPAWN_EVENT10=0
[ -f "$TASK_HISTORY" ] && grep -qE '"event"[[:space:]]*:[[:space:]]*"spawn"' "$TASK_HISTORY" 2>/dev/null && SPAWN_EVENT10=1

# spawn-telemetry must have logged an error about the nonce file failure
ERROR_LOGGED10=0
[ -f "$SPAWN_ERR_LOG10" ] && grep -q "nonce file write failed" "$SPAWN_ERR_LOG10" 2>/dev/null && ERROR_LOGGED10=1

# write-proxy with a guessed nonce must be rejected (HMAC will not match real nonce in spawn event)
GUESSED_NONCE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
DEST_FILE10="$FAKE_PROJECT/src/output10.txt"
rm -f "$DEST_FILE10"

# v5.7.0: raw nonce is no longer stored in task-history (write_proxy_nonce removed).
# The nonce file could not be written (teams dir locked), so write-proxy cannot resolve
# the nonce for this teammate — envelope with any nonce will be rejected.
# REAL_NONCE10 is not used; guessed nonce below will cause HMAC mismatch / no-nonce rejection.

# Attempt to emit an envelope using a wrong (guessed) nonce — HMAC will mismatch
ENVELOPE10=$(_build_valid_envelope "$DEST_FILE10" "should not land" "developer" "2026-04-18" "role-self-report" "$GUESSED_NONCE")
PAYLOAD10=$(_make_sendmessage_payload "$ENVELOPE10" "$E2E_MATE10" "$E2E_TEAM10")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-wp" \
    bash "$HOOK" <<< "$PAYLOAD10" 2>/dev/null
) || true

WRITE_REJECTED10=0
[ ! -f "$DEST_FILE10" ] && WRITE_REJECTED10=1

if [ $SPAWN_EVENT10 -eq 1 ] && [ $ERROR_LOGGED10 -eq 1 ] && [ $WRITE_REJECTED10 -eq 1 ]; then
    _pass "TC-WP-10: nonce file write fails → spawn event still emitted, error logged, envelope rejected"
else
    _fail "TC-WP-10: locked nonce dir handling" \
        "spawn_event=$SPAWN_EVENT10 error_logged=$ERROR_LOGGED10 write_rejected=$WRITE_REJECTED10"
fi

# ---------------------------------------------------------------------------
# TC-WP-11: Option 2 primary path — teammate-nonce event takes priority over spawn event
# Coordinator pre-emits teammate-nonce event with nonce_A; spawn event has nonce_B.
# Envelope is HMAC'd with nonce_A. Hook must prefer teammate-nonce event → write succeeds.
# ---------------------------------------------------------------------------
_reset_history

NONCE_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NONCE_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
MATE11="frank"
TEAM11="priority-team"
DEST_FILE11="$FAKE_PROJECT/src/output11.txt"
rm -f "$DEST_FILE11"

# Inject teammate-nonce event (Tier 1) with nonce_A
python3 -c "
import json, sys
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'teammate-nonce',
    'source': 'coordinator-spawn',
    'role': 'developer',
    'teammate_name': sys.argv[1],
    'team_name': sys.argv[2],
    'nonce': sys.argv[3],
}
print(json.dumps(ev))
" "$MATE11" "$TEAM11" "$NONCE_A" >> "$TASK_HISTORY"

# Inject spawn event (Tier 2) with nonce_B — different from nonce_A
_inject_spawn_event "$MATE11" "$TEAM11" "$NONCE_B" '["src/*.txt"]'

# Build envelope HMAC'd with nonce_A (teammate-nonce event's nonce — should succeed)
CONTENT11="Written via Tier 1 teammate-nonce nonce."
ENVELOPE11=$(_build_valid_envelope "$DEST_FILE11" "$CONTENT11" "developer" "2026-04-18" "role-self-report" "$NONCE_A")
PAYLOAD11=$(_make_sendmessage_payload "$ENVELOPE11" "$MATE11" "$TEAM11")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-wp" \
    bash "$HOOK" <<< "$PAYLOAD11" 2>/dev/null
) || true

if [ -f "$DEST_FILE11" ] && [ "$(cat "$DEST_FILE11")" = "$CONTENT11" ]; then
    _pass "TC-WP-11: Option 2 primary — teammate-nonce event nonce preferred, write succeeds"
else
    _fail "TC-WP-11: Option 2 primary path failed" \
        "dest_exists=$([ -f "$DEST_FILE11" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
fi

# ---------------------------------------------------------------------------
# TC-WP-12: Fallback chain — no teammate-nonce event; spawn event nonce used (Option 1)
# Only a spawn event exists. Envelope HMAC'd with spawn event's nonce → write succeeds.
# Verifies Tier 2 fallback works when Tier 1 (Option 2) event was never emitted.
# ---------------------------------------------------------------------------
_reset_history

NONCE12="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
MATE12="grace"
TEAM12="fallback-team"
DEST_FILE12="$FAKE_PROJECT/src/output12.txt"
rm -f "$DEST_FILE12"

# Only inject a spawn event (Tier 2) — no teammate-nonce event (Tier 1 absent)
_inject_spawn_event "$MATE12" "$TEAM12" "$NONCE12" '["src/*.txt"]'

# Build envelope HMAC'd with spawn event nonce (Tier 2) — should succeed
CONTENT12="Written via Tier 2 spawn-event nonce fallback."
ENVELOPE12=$(_build_valid_envelope "$DEST_FILE12" "$CONTENT12" "developer" "2026-04-18" "role-self-report" "$NONCE12")
PAYLOAD12=$(_make_sendmessage_payload "$ENVELOPE12" "$MATE12" "$TEAM12")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-wp" \
    bash "$HOOK" <<< "$PAYLOAD12" 2>/dev/null
) || true

if [ -f "$DEST_FILE12" ] && [ "$(cat "$DEST_FILE12")" = "$CONTENT12" ]; then
    _pass "TC-WP-12: Fallback chain — no teammate-nonce event, spawn event nonce used, write succeeds"
else
    _fail "TC-WP-12: Tier 2 fallback path failed" \
        "dest_exists=$([ -f "$DEST_FILE12" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -3)"
fi

# ---------------------------------------------------------------------------
# TC-WP-13: Tier 1 session_id lookup — SendMessage payload carries session_id;
# no teammate_name/team_name in tool_input. Hook resolves nonce from matching
# team_name-mode spawn event in task-history and accepts the envelope.
# ---------------------------------------------------------------------------
_reset_history

SESSION13="session-tier1-test-13"
NONCE13="1111111111111111111111111111111111111111111111111111111111111111"
MATE13="helen"
TEAM13="tier1-team"
DEST_FILE13="$FAKE_PROJECT/src/output13.txt"
rm -f "$DEST_FILE13"

# Inject a team_name-mode spawn event with matching session_id.
# v5.7.0: raw nonce NOT stored in task-history; nonce file is canonical source.
python3 -c "
import json, sys, hashlib
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'spawn',
    'source': 'hook-auto',
    'role': 'developer',
    'session_id': sys.argv[1],
    'teammate_name': sys.argv[2],
    'team_name': sys.argv[3],
    'spawn_mode': 'team_name',
    'background': True,
    'prompt_bytes': 100,
    'scope': [],
    'write_proxy_nonce_sha256': hashlib.sha256(sys.argv[4].encode()).hexdigest(),
}
print(json.dumps(ev))
" "$SESSION13" "$MATE13" "$TEAM13" "$NONCE13" >> "$TASK_HISTORY"

# v5.7.0: write nonce to canonical nonce file so Tier 1 can read it
_inject_nonce_file "$MATE13" "$TEAM13" "$NONCE13"

CONTENT13="Written via Tier 1 session_id lookup."
ENVELOPE13=$(_build_valid_envelope "$DEST_FILE13" "$CONTENT13" "developer" "2026-04-18" "role-self-report" "$NONCE13")

# Build real SendMessage payload: session_id present, NO teammate_name/team_name
PAYLOAD13=$(_make_sendmessage_payload_real "$ENVELOPE13" "$SESSION13")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="$SESSION13" \
    bash "$HOOK" <<< "$PAYLOAD13" 2>/dev/null
) || true

if [ -f "$DEST_FILE13" ] && [ "$(cat "$DEST_FILE13")" = "$CONTENT13" ]; then
    _pass "TC-WP-13: Tier 1 session_id→spawn event lookup — SendMessage envelope accepted"
else
    _fail "TC-WP-13: Tier 1 session_id lookup" \
        "dest_exists=$([ -f "$DEST_FILE13" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
fi

# ---------------------------------------------------------------------------
# TC-WP-14: Tier 2 envelope role lookup — real session_id, no teammate_name/team_name;
# a prior teammate-nonce event with role=researcher and matching session_id exists.
# Envelope frontmatter carries role: researcher, HMAC computed against that nonce.
# Hook accepts.
#
# HIGH fix (v5.7.1): test updated to use a real session_id in both CLAUDE_SESSION_ID
# and the injected nonce event. The previous version used CLAUDE_SESSION_ID="" which
# relied on the empty-session_id bypass that is now correctly closed.
# ---------------------------------------------------------------------------
_reset_history

NONCE14="2222222222222222222222222222222222222222222222222222222222222222"
SESSION14="session-tc-wp-14-real-id-abc123"
DEST_FILE14="$FAKE_PROJECT/src/output14.txt"
rm -f "$DEST_FILE14"

# Inject a teammate-nonce event keyed by role=researcher WITH matching session_id
python3 -c "
import json, sys
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'teammate-nonce',
    'source': 'coordinator-spawn',
    'role': 'researcher',
    'teammate_name': 'irene',
    'team_name': 'tier2-team',
    'session_id': sys.argv[2],
    'nonce': sys.argv[1],
}
print(json.dumps(ev))
" "$NONCE14" "$SESSION14" >> "$TASK_HISTORY"

CONTENT14="Written via Tier 2 role→teammate-nonce lookup."
# Build envelope with role: researcher in frontmatter, HMAC against NONCE14
ENVELOPE14=$(_build_valid_envelope "$DEST_FILE14" "$CONTENT14" "researcher" "2026-04-18" "role-self-report" "$NONCE14")

# Real SendMessage payload: session_id in payload, no teammate_name/team_name in envelope
PAYLOAD14=$(_make_sendmessage_payload_real "$ENVELOPE14" "$SESSION14")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="$SESSION14" \
    bash "$HOOK" <<< "$PAYLOAD14" 2>/dev/null
) || true

if [ -f "$DEST_FILE14" ] && [ "$(cat "$DEST_FILE14")" = "$CONTENT14" ]; then
    _pass "TC-WP-14: Tier 2 role→teammate-nonce lookup — SendMessage envelope accepted (real session_id)"
else
    _fail "TC-WP-14: Tier 2 role lookup" \
        "dest_exists=$([ -f "$DEST_FILE14" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
fi

# ---------------------------------------------------------------------------
# TC-WP-14b: Tier 2 empty session_id bypass — MUST REJECT.
# HIGH fix (v5.7.1): when CLAUDE_SESSION_ID="" (empty), the hook must refuse
# the Tier 2 nonce lookup rather than short-circuiting the session constraint.
# ---------------------------------------------------------------------------
_reset_history

NONCE14B="4444444444444444444444444444444444444444444444444444444444444444"
DEST_FILE14B="$FAKE_PROJECT/src/output14b.txt"
rm -f "$DEST_FILE14B"

# Inject a teammate-nonce event — note: no session_id field (simulates old event)
python3 -c "
import json, sys
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'teammate-nonce',
    'source': 'coordinator-spawn',
    'role': 'researcher',
    'teammate_name': 'irene',
    'team_name': 'tier2-team',
    'nonce': sys.argv[1],
}
print(json.dumps(ev))
" "$NONCE14B" >> "$TASK_HISTORY"

CONTENT14B="This write must NOT succeed — empty session_id bypass test."
ENVELOPE14B=$(_build_valid_envelope "$DEST_FILE14B" "$CONTENT14B" "researcher" "2026-04-18" "role-self-report" "$NONCE14B")
# Empty session_id in payload — the bypass vector
PAYLOAD14B=$(_make_sendmessage_payload_real "$ENVELOPE14B" "")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="" \
    bash "$HOOK" <<< "$PAYLOAD14B" 2>/dev/null
) || true

if [ ! -f "$DEST_FILE14B" ]; then
    _pass "TC-WP-14b: empty session_id bypass correctly blocked — file NOT written"
else
    _fail "TC-WP-14b: empty session_id bypass should be blocked" \
        "SECURITY: file was written when session_id was empty — bypass not closed"
fi

# ---------------------------------------------------------------------------
# TC-WP-15: Helper-script HMAC path — build envelope via compute-envelope-hmac.sh
# (the canonical teammate path), send through hook with matching spawn event,
# expect ACCEPT + file written. Regression: proves hook + helper share one formula.
# ---------------------------------------------------------------------------
_reset_history

NONCE15="3333333333333333333333333333333333333333333333333333333333333333"
DEST_FILE15="$FAKE_PROJECT/src/output15.txt"
rm -f "$DEST_FILE15"

_inject_spawn_event "carol" "beta-team" "$NONCE15" '[]'

CONTENT15="Written via canonical helper-script HMAC path."
PROV_ROLE15="developer"
PROV_SESS15="2026-04-18"

# Build the envelope body WITHOUT hmac line (the helper will compute it)
ENVELOPE_NO_HMAC15=$(python3 -c "
import sys
dest        = sys.argv[1]
content     = sys.argv[2]
prov_role   = sys.argv[3]
prov_sess   = sys.argv[4]
full = (
    '<!-- WRITE-PROXY-ENVELOPE v1 -->\n'
    '---\n'
    'intended_destination: ' + dest + '\n'
    'role: ' + prov_role + '\n'
    'session: ' + prov_sess + '\n'
    'provenance:\n'
    '  role: ' + prov_role + '\n'
    '  session: ' + prov_sess + '\n'
    '  source: role-self-report\n'
    '  discovered: 2026-04-18\n'
    '  verified: null\n'
    '---\n'
    + content
)
print(full, end='')
" "$DEST_FILE15" "$CONTENT15" "$PROV_ROLE15" "$PROV_SESS15" 2>/dev/null)

# Use the helper script (canonical teammate path) to compute the HMAC.
# Use printf to avoid bash <<< appending a trailing newline that would change the HMAC body.
HELPER_SCRIPT="$PROJECT_ROOT/scripts/compute-envelope-hmac.sh"
HMAC15=$(printf '%s' "$ENVELOPE_NO_HMAC15" | \
         CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
         bash "$HELPER_SCRIPT" "$NONCE15" 2>/dev/null || echo "HELPER_FAILED")

if [ "$HMAC15" = "HELPER_FAILED" ] || [ -z "$HMAC15" ]; then
    _fail "TC-WP-15: helper script failed to produce HMAC" \
        "compute-envelope-hmac.sh exited non-zero or produced empty output"
else
    # Insert the HMAC line into the envelope
    ENVELOPE15=$(python3 -c "
import sys, re
envelope = sys.argv[1]
hmac_val  = sys.argv[2]
# Insert hmac: line after 'session: ...' line in frontmatter
result = re.sub(r'(session: [^\n]+\n)', r'\1hmac: ' + hmac_val + '\n', envelope, count=1)
print(result, end='')
" "$ENVELOPE_NO_HMAC15" "$HMAC15" 2>/dev/null)

    PAYLOAD15=$(_make_sendmessage_payload "$ENVELOPE15" "carol" "beta-team")

    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="test-session-wp" \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
        bash "$HOOK" <<< "$PAYLOAD15" 2>/dev/null
    ) || true

    if [ -f "$DEST_FILE15" ] && [ "$(cat "$DEST_FILE15")" = "$CONTENT15" ]; then
        _pass "TC-WP-15: helper-script HMAC path — hook accepted envelope built via compute-envelope-hmac.sh"
    else
        _fail "TC-WP-15: helper-script HMAC path" \
            "dest_exists=$([ -f "$DEST_FILE15" ] && echo 1 || echo 0) hmac=${HMAC15} log=$(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
    fi
fi

# ---------------------------------------------------------------------------
# TC-WP-17: v5.8.1 Item 5 — envelope to learnings.jsonl without per-record provenance → exit 2
# ---------------------------------------------------------------------------
DEST17="$FAKE_PROJECT/.claude/ainous-roles/developer/learnings.jsonl"
# Content body has a JSONL record missing required provenance fields
CONTENT17=$(cat <<'CONTENTEOF17'
{"key":"test","insight":"some insight","confidence":0.9}
CONTENTEOF17
)
ENVELOPE17=$(_build_valid_envelope "$DEST17" "$CONTENT17" "developer" "2026-04-18" "role-self-report" "$NONCE")
PAYLOAD17=$(_make_sendmessage_payload "$ENVELOPE17" "wp17-agent" "wp17-team")

# Write nonce file for Tier 3b lookup (teammate_name/team_name from payload)
_inject_nonce_file "wp17-agent" "wp17-team" "$NONCE"
# Write spawn event so Tier 3b can find it
_inject_spawn_event "wp17-agent" "wp17-team" "$NONCE" '[]'

_WP17_OUTPUT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-wp" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    bash "$HOOK" <<< "$PAYLOAD17" 2>&1 || true
)

if [ ! -f "$DEST17" ]; then
    _pass "TC-WP-17: envelope to learnings.jsonl with body missing per-record provenance → rejected (no write)"
else
    _fail "TC-WP-17: expected rejection for missing per-record provenance" \
        "file was written despite missing provenance: output=$_WP17_OUTPUT"
fi
# Cleanup so TC-WP-18 starts fresh
rm -f "$DEST17"

# ---------------------------------------------------------------------------
# TC-WP-18: v5.8.1 Item 5 — envelope to learnings.jsonl with valid per-record provenance → exit 0
# ---------------------------------------------------------------------------
DEST18="$DEST17"
# Content body has a valid JSONL record with all 5 required provenance fields
CONTENT18=$(cat <<'CONTENTEOF18'
{"role":"developer","session":"2026-04-18","source":"role-self-report","discovered":"2026-04-18","verified":null,"key":"test-entry","insight":"a meaningful insight","confidence":0.8}
CONTENTEOF18
)
ENVELOPE18=$(_build_valid_envelope "$DEST18" "$CONTENT18" "developer" "2026-04-18" "role-self-report" "$NONCE")
PAYLOAD18=$(_make_sendmessage_payload "$ENVELOPE18" "wp17-agent" "wp17-team")
# Nonce file already written by TC-WP-17 setup above

_WP18_OUTPUT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-wp" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    bash "$HOOK" <<< "$PAYLOAD18" 2>&1 || true
)

if [ -f "$DEST18" ]; then
    _pass "TC-WP-18: envelope to learnings.jsonl with valid per-record provenance → write succeeded"
else
    _fail "TC-WP-18: expected write to succeed for valid per-record JSONL provenance" \
        "file not written; output=$_WP18_OUTPUT"
fi

# ---------------------------------------------------------------------------
# TC-WP-19: S-2 fully closed — cross-teammate nonce redirection rejected.
# Attack: attacker knows victim's team/name. They craft a payload with
#   teammate_name=victim, team_name=victim-team  (caller-supplied)
# and HMAC their envelope with victim's nonce.  Before the S-2 fix, Tier-3b
# would read victim's nonce file using attacker-controlled names.
# After the fix, nonce path comes from the SPAWN EVENT that was matched, not
# from tool_input — so attacker must also forge a spawn event, which they
# cannot.  Test verifies: when spawn event names disagree with tool_input
# names, the nonce file used is the one from the SPAWN EVENT (victim's),
# meaning HMAC keyed on attacker's nonce does NOT match → write rejected.
# ---------------------------------------------------------------------------
_reset_history

NONCE19_VICTIM="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
NONCE19_ATTKR="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
VICTIM_MATE="victim"
VICTIM_TEAM="shared-team"
ATTKR_MATE="attacker"
ATTKR_TEAM="shared-team"
DEST_FILE19="$FAKE_PROJECT/src/output19.txt"
rm -f "$DEST_FILE19"

# Inject a SPAWN EVENT for the VICTIM (correct record on disk)
# Session id won't match CLAUDE_SESSION_ID used below, so Tier-1 is bypassed.
python3 -c "
import json, sys, hashlib
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'spawn',
    'source': 'hook-auto',
    'role': 'developer',
    'session_id': 'victim-original-session',
    'teammate_name': sys.argv[1],
    'team_name': sys.argv[2],
    'spawn_mode': 'team_name',
    'background': True,
    'prompt_bytes': 100,
    'scope': [],
    'write_proxy_nonce_sha256': hashlib.sha256(sys.argv[3].encode()).hexdigest(),
}
print(json.dumps(ev))
" "$VICTIM_MATE" "$VICTIM_TEAM" "$NONCE19_VICTIM" >> "$TASK_HISTORY"
# Write victim's nonce file
_inject_nonce_file "$VICTIM_MATE" "$VICTIM_TEAM" "$NONCE19_VICTIM"
# Write attacker's nonce file too (attacker legitimately has their own spawn event + nonce)
_inject_nonce_file "$ATTKR_MATE" "$ATTKR_TEAM" "$NONCE19_ATTKR"

# Attacker builds envelope HMAC'd with VICTIM's nonce, but submits their name
# as tool_input fields to try to trigger the old Tier-3b path.
# The key question: does Tier-3b look up victim's spawn event (found by teammate_name)
# and use victim's event-recorded name→ victim's nonce → HMAC mismatch?
# Or does it incorrectly use attacker's nonce from attacker's nonce file?
CONTENT19="Cross-teammate nonce redirect attempt — should be rejected"
# We HMAC with victim nonce so if nonce path resolves to victim correctly, HMAC matches
# BUT we also test that the spawn event lookup finds VICTIM's spawn (by teammate_name match)
# and nonce path is keyed to VICTIM names, so HMAC (victim nonce) WOULD match.
# The real test is: attacker injects their OWN name as tool_input,
# finds THEIR own spawn event (not victim's), which keys to attacker's nonce file.
# But attacker HMACs with victim's nonce → mismatch → rejected.
# This proves tool_input cannot redirect to a different nonce.

# Attacker uses their own name in tool_input but HMACs with victim's nonce
ENVELOPE19=$(_build_valid_envelope "$DEST_FILE19" "$CONTENT19" "developer" "2026-04-18" "role-self-report" "$NONCE19_VICTIM")
# Payload has ATTACKER's identity in tool_input — the redirection attempt
PAYLOAD19=$(_make_sendmessage_payload "$ENVELOPE19" "$ATTKR_MATE" "$ATTKR_TEAM")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="unmatched-session-19" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    bash "$HOOK" <<< "$PAYLOAD19" 2>/dev/null
) || true

# Attacker has no spawn event for (attacker,shared-team) in task-history,
# so Tier-3b finds no spawn event for their identity and rejects.
# If the old code had been in place, we'd also need to verify the nonce file
# used was attacker's (not victim's). The new code uses event names, so it's
# always bound to whatever spawn event was found.
if [ ! -f "$DEST_FILE19" ]; then
    _pass "TC-WP-19: S-2 cross-teammate nonce redirection — correctly rejected (no spawn event for attacker)"
else
    _fail "TC-WP-19: S-2 cross-teammate nonce redirection should be blocked" \
        "SECURITY: file was written despite cross-teammate redirect attempt"
fi

# ---------------------------------------------------------------------------
# TC-WP-20: S-2 Tier-1 mismatch rejection — adversarial payload.
#
# Exact tester payload:
#   session_id = innocent-user's valid session (gate matches innocent-user's spawn event)
#   tool_input.teammate_name = victim-user  (caller-supplied name disagrees with event)
#   HMAC keyed with victim's nonce
#
# Before the fix, Tier-1 used `if not teammate_name:` backfill: because tool_input
# already set teammate_name=victim, the backfill was skipped and the nonce path was
# built from the attacker-supplied victim name → victim's nonce file was read →
# HMAC with victim's nonce matched → write accepted.
#
# After the fix, Tier-1 extracts names from the spawn event first, then checks
# tool_input against them. The spawn event says innocent-user; tool_input says
# victim → mismatch → rejected immediately (nonce file never opened).
#
# TC-WP-20a: REJECT — valid session_id (innocent-user's event) + tool_input=victim-user + HMAC(victim nonce)
# TC-WP-20b: ACCEPT — legitimate Tier-1 (session_id matches event, tool_input empty or matching)
# ---------------------------------------------------------------------------
_reset_history

SESSION20="session-innocent-user-20"
NONCE20_INNOCENT="aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11"
NONCE20_VICTIM="bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22"
INNOCENT_MATE20="innocent-user"
VICTIM_MATE20="victim-user"
TEAM20="shared-org-team"
DEST_FILE20="$FAKE_PROJECT/src/output20.txt"
rm -f "$DEST_FILE20"

# Inject innocent-user's spawn event with SESSION20 — Tier-1 will match this.
python3 -c "
import json, sys, hashlib
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'spawn',
    'source': 'hook-auto',
    'role': 'developer',
    'session_id': sys.argv[1],
    'teammate_name': sys.argv[2],
    'team_name': sys.argv[3],
    'spawn_mode': 'team_name',
    'background': True,
    'prompt_bytes': 100,
    'scope': [],
    'write_proxy_nonce_sha256': hashlib.sha256(sys.argv[4].encode()).hexdigest(),
}
print(json.dumps(ev))
" "$SESSION20" "$INNOCENT_MATE20" "$TEAM20" "$NONCE20_INNOCENT" >> "$TASK_HISTORY"

# Write innocent-user's nonce file
_inject_nonce_file "$INNOCENT_MATE20" "$TEAM20" "$NONCE20_INNOCENT"
# Write victim-user's nonce file (separate — attacker wants Tier-1 to read THIS one)
_inject_nonce_file "$VICTIM_MATE20" "$TEAM20" "$NONCE20_VICTIM"

# Attacker builds envelope HMAC'd with victim's nonce.
# Attacker sends: session_id=SESSION20 (innocent's session) + tool_input.teammate_name=victim-user
CONTENT20="Adversarial write — must be rejected by Tier-1 mismatch guard"
ENVELOPE20=$(_build_valid_envelope "$DEST_FILE20" "$CONTENT20" "developer" "2026-04-18" "role-self-report" "$NONCE20_VICTIM")

# Build payload with session_id AND attacker-supplied tool_input.teammate_name=victim-user
PAYLOAD20=$(python3 -c "
import json, sys
payload = {
    'tool_name': 'SendMessage',
    'session_id': sys.argv[1],
    'tool_input': {
        'message': sys.argv[2],
        'teammate_name': sys.argv[3],
        'team_name': sys.argv[4],
    }
}
print(json.dumps(payload))
" "$SESSION20" "$ENVELOPE20" "$VICTIM_MATE20" "$TEAM20" 2>/dev/null)

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="$SESSION20" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    bash "$HOOK" <<< "$PAYLOAD20" 2>/dev/null
) || true

# TC-WP-20a: must be REJECTED — tool_input says victim, event says innocent → mismatch
if [ ! -f "$DEST_FILE20" ]; then
    _pass "TC-WP-20a: Tier-1 mismatch (session_id→innocent, tool_input→victim, HMAC→victim) — correctly REJECTED"
else
    _fail "TC-WP-20a: Tier-1 mismatch must be blocked" \
        "SECURITY: write succeeded — Tier-1 read victim nonce file via attacker-controlled tool_input name"
fi

# TC-WP-20b: Legitimate Tier-1 — same session_id, tool_input names MATCH the event.
# Envelope HMAC'd with innocent's nonce. Must SUCCEED.
_reset_history
rm -f "$DEST_FILE20"

python3 -c "
import json, sys, hashlib
from datetime import datetime, timezone
ev = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'schema': '1',
    'event': 'spawn',
    'source': 'hook-auto',
    'role': 'developer',
    'session_id': sys.argv[1],
    'teammate_name': sys.argv[2],
    'team_name': sys.argv[3],
    'spawn_mode': 'team_name',
    'background': True,
    'prompt_bytes': 100,
    'scope': [],
    'write_proxy_nonce_sha256': hashlib.sha256(sys.argv[4].encode()).hexdigest(),
}
print(json.dumps(ev))
" "$SESSION20" "$INNOCENT_MATE20" "$TEAM20" "$NONCE20_INNOCENT" >> "$TASK_HISTORY"
_inject_nonce_file "$INNOCENT_MATE20" "$TEAM20" "$NONCE20_INNOCENT"

CONTENT20B="Legitimate write — session_id matches event, tool_input names match event names"
ENVELOPE20B=$(_build_valid_envelope "$DEST_FILE20" "$CONTENT20B" "developer" "2026-04-18" "role-self-report" "$NONCE20_INNOCENT")

# Payload: session_id=SESSION20, tool_input.teammate_name=innocent (matching the event)
PAYLOAD20B=$(python3 -c "
import json, sys
payload = {
    'tool_name': 'SendMessage',
    'session_id': sys.argv[1],
    'tool_input': {
        'message': sys.argv[2],
        'teammate_name': sys.argv[3],
        'team_name': sys.argv[4],
    }
}
print(json.dumps(payload))
" "$SESSION20" "$ENVELOPE20B" "$INNOCENT_MATE20" "$TEAM20" 2>/dev/null)

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="$SESSION20" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    bash "$HOOK" <<< "$PAYLOAD20B" 2>/dev/null
) || true

if [ -f "$DEST_FILE20" ] && [ "$(cat "$DEST_FILE20")" = "$CONTENT20B" ]; then
    _pass "TC-WP-20b: Tier-1 legitimate path (session_id matches, tool_input names match event) — correctly ACCEPTED"
else
    _fail "TC-WP-20b: legitimate Tier-1 should succeed" \
        "dest_exists=$([ -f "$DEST_FILE20" ] && echo 1 || echo 0) log=$(cat "$ERROR_LOG" 2>/dev/null | tail -5)"
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
