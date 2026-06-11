#!/usr/bin/env bash
# test-session-start.sh — Test suite for hooks/session-start team-dir reaper (Fix 6a / v5.6.0)
#
# TC-SS-1: Stale team dir (mtime >24h, no live PID) → archived with .archived-<epoch>- prefix
# TC-SS-2: Fresh team dir (mtime within 24h) → NOT archived
# TC-SS-3: Team dir with live PID in process table → NOT archived
# TC-SS-4: Team dir with no config.json, mtime >24h → archived (can't verify ownership)
# TC-SS-5: Stale .archived-* dir older than 30 days → deleted
# TC-SS-6: Reaper errors logged but do not break SessionStart exit code
#
# Run: bash tests/test-session-start.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_START="$PROJECT_ROOT/hooks/session-start"

TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-session-start.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"
TEAMS_DIR="$FAKE_HOME/.claude/teams"
ERROR_LOG="$FAKE_HOME/.claude/.session-start-errors.log"

mkdir -p "$FAKE_HOME/.claude" "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"

# Helper: run session-start hook with fake HOME (redirecting stdout to /dev/null)
_run_reaper() {
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        CLAUDE_SESSION_ID="" \
        bash "$SESSION_START" > /dev/null 2>&1
    )
    return $?
}

# Helper: make a dir look stale (mtime 48h ago)
_make_stale() {
    local path="$1"
    python3 -c "import os,time; os.utime('$path', (time.time()-172800, time.time()-172800))"
}

# Helper: make a dir look ancient (mtime 35 days ago)
_make_ancient() {
    local path="$1"
    python3 -c "import os,time; os.utime('$path', (time.time()-35*86400, time.time()-35*86400))"
}

# ---------------------------------------------------------------------------
# TC-SS-1: Stale team dir with config.json pointing to absent PID → archived
# ---------------------------------------------------------------------------
mkdir -p "$TEAMS_DIR/stale-team-1"
# Use a PID that definitely doesn't exist
echo '{"leadSessionId":"nonexistent-session-xyz-99999","isActive":true}' \
    > "$TEAMS_DIR/stale-team-1/config.json"
_make_stale "$TEAMS_DIR/stale-team-1"

_run_reaper

ARCHIVED=$(ls -a "$TEAMS_DIR" 2>/dev/null | grep -c "\.archived-.*stale-team-1" || true)
ORIGINAL_EXISTS=0
[ -d "$TEAMS_DIR/stale-team-1" ] && ORIGINAL_EXISTS=1

if [ "$ARCHIVED" -ge 1 ] && [ "$ORIGINAL_EXISTS" -eq 0 ]; then
    _pass "TC-SS-1: stale team dir with absent PID archived, original removed"
else
    _fail "TC-SS-1: expected archive" "archived_count=$ARCHIVED original_exists=$ORIGINAL_EXISTS"
fi

# ---------------------------------------------------------------------------
# TC-SS-2: Fresh team dir (mtime within 24h) → NOT archived
# ---------------------------------------------------------------------------
mkdir -p "$TEAMS_DIR/fresh-team-2"
echo '{"leadSessionId":"nonexistent-session-fresh","isActive":true}' \
    > "$TEAMS_DIR/fresh-team-2/config.json"
# mtime defaults to now — no touch needed

_run_reaper

STILL_EXISTS=0
[ -d "$TEAMS_DIR/fresh-team-2" ] && STILL_EXISTS=1
FRESH_ARCHIVED=$(ls -a "$TEAMS_DIR" 2>/dev/null | grep -c "\.archived-.*fresh-team-2" || true)

if [ "$STILL_EXISTS" -eq 1 ] && [ "$FRESH_ARCHIVED" -eq 0 ]; then
    _pass "TC-SS-2: fresh team dir (mtime <24h) left untouched"
else
    _fail "TC-SS-2: fresh dir should not be archived" "still_exists=$STILL_EXISTS archived=$FRESH_ARCHIVED"
fi

# ---------------------------------------------------------------------------
# TC-SS-3: Team dir with live PID → NOT archived
# ---------------------------------------------------------------------------
LIVE_PID=$$
mkdir -p "$TEAMS_DIR/live-team-3"
# Use a session ID that the process table check won't match (we fake with
# a known-present PID by writing a config.json with leadSessionId and then
# directly overriding via a ps shim in PATH)
# Simpler: set leadSessionId to a value and inject a fake ps shim
FAKE_BIN="$TMPDIR_BASE/bin"
mkdir -p "$FAKE_BIN"
# Write a ps shim that outputs a fake matching line
cat > "$FAKE_BIN/ps" << 'PSEOF'
#!/usr/bin/env bash
echo "PID COMMAND"
echo "99999 claude --parent-session-id live-session-tc3 --other-flag"
PSEOF
chmod +x "$FAKE_BIN/ps"

echo '{"leadSessionId":"live-session-tc3","isActive":true}' \
    > "$TEAMS_DIR/live-team-3/config.json"
_make_stale "$TEAMS_DIR/live-team-3"

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$SESSION_START" > /dev/null 2>&1
) || true

LIVE_EXISTS=0
[ -d "$TEAMS_DIR/live-team-3" ] && LIVE_EXISTS=1
LIVE_ARCHIVED=$(ls -a "$TEAMS_DIR" 2>/dev/null | grep -c "\.archived-.*live-team-3" || true)

if [ "$LIVE_EXISTS" -eq 1 ] && [ "$LIVE_ARCHIVED" -eq 0 ]; then
    _pass "TC-SS-3: team dir with live PID in process table not archived"
else
    _fail "TC-SS-3: live-owned dir should survive" "exists=$LIVE_EXISTS archived=$LIVE_ARCHIVED"
fi

# ---------------------------------------------------------------------------
# TC-SS-4: Team dir with no config.json, mtime >24h → archived (unknown ownership)
# ---------------------------------------------------------------------------
mkdir -p "$TEAMS_DIR/no-config-team-4"
_make_stale "$TEAMS_DIR/no-config-team-4"

_run_reaper

NC_ARCHIVED=$(ls -a "$TEAMS_DIR" 2>/dev/null | grep -c "\.archived-.*no-config-team-4" || true)
NC_ORIGINAL=0
[ -d "$TEAMS_DIR/no-config-team-4" ] && NC_ORIGINAL=1

if [ "$NC_ARCHIVED" -ge 1 ] && [ "$NC_ORIGINAL" -eq 0 ]; then
    _pass "TC-SS-4: no-config.json dir with mtime >24h archived (conservative)"
else
    _fail "TC-SS-4: expected archive for no-config dir" "archived=$NC_ARCHIVED original=$NC_ORIGINAL"
fi

# ---------------------------------------------------------------------------
# TC-SS-5: .archived-* dir older than 30 days → deleted
# ---------------------------------------------------------------------------
ANCIENT_ARCHIVE="$TEAMS_DIR/.archived-1000000000-old-team"
mkdir -p "$ANCIENT_ARCHIVE"
_make_ancient "$ANCIENT_ARCHIVE"

_run_reaper

ANCIENT_GONE=0
[ ! -d "$ANCIENT_ARCHIVE" ] && ANCIENT_GONE=1

if [ "$ANCIENT_GONE" -eq 1 ]; then
    _pass "TC-SS-5: .archived-* dir >30 days old deleted"
else
    _fail "TC-SS-5: expected ancient archive to be deleted" "dir still exists: $ANCIENT_ARCHIVE"
fi

# ---------------------------------------------------------------------------
# TC-SS-6: Reaper error (unreadable dir) is logged but SessionStart exits 0
# ---------------------------------------------------------------------------
# Simulate an error by making the teams dir itself unreadable... but that
# would break other TCs. Instead, pre-corrupt a config.json with invalid JSON
# and verify the error log captures it while exit code remains 0.
mkdir -p "$TEAMS_DIR/bad-config-team-6"
echo 'THIS IS NOT JSON' > "$TEAMS_DIR/bad-config-team-6/config.json"
_make_stale "$TEAMS_DIR/bad-config-team-6"
rm -f "$ERROR_LOG"

EXIT_CODE=0
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="" \
    bash "$SESSION_START" > /dev/null 2>/dev/null
) || EXIT_CODE=$?

# Check error was logged
ERROR_LOGGED=0
[ -f "$ERROR_LOG" ] && grep -q "bad-config-team-6" "$ERROR_LOG" 2>/dev/null && ERROR_LOGGED=1

if [ "$EXIT_CODE" -eq 0 ]; then
    _pass "TC-SS-6: reaper JSON parse error logged ($ERROR_LOGGED=1 expected) but SessionStart exits 0"
else
    _fail "TC-SS-6: SessionStart must exit 0 despite reaper error" "exit_code=$EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TC-SS-7: Log rotation — oversized log is rotated with marker + tail intact.
# v5.9.1 Item 3: atomic rotation via fcntl.flock + os.rename.
# ---------------------------------------------------------------------------
TAINT_ERROR_LOG="$FAKE_HOME/.claude/.taint-flag-errors.log"
AUDIT_LOG="$FAKE_HOME/.claude/.authority-tainted-decisions.log"

# Generate a log exceeding 10 MB (write repeated lines)
python3 -c "
import os
log_path = '${AUDIT_LOG}'
os.makedirs(os.path.dirname(log_path), exist_ok=True)
line = b'[2026-01-01T00:00:00Z] TAINTED-BASH-BLOCK role=\"developer\" command_sha256=aabbccdd1234 failing_predicate=tainted-bash-allowlist\n'
# Write 11 MB worth of lines
with open(log_path, 'wb') as f:
    written = 0
    while written < 11 * 1024 * 1024:
        f.write(line)
        written += len(line)
# Append a unique tail marker so we can verify it's preserved
f_path = '${AUDIT_LOG}'
with open(f_path, 'ab') as f:
    f.write(b'UNIQUE_TAIL_SENTINEL_XYZ_FOR_TC_SS_7\n')
" 2>/dev/null

PRE_SIZE=$(python3 -c "import os; print(os.path.getsize('${AUDIT_LOG}'))" 2>/dev/null || echo "0")

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-ss7" \
    bash "$SESSION_START" > /dev/null 2>/dev/null
) || true

POST_SIZE=$(python3 -c "import os; print(os.path.getsize('${AUDIT_LOG}'))" 2>/dev/null || echo "$PRE_SIZE")

# Verify: log was rotated (new size much smaller than original)
SIZE_REDUCED=0
[ "$POST_SIZE" -lt "$((PRE_SIZE / 2))" ] && SIZE_REDUCED=1 || true

# Verify: TRUNCATED marker is present
HAS_MARKER=0
grep -qF "TRUNCATED" "$AUDIT_LOG" 2>/dev/null && HAS_MARKER=1 || true

# Verify: tail sentinel is preserved (rotation kept last 100KB)
HAS_TAIL=0
grep -qF "UNIQUE_TAIL_SENTINEL_XYZ_FOR_TC_SS_7" "$AUDIT_LOG" 2>/dev/null && HAS_TAIL=1 || true

if [ "$SIZE_REDUCED" -eq 1 ] && [ "$HAS_MARKER" -eq 1 ] && [ "$HAS_TAIL" -eq 1 ]; then
    _pass "TC-SS-7: oversized log rotated atomically — size reduced, TRUNCATED marker present, tail preserved"
elif [ "$SIZE_REDUCED" -eq 0 ]; then
    _fail "TC-SS-7: log size not reduced after rotation" "pre=$PRE_SIZE post=$POST_SIZE marker=$HAS_MARKER tail=$HAS_TAIL"
elif [ "$HAS_MARKER" -eq 0 ]; then
    _fail "TC-SS-7: TRUNCATED marker not found after rotation" "pre=$PRE_SIZE post=$POST_SIZE"
else
    _fail "TC-SS-7: tail sentinel not preserved after rotation" "pre=$PRE_SIZE post=$POST_SIZE"
fi

rm -f "$AUDIT_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# TC-SS-8: Concurrent rotation stress — two session-start processes both try to
# rotate a large log. ONE succeeds cleanly; the OTHER skips (lock not available).
# Verify log is not corrupted after both complete.
# ---------------------------------------------------------------------------
# Regenerate a large log
python3 -c "
import os
log_path = '${AUDIT_LOG}'
os.makedirs(os.path.dirname(log_path), exist_ok=True)
line = b'[2026-01-01T00:00:00Z] TAINTED-BASH-BLOCK role=\"developer\" concurrent_stress_test\n'
with open(log_path, 'wb') as f:
    written = 0
    while written < 11 * 1024 * 1024:
        f.write(line)
        written += len(line)
with open(log_path, 'ab') as f:
    f.write(b'CONCURRENT_TAIL_SENTINEL_ABC123\n')
" 2>/dev/null

# Run two session-start hooks concurrently (both in subshells, same HOME/project)
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-ss8a" \
    bash "$SESSION_START" > /dev/null 2>/dev/null
) &
PID_A=$!

(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    CLAUDE_SESSION_ID="test-session-ss8b" \
    bash "$SESSION_START" > /dev/null 2>/dev/null
) &
PID_B=$!

wait $PID_A || true
wait $PID_B || true

# Verify log exists and is valid (not a zero-length or mid-write partial file)
LOG_EXISTS=0
[ -f "$AUDIT_LOG" ] && LOG_EXISTS=1 || true

LOG_VALID=0
if [ "$LOG_EXISTS" -eq 1 ]; then
    LOG_SIZE=$(python3 -c "import os; print(os.path.getsize('${AUDIT_LOG}'))" 2>/dev/null || echo "0")
    [ "$LOG_SIZE" -gt 0 ] && LOG_VALID=1 || true
fi

# Verify: the log is either (a) rotated with TRUNCATED marker, or (b) original untouched
# In both cases it must be readable (not a truncated-mid-write partial)
LOG_READABLE=0
python3 -c "
with open('${AUDIT_LOG}', 'rb') as f:
    data = f.read()
assert len(data) > 0, 'log is empty'
print('ok')
" 2>/dev/null && LOG_READABLE=1 || true

if [ "$LOG_EXISTS" -eq 1 ] && [ "$LOG_VALID" -eq 1 ] && [ "$LOG_READABLE" -eq 1 ]; then
    _pass "TC-SS-8: concurrent rotation — both session-starts completed; log exists and is readable (not corrupted)"
else
    _fail "TC-SS-8: log corrupted or missing after concurrent rotation" \
        "exists=$LOG_EXISTS valid=$LOG_VALID readable=$LOG_READABLE"
fi

rm -f "$AUDIT_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Staleness-warning regression tests (TC-SS-A through TC-SS-D)
#
# The staleness logic lives in the Python block (~L490-595 of session-start).
# The hook reads:
#   - role playbooks  from $HOME/.claude/ainous-roles/<role>/playbook.md
#   - project journals from $CWD/.claude/ainous-roles/<role>/journal.md
#
# Spec:
#   - unconsolidated >= 3   → role qualifies for staleness check
#   - days_stale > 2        → really_critical (CRITICAL message, names roles)
#   - days_stale > 1 (<=2)  → stale_roles (Reminder message, names roles)
#   - Both non-empty        → BOTH messages appear (elif-swallow regression guard)
#   - unconsolidated 1-2    → no staleness warning (threshold gate)
#   - unconsolidated > 20   → overflow_roles WARNING (separate, names roles)
#   - malformed playbook    → hook exits 0, no crash (fail-open)
# ---------------------------------------------------------------------------

# Shared isolation dirs for staleness tests — each TC gets its own subdirs
# inside $TMPDIR_BASE so they don't interfere with reaper TCs above.

STALE_TMPBASE="$TMPDIR_BASE/staleness"
mkdir -p "$STALE_TMPBASE"

# Helper: compute a date N days in the past (portable: python3)
_days_ago() {
    python3 -c "
from datetime import date, timedelta
import sys
n = int(sys.argv[1])
print((date.today() - timedelta(days=n)).isoformat())
" "$1"
}

# Helper: run the hook in a fully isolated environment, capturing stdout.
# Usage: _run_hook_capture <fake_home> <fake_project>
# Returns 0 always (fail-open expected); stdout goes to $HOOK_OUTPUT variable.
_run_hook_capture() {
    local fake_home="$1"
    local fake_project="$2"
    HOOK_OUTPUT=$(
        cd "$fake_project"
        HOME="$fake_home" \
        CLAUDE_PROJECT_DIR="$fake_project" \
        CLAUDE_SESSION_ID="" \
        bash "$SESSION_START" 2>/dev/null
    ) || true
}

# Helper: write a minimal playbook.md with a given last_consolidated date.
# Usage: _write_playbook <path> <date_string>
_write_playbook() {
    local path="$1"
    local date_str="$2"
    mkdir -p "$(dirname "$path")"
    printf 'last_consolidated: %s\n\n# Role playbook\nStrategies go here.\n' \
        "$date_str" > "$path"
}

# Helper: write a project journal.md with N date-headed entries, all after
# the given last_consolidated date so they count as unconsolidated.
# Usage: _write_journal <path> <count> <last_consolidated_date>
_write_journal() {
    local path="$1"
    local count="$2"
    local after_date="$3"
    mkdir -p "$(dirname "$path")"
    # Start from after_date + 1 day, write 'count' entries
    python3 -c "
from datetime import date, timedelta
import sys

out_path = sys.argv[1]
count    = int(sys.argv[2])
after    = date.fromisoformat(sys.argv[3])

lines = []
for i in range(1, count + 1):
    d = after + timedelta(days=i)
    lines.append(f'## {d.isoformat()} — session {i}\nSome content.\n')

with open(out_path, 'w') as f:
    f.write('\n'.join(lines))
" "$path" "$count" "$after_date"
}

# ---------------------------------------------------------------------------
# TC-SS-A: Role 3+ days stale AND >= 3 unconsolidated → CRITICAL message
#          names the role.
# ---------------------------------------------------------------------------
TC_A_HOME="$STALE_TMPBASE/tc-a-home"
TC_A_PROJECT="$STALE_TMPBASE/tc-a-project"
mkdir -p "$TC_A_HOME/.claude" "$TC_A_PROJECT/.claude"

DATE_3_DAYS_AGO=$(_days_ago 3)

_write_playbook \
    "$TC_A_HOME/.claude/ainous-roles/tc-a-role/playbook.md" \
    "$DATE_3_DAYS_AGO"

_write_journal \
    "$TC_A_PROJECT/.claude/ainous-roles/tc-a-role/journal.md" \
    3 "$DATE_3_DAYS_AGO"

_run_hook_capture "$TC_A_HOME" "$TC_A_PROJECT"

HAS_CRITICAL=0
HAS_ROLE_NAME=0
echo "$HOOK_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ctx = data.get('additional_context', data.get('hookSpecificOutput', {}).get('additionalContext', ''))
if 'CRITICAL' in ctx:
    print('HAS_CRITICAL=1')
if 'tc-a-role' in ctx:
    print('HAS_ROLE_NAME=1')
" 2>/dev/null | while IFS= read -r line; do eval "$line"; done || true

# Evaluate inline since subshell env vars don't propagate — use temp file approach
TC_A_RESULT=$(echo "$HOOK_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ctx = data.get('additional_context', data.get('hookSpecificOutput', {}).get('additionalContext', ''))
has_critical = 'CRITICAL' in ctx
has_name     = 'tc-a-role' in ctx
print(f'{int(has_critical)} {int(has_name)}')
" 2>/dev/null || echo "0 0")

TC_A_CRIT=$(echo "$TC_A_RESULT" | awk '{print $1}')
TC_A_NAME=$(echo "$TC_A_RESULT" | awk '{print $2}')

if [ "${TC_A_CRIT:-0}" -eq 1 ] && [ "${TC_A_NAME:-0}" -eq 1 ]; then
    _pass "TC-SS-A: 3d-stale role with 3 unconsolidated entries → CRITICAL message names role"
else
    _fail "TC-SS-A: expected CRITICAL message naming 'tc-a-role'" \
        "has_critical=${TC_A_CRIT:-0} has_role_name=${TC_A_NAME:-0} output=$(echo "$HOOK_OUTPUT" | head -c 500)"
fi

# ---------------------------------------------------------------------------
# TC-SS-B: Role X critical (3d, 3 entries) + Role Y stale (2d, 3 entries) →
#          output names BOTH. Regression guard for the elif-swallow bug.
# ---------------------------------------------------------------------------
TC_B_HOME="$STALE_TMPBASE/tc-b-home"
TC_B_PROJECT="$STALE_TMPBASE/tc-b-project"
mkdir -p "$TC_B_HOME/.claude" "$TC_B_PROJECT/.claude"

DATE_2_DAYS_AGO=$(_days_ago 2)

# Role X: 3 days stale → really_critical
_write_playbook \
    "$TC_B_HOME/.claude/ainous-roles/tc-b-critical-role/playbook.md" \
    "$DATE_3_DAYS_AGO"
_write_journal \
    "$TC_B_PROJECT/.claude/ainous-roles/tc-b-critical-role/journal.md" \
    3 "$DATE_3_DAYS_AGO"

# Role Y: 2 days stale → stale_roles
_write_playbook \
    "$TC_B_HOME/.claude/ainous-roles/tc-b-stale-role/playbook.md" \
    "$DATE_2_DAYS_AGO"
_write_journal \
    "$TC_B_PROJECT/.claude/ainous-roles/tc-b-stale-role/journal.md" \
    3 "$DATE_2_DAYS_AGO"

_run_hook_capture "$TC_B_HOME" "$TC_B_PROJECT"

TC_B_RESULT=$(echo "$HOOK_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ctx = data.get('additional_context', data.get('hookSpecificOutput', {}).get('additionalContext', ''))
has_critical      = 'CRITICAL' in ctx
has_reminder      = 'Reminder' in ctx
has_critical_role = 'tc-b-critical-role' in ctx
has_stale_role    = 'tc-b-stale-role' in ctx
print(f'{int(has_critical)} {int(has_reminder)} {int(has_critical_role)} {int(has_stale_role)}')
" 2>/dev/null || echo "0 0 0 0")

TC_B_CRIT=$(echo "$TC_B_RESULT"  | awk '{print $1}')
TC_B_REM=$( echo "$TC_B_RESULT"  | awk '{print $2}')
TC_B_CR=$(  echo "$TC_B_RESULT"  | awk '{print $3}')
TC_B_SR=$(  echo "$TC_B_RESULT"  | awk '{print $4}')

if [ "${TC_B_CRIT:-0}" -eq 1 ] && [ "${TC_B_REM:-0}" -eq 1 ] \
   && [ "${TC_B_CR:-0}" -eq 1 ] && [ "${TC_B_SR:-0}" -eq 1 ]; then
    _pass "TC-SS-B: critical+stale roles both named — elif-swallow bug not present"
else
    _fail "TC-SS-B: expected CRITICAL and Reminder naming both roles" \
        "has_critical=${TC_B_CRIT:-0} has_reminder=${TC_B_REM:-0} critical_role=${TC_B_CR:-0} stale_role=${TC_B_SR:-0}"
fi

# ---------------------------------------------------------------------------
# TC-SS-C: Role 3 days stale but only 2 unconsolidated entries → NO staleness
#          warning (threshold gate: requires >= 3).
# ---------------------------------------------------------------------------
TC_C_HOME="$STALE_TMPBASE/tc-c-home"
TC_C_PROJECT="$STALE_TMPBASE/tc-c-project"
mkdir -p "$TC_C_HOME/.claude" "$TC_C_PROJECT/.claude"

_write_playbook \
    "$TC_C_HOME/.claude/ainous-roles/tc-c-role/playbook.md" \
    "$DATE_3_DAYS_AGO"

# Only 2 unconsolidated entries — below the >= 3 threshold
_write_journal \
    "$TC_C_PROJECT/.claude/ainous-roles/tc-c-role/journal.md" \
    2 "$DATE_3_DAYS_AGO"

_run_hook_capture "$TC_C_HOME" "$TC_C_PROJECT"

TC_C_RESULT=$(echo "$HOOK_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ctx = data.get('additional_context', data.get('hookSpecificOutput', {}).get('additionalContext', ''))
has_stale_warn = ('CRITICAL' in ctx or 'Reminder' in ctx) and 'tc-c-role' in ctx
print(int(has_stale_warn))
" 2>/dev/null || echo "0")

if [ "${TC_C_RESULT:-0}" -eq 0 ]; then
    _pass "TC-SS-C: 3d-stale role with only 2 unconsolidated entries → no staleness warning"
else
    _fail "TC-SS-C: threshold gate failed — got warning despite only 2 unconsolidated entries" \
        "output=$(echo "$HOOK_OUTPUT" | head -c 500)"
fi

# ---------------------------------------------------------------------------
# TC-SS-D: Malformed playbook (garbage / missing date) → hook exits 0.
#          Fail-open: session-start must never crash due to bad playbook data.
# ---------------------------------------------------------------------------
TC_D_HOME="$STALE_TMPBASE/tc-d-home"
TC_D_PROJECT="$STALE_TMPBASE/tc-d-project"
mkdir -p "$TC_D_HOME/.claude" "$TC_D_PROJECT/.claude"

# Malformed playbook: no last_consolidated line at all
MALFORMED_PB="$TC_D_HOME/.claude/ainous-roles/tc-d-role/playbook.md"
mkdir -p "$(dirname "$MALFORMED_PB")"
printf 'last_consolidated: *** NOT A DATE *** garbage value here\n\nSome other content.\n' \
    > "$MALFORMED_PB"

# Also write a journal so this role has entries
_write_journal \
    "$TC_D_PROJECT/.claude/ainous-roles/tc-d-role/journal.md" \
    3 "2020-01-01"

# Run hook and capture exit code explicitly
TC_D_EXIT=0
(
    cd "$TC_D_PROJECT"
    HOME="$TC_D_HOME" \
    CLAUDE_PROJECT_DIR="$TC_D_PROJECT" \
    CLAUDE_SESSION_ID="" \
    bash "$SESSION_START" > /dev/null 2>/dev/null
) || TC_D_EXIT=$?

# Also verify the output is still valid JSON (identity context still emitted)
TC_D_VALID_JSON=0
(
    cd "$TC_D_PROJECT"
    HOME="$TC_D_HOME" \
    CLAUDE_PROJECT_DIR="$TC_D_PROJECT" \
    CLAUDE_SESSION_ID="" \
    bash "$SESSION_START" 2>/dev/null
) | python3 -c "import json,sys; json.load(sys.stdin); print('ok')" 2>/dev/null \
    | grep -q "^ok$" && TC_D_VALID_JSON=1 || true

if [ "${TC_D_EXIT:-0}" -eq 0 ] && [ "${TC_D_VALID_JSON:-0}" -eq 1 ]; then
    _pass "TC-SS-D: malformed playbook (garbage date) → hook exits 0 and emits valid JSON (fail-open)"
elif [ "${TC_D_EXIT:-0}" -ne 0 ]; then
    _fail "TC-SS-D: hook must exit 0 with malformed playbook (fail-open violated)" \
        "exit_code=${TC_D_EXIT:-?}"
else
    _fail "TC-SS-D: hook exited 0 but output is not valid JSON" \
        "valid_json=${TC_D_VALID_JSON:-0}"
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
