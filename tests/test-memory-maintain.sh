#!/usr/bin/env bash
# test-memory-maintain.sh — Test suite for scripts/memory-maintain.py
#
# Tests:
#   TC-MM-1:  enforce_session_cap — >50 entries trimmed to 50 + oldest archived
#   TC-MM-2:  enforce_session_cap — exactly 50 entries untouched
#   TC-MM-3:  enforce_session_cap — <50 entries untouched
#   TC-MM-4:  enforce_session_cap — WAL leaves no .new residue after success
#   TC-MM-5:  dedup_learnings — duplicate (key,type) collapses to latest entry
#   TC-MM-6:  dedup_learnings — distinct (key,type) pairs all preserved
#   TC-MM-7:  prune_orphan_learnings — all-missing files[] entries pruned
#   TC-MM-8:  prune_orphan_learnings — at least one existing file → entry kept
#   TC-MM-9:  prune_orphan_learnings — empty files[] field → entry kept
#   TC-MM-10: prune_orphan_learnings — absent files field → entry kept
#   TC-MM-11: rotate_expired_decisions — expired entry moved to archive; active kept
#   TC-MM-12: rotate_expired_decisions — active-only decisions file unchanged
#   TC-MM-13: flag_stale_facts — old fact annotated; fresh fact not annotated
#   TC-MM-14: verify_index_integrity — broken link removed; valid link kept
#   TC-MM-15: --check/--dry-run NEVER mutates (session cap violation detected)
#   TC-MM-16: --check/--dry-run NEVER mutates (dedup violation detected)
#   TC-MM-17: verify_index_integrity — line with one valid + one broken link keeps valid link
#   TC-MM-18: verify_index_integrity — relative link to sibling file is NOT removed
#   TC-MM-19: trust_audit — stored level exceeds justified → clamped down
#   TC-MM-20: trust_audit — stored level within justified → no change
#   TC-MM-21: trust_audit — insufficient data → no clamp, returns success
#   TC-MM-22: trust_audit — dry-run with over-trust → exit 1, file NOT mutated
#   TC-MM-31: detect_external_mutation — file changed externally after baseline -> WARNING emitted
#   TC-MM-32: detect_external_mutation — our own write updates baseline -> no false warning next run
#   TC-MM-33: detect_external_mutation — --dry-run does NOT write the baseline
#   TC-MM-34: detect_external_mutation — first run (no baseline) -> no warning, baseline created
#   TC-MM-35: ensure_protective_header — header added once, not duplicated
#   TC-MM-36: dedup_learnings — higher utility wins over lower utility (same key/type)
#   TC-MM-37: dedup_learnings — equal utility falls back to higher confidence tiebreak
#   TC-MM-38: dedup_learnings — utility=N>0 beats utility=0 (missing field default)
#   TC-MM-39: report_utility flags utility<=0 entries in --check output
#   TC-MM-40: report_utility in --check mode writes nothing (read-only contract)
#   TC-MM-41: enforce_playbook_cap over-cap names lowest-utility candidates with consolidator note
#   TC-MM-42: enforce_playbook_cap over-cap with --dry-run writes nothing
#
# Run: bash tests/test-memory-maintain.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_ROOT/scripts/memory-maintain.py"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Harness setup — each TC gets its own fixture dir via --growth-dir
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-memory-maintain.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

# Helper: create a fresh fixture directory for a role
_make_fixture() {
    local name="$1"
    local dir="$TMPDIR_BASE/fixtures/$name"
    mkdir -p "$dir"
    echo "$dir"
}

# Helper: run memory-maintain with --growth-dir pointing at fixture
_run() {
    local growth_dir="$1"
    shift
    python3 "$SCRIPT" --growth-dir "$growth_dir" "$@" 2>&1
    return ${PIPESTATUS[0]}
}

# Helper: build a growth.json with N sessions
_make_growth_json() {
    local n="$1"
    python3 -c "
import json, sys
n = int(sys.argv[1])
sessions = [{'date': '2026-01-' + str(i+1).zfill(2), 'summary': 'session ' + str(i+1)} for i in range(n)]
print(json.dumps({'sessions': sessions}, indent=2))
" "$n"
}

# Helper: build a learnings.jsonl line
_learning_line() {
    local key="$1" ltype="$2" ts="$3" insight="$4" files="${5:-[]}"
    python3 -c "
import json, sys
print(json.dumps({
    'timestamp': sys.argv[3],
    'role': 'developer',
    'type': sys.argv[2],
    'key': sys.argv[1],
    'insight': sys.argv[4],
    'confidence': 0.8,
    'files': json.loads(sys.argv[5]),
}))
" "$key" "$ltype" "$ts" "$insight" "$files"
}

# ---------------------------------------------------------------------------
# TC-MM-1: enforce_session_cap — >50 entries trimmed to 50 + oldest archived
# ---------------------------------------------------------------------------
GD1=$(_make_fixture "tc-mm-1")
mkdir -p "$GD1/developer"
_make_growth_json 55 > "$GD1/developer/growth.json"

_run "$GD1" --role developer --verbose > /dev/null 2>&1
EXIT1=$?

SESSIONS_AFTER=$(python3 -c "
import json
with open('$GD1/developer/growth.json') as f:
    d = json.load(f)
print(len(d.get('sessions', [])))
" 2>/dev/null || echo -1)

ARCHIVE_LINES=$(wc -l < "$GD1/developer/sessions-archive.jsonl" 2>/dev/null || echo -1)

if [ "$SESSIONS_AFTER" -eq 50 ] && [ "$ARCHIVE_LINES" -eq 5 ]; then
    _pass "TC-MM-1: >50 sessions trimmed to 50; 5 oldest archived"
else
    _fail "TC-MM-1: session cap enforcement" \
        "sessions_after=$SESSIONS_AFTER archive_lines=$ARCHIVE_LINES"
fi

# ---------------------------------------------------------------------------
# TC-MM-2: enforce_session_cap — exactly 50 entries untouched
# ---------------------------------------------------------------------------
GD2=$(_make_fixture "tc-mm-2")
mkdir -p "$GD2/developer"
_make_growth_json 50 > "$GD2/developer/growth.json"
# Capture original content checksum
ORIGINAL_HASH=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD2/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD2" --role developer > /dev/null 2>&1

AFTER_HASH=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD2/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

if [ "$ORIGINAL_HASH" = "$AFTER_HASH" ] && [ ! -f "$GD2/developer/sessions-archive.jsonl" ]; then
    _pass "TC-MM-2: exactly 50 sessions — file untouched, no archive created"
else
    _fail "TC-MM-2: exactly 50 sessions should be untouched" \
        "hash_changed=$([ "$ORIGINAL_HASH" != "$AFTER_HASH" ] && echo yes || echo no) archive=$([ -f "$GD2/developer/sessions-archive.jsonl" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# TC-MM-3: enforce_session_cap — <50 entries untouched
# ---------------------------------------------------------------------------
GD3=$(_make_fixture "tc-mm-3")
mkdir -p "$GD3/developer"
_make_growth_json 10 > "$GD3/developer/growth.json"
ORIGINAL_HASH3=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD3/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD3" --role developer > /dev/null 2>&1

AFTER_HASH3=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD3/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

if [ "$ORIGINAL_HASH3" = "$AFTER_HASH3" ]; then
    _pass "TC-MM-3: <50 sessions — file untouched"
else
    _fail "TC-MM-3: <50 sessions should be untouched" "hash changed unexpectedly"
fi

# ---------------------------------------------------------------------------
# TC-MM-4: enforce_session_cap — WAL leaves no .new residue after success
# ---------------------------------------------------------------------------
GD4=$(_make_fixture "tc-mm-4")
mkdir -p "$GD4/developer"
_make_growth_json 52 > "$GD4/developer/growth.json"

_run "$GD4" --role developer > /dev/null 2>&1

if [ ! -f "$GD4/developer/growth.json.new" ]; then
    _pass "TC-MM-4: WAL leaves no .new residue after successful cap enforcement"
else
    _fail "TC-MM-4: .new file still present after WAL promotion" \
        "found: $GD4/developer/growth.json.new"
fi

# ---------------------------------------------------------------------------
# TC-MM-5: dedup_learnings — duplicate (key,type) collapses to latest entry
# ---------------------------------------------------------------------------
GD5=$(_make_fixture "tc-mm-5")
mkdir -p "$GD5/developer"
# Write 3 entries: first two have same (key,type); third is different
{
    _learning_line "write-proxy-pattern" "pattern" "2026-01-01T00:00:00Z" "old insight"
    _learning_line "write-proxy-pattern" "pattern" "2026-03-01T00:00:00Z" "new insight"
    _learning_line "other-key" "operational" "2026-03-01T00:00:00Z" "distinct insight"
} > "$GD5/developer/learnings.jsonl"

_run "$GD5" --role developer > /dev/null 2>&1

AFTER_LINES=$(grep -c . "$GD5/developer/learnings.jsonl" 2>/dev/null || echo 0)
LATEST_INSIGHT=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD5/developer/learnings.jsonl') if l.strip()]
for e in (json.loads(l) for l in lines):
    if e.get('key') == 'write-proxy-pattern':
        print(e.get('insight',''))
        break
" 2>/dev/null || echo "")

if [ "$AFTER_LINES" -eq 2 ] && [ "$LATEST_INSIGHT" = "new insight" ]; then
    _pass "TC-MM-5: duplicate (key,type) collapsed to latest entry; 2 entries remain"
else
    _fail "TC-MM-5: dedup_learnings" \
        "after_lines=$AFTER_LINES latest_insight=${LATEST_INSIGHT@Q}"
fi

# ---------------------------------------------------------------------------
# TC-MM-6: dedup_learnings — distinct (key,type) pairs all preserved
# ---------------------------------------------------------------------------
GD6=$(_make_fixture "tc-mm-6")
mkdir -p "$GD6/developer"
{
    _learning_line "key-a" "pattern"     "2026-01-01T00:00:00Z" "insight A"
    _learning_line "key-b" "operational" "2026-01-01T00:00:00Z" "insight B"
    _learning_line "key-a" "pitfall"     "2026-01-01T00:00:00Z" "insight C"  # same key, different type
} > "$GD6/developer/learnings.jsonl"

ORIGINAL_COUNT=$(grep -c . "$GD6/developer/learnings.jsonl" 2>/dev/null || echo 0)
_run "$GD6" --role developer > /dev/null 2>&1
AFTER_COUNT=$(grep -c . "$GD6/developer/learnings.jsonl" 2>/dev/null || echo 0)

if [ "$AFTER_COUNT" -eq "$ORIGINAL_COUNT" ] && [ "$AFTER_COUNT" -eq 3 ]; then
    _pass "TC-MM-6: 3 distinct (key,type) pairs all preserved after dedup"
else
    _fail "TC-MM-6: distinct pairs should all be preserved" \
        "original=$ORIGINAL_COUNT after=$AFTER_COUNT"
fi

# ---------------------------------------------------------------------------
# TC-MM-7: prune_orphan_learnings — all-missing files[] entries pruned
# ---------------------------------------------------------------------------
GD7=$(_make_fixture "tc-mm-7")
mkdir -p "$GD7/developer"
{
    _learning_line "orphan-key" "pattern" "2026-01-01T00:00:00Z" "orphaned insight" \
        '["/nonexistent/file1.py", "/nonexistent/file2.py"]'
    _learning_line "kept-key" "operational" "2026-01-01T00:00:00Z" "no file refs" '[]'
} > "$GD7/developer/learnings.jsonl"

_run "$GD7" --role developer > /dev/null 2>&1

AFTER_KEYS=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD7/developer/learnings.jsonl') if l.strip()]
print(','.join(json.loads(l).get('key','') for l in lines))
" 2>/dev/null || echo "")

if [ "$AFTER_KEYS" = "kept-key" ]; then
    _pass "TC-MM-7: all-missing files[] → entry pruned; empty-files entry kept"
else
    _fail "TC-MM-7: prune_orphan_learnings with all-missing files" \
        "remaining keys: $AFTER_KEYS"
fi

# ---------------------------------------------------------------------------
# TC-MM-8: prune_orphan_learnings — at least one existing file → entry kept
# ---------------------------------------------------------------------------
GD8=$(_make_fixture "tc-mm-8")
mkdir -p "$GD8/developer"

# Create a real file to reference
REAL_FILE="$GD8/developer/playbook.md"
echo "# playbook" > "$REAL_FILE"

{
    _learning_line "partial-key" "pattern" "2026-01-01T00:00:00Z" "partial insight" \
        "[\"$REAL_FILE\", \"/nonexistent/missing.py\"]"
} > "$GD8/developer/learnings.jsonl"

_run "$GD8" --role developer > /dev/null 2>&1

AFTER_LINES8=$(grep -c . "$GD8/developer/learnings.jsonl" 2>/dev/null || echo 0)

if [ "$AFTER_LINES8" -eq 1 ]; then
    _pass "TC-MM-8: at least one existing file in files[] → entry kept"
else
    _fail "TC-MM-8: entry with one existing file should be kept" \
        "after_lines=$AFTER_LINES8"
fi

# ---------------------------------------------------------------------------
# TC-MM-9: prune_orphan_learnings — empty files[] → entry kept
# ---------------------------------------------------------------------------
GD9=$(_make_fixture "tc-mm-9")
mkdir -p "$GD9/developer"
_learning_line "no-files" "operational" "2026-01-01T00:00:00Z" "no file refs" '[]' \
    > "$GD9/developer/learnings.jsonl"

_run "$GD9" --role developer > /dev/null 2>&1

AFTER_LINES9=$(grep -c . "$GD9/developer/learnings.jsonl" 2>/dev/null || echo 0)

if [ "$AFTER_LINES9" -eq 1 ]; then
    _pass "TC-MM-9: empty files[] → entry kept"
else
    _fail "TC-MM-9: empty files[] entry should be kept" "after_lines=$AFTER_LINES9"
fi

# ---------------------------------------------------------------------------
# TC-MM-10: prune_orphan_learnings — absent files field → entry kept
# ---------------------------------------------------------------------------
GD10=$(_make_fixture "tc-mm-10")
mkdir -p "$GD10/developer"
python3 -c "
import json
print(json.dumps({'timestamp':'2026-01-01T00:00:00Z','role':'developer','type':'operational','key':'no-files-field','insight':'no files key at all','confidence':0.8}))
" > "$GD10/developer/learnings.jsonl"

_run "$GD10" --role developer > /dev/null 2>&1

AFTER_LINES10=$(grep -c . "$GD10/developer/learnings.jsonl" 2>/dev/null || echo 0)

if [ "$AFTER_LINES10" -eq 1 ]; then
    _pass "TC-MM-10: absent files field → entry kept"
else
    _fail "TC-MM-10: entry without files field should be kept" "after_lines=$AFTER_LINES10"
fi

# ---------------------------------------------------------------------------
# TC-MM-11: rotate_expired_decisions — expired moved to archive; active kept
# ---------------------------------------------------------------------------
GD11=$(_make_fixture "tc-mm-11")
mkdir -p "$GD11/authority"
TODAY=$(python3 -c "from datetime import date; print(date.today())" 2>/dev/null)
PAST_DATE=$(python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=120)).isoformat())" 2>/dev/null)
FUTURE_DATE=$(python3 -c "from datetime import date, timedelta; print((date.today() + timedelta(days=30)).isoformat())" 2>/dev/null)

cat > "$GD11/authority/decisions.md" << DECISIONS_EOF
# Authority Decisions

- **role:** developer
- **path_pattern:** src/output.txt
- **decision:** allow
- **scope:** session
- **expires:** $PAST_DATE

- **role:** architect
- **path_pattern:** docs/design.md
- **decision:** allow
- **scope:** session
- **expires:** $FUTURE_DATE
DECISIONS_EOF

_run "$GD11" > /dev/null 2>&1

# Active decisions.md should have only the future-date block
ACTIVE_CONTAINS_EXPIRED=0
grep -q "$PAST_DATE" "$GD11/authority/decisions.md" 2>/dev/null && ACTIVE_CONTAINS_EXPIRED=1
ACTIVE_CONTAINS_FUTURE=0
grep -q "$FUTURE_DATE" "$GD11/authority/decisions.md" 2>/dev/null && ACTIVE_CONTAINS_FUTURE=1

# Archive should have the expired block
ARCHIVE_HAS_EXPIRED=0
[ -f "$GD11/authority/decisions-archive.md" ] && \
    grep -q "$PAST_DATE" "$GD11/authority/decisions-archive.md" 2>/dev/null && \
    ARCHIVE_HAS_EXPIRED=1

if [ $ACTIVE_CONTAINS_EXPIRED -eq 0 ] && [ $ACTIVE_CONTAINS_FUTURE -eq 1 ] && [ $ARCHIVE_HAS_EXPIRED -eq 1 ]; then
    _pass "TC-MM-11: expired decision moved to archive; active decision kept in decisions.md"
else
    _fail "TC-MM-11: rotate_expired_decisions" \
        "active_has_expired=$ACTIVE_CONTAINS_EXPIRED active_has_future=$ACTIVE_CONTAINS_FUTURE archive_has_expired=$ARCHIVE_HAS_EXPIRED"
fi

# ---------------------------------------------------------------------------
# TC-MM-12: rotate_expired_decisions — all-active decisions file unchanged
# ---------------------------------------------------------------------------
GD12=$(_make_fixture "tc-mm-12")
mkdir -p "$GD12/authority"
FUTURE_DATE2=$(python3 -c "from datetime import date, timedelta; print((date.today() + timedelta(days=60)).isoformat())" 2>/dev/null)

cat > "$GD12/authority/decisions.md" << DECISIONS_EOF12
# Authority Decisions

- **role:** developer
- **path_pattern:** src/foo.txt
- **decision:** allow
- **scope:** session
- **expires:** $FUTURE_DATE2
DECISIONS_EOF12
ORIGINAL_HASH12=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD12/authority/decisions.md','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD12" > /dev/null 2>&1

AFTER_HASH12=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD12/authority/decisions.md','rb').read()).hexdigest())" 2>/dev/null)

if [ "$ORIGINAL_HASH12" = "$AFTER_HASH12" ] && [ ! -f "$GD12/authority/decisions-archive.md" ]; then
    _pass "TC-MM-12: all-active decisions — file unchanged, no archive created"
else
    _fail "TC-MM-12: all-active decisions should be unchanged" \
        "hash_changed=$([ "$ORIGINAL_HASH12" != "$AFTER_HASH12" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-13: flag_stale_facts — old fact annotated; fresh fact not annotated
# ---------------------------------------------------------------------------
GD13=$(_make_fixture "tc-mm-13")
OLD_DATE=$(python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=200)).isoformat())" 2>/dev/null)
FRESH_DATE=$(python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=30)).isoformat())" 2>/dev/null)

cat > "$GD13/team-knowledge.md" << TK_EOF
# Team Knowledge

- Tests use vitest <!-- discovered: $OLD_DATE -->
- API is REST+JSON <!-- discovered: $FRESH_DATE -->
TK_EOF

_run "$GD13" > /dev/null 2>&1

OLD_FLAGGED=0
grep -q "STALE" "$GD13/team-knowledge.md" 2>/dev/null && \
    grep "$OLD_DATE" "$GD13/team-knowledge.md" 2>/dev/null | grep -q "STALE" && \
    OLD_FLAGGED=1

FRESH_UNFLAGGED=1
grep "$FRESH_DATE" "$GD13/team-knowledge.md" 2>/dev/null | grep -q "STALE" && FRESH_UNFLAGGED=0

if [ $OLD_FLAGGED -eq 1 ] && [ $FRESH_UNFLAGGED -eq 1 ]; then
    _pass "TC-MM-13: old fact (>180 days) annotated with STALE; fresh fact unchanged"
else
    _fail "TC-MM-13: flag_stale_facts" \
        "old_flagged=$OLD_FLAGGED fresh_unflagged=$FRESH_UNFLAGGED content=$(cat "$GD13/team-knowledge.md" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# TC-MM-14: verify_index_integrity — broken link removed; valid link kept
#           Uses paths relative to index_path.parent (the fixed resolution base).
#           The index is at <project>/.claude/ainous-roles/team-sync/index.md,
#           so "artifacts/existing.md" resolves to
#           <project>/.claude/ainous-roles/team-sync/artifacts/existing.md.
# ---------------------------------------------------------------------------
GD14=$(_make_fixture "tc-mm-14")
FAKE_PROJECT14="$TMPDIR_BASE/project14"
mkdir -p "$FAKE_PROJECT14/.claude/ainous-roles/team-sync"

# Create one existing file and reference it, plus a non-existing file
EXISTING_ARTIFACT="$FAKE_PROJECT14/.claude/ainous-roles/team-sync/artifacts/existing.md"
mkdir -p "$(dirname "$EXISTING_ARTIFACT")"
echo "# exists" > "$EXISTING_ARTIFACT"

# Paths are relative to index_path.parent (the fixed resolution):
#   "artifacts/existing.md" resolves to the artifacts/ subdir of team-sync/
cat > "$FAKE_PROJECT14/.claude/ainous-roles/team-sync/index.md" << INDEX_EOF
# Team Sync Index

- [Existing artifact](artifacts/existing.md)
- [Missing artifact](artifacts/missing.md)
INDEX_EOF

_run "$GD14" --project-root "$FAKE_PROJECT14" > /dev/null 2>&1

VALID_LINK_KEPT=0
grep -q "Existing artifact" "$FAKE_PROJECT14/.claude/ainous-roles/team-sync/index.md" 2>/dev/null && VALID_LINK_KEPT=1
BROKEN_LINK_REMOVED=1
grep -q "Missing artifact" "$FAKE_PROJECT14/.claude/ainous-roles/team-sync/index.md" 2>/dev/null && BROKEN_LINK_REMOVED=0

if [ $VALID_LINK_KEPT -eq 1 ] && [ $BROKEN_LINK_REMOVED -eq 1 ]; then
    _pass "TC-MM-14: broken link removed from index; valid link kept"
else
    _fail "TC-MM-14: verify_index_integrity" \
        "valid_kept=$VALID_LINK_KEPT broken_removed=$BROKEN_LINK_REMOVED"
fi

# ---------------------------------------------------------------------------
# TC-MM-15: --check/--dry-run NEVER mutates (session cap violation)
# ---------------------------------------------------------------------------
GD15=$(_make_fixture "tc-mm-15")
mkdir -p "$GD15/developer"
_make_growth_json 55 > "$GD15/developer/growth.json"
ORIGINAL_CONTENT15=$(cat "$GD15/developer/growth.json")

# --check must exit 1 (violation detected) but NOT change the file
EXIT15=$(_run "$GD15" --role developer --check > /dev/null 2>&1; echo $?)
AFTER_CONTENT15=$(cat "$GD15/developer/growth.json")
ARCHIVE_CREATED15=0
[ -f "$GD15/developer/sessions-archive.jsonl" ] && ARCHIVE_CREATED15=1

if [ "$EXIT15" -eq 1 ] && [ "$ORIGINAL_CONTENT15" = "$AFTER_CONTENT15" ] && [ $ARCHIVE_CREATED15 -eq 0 ]; then
    _pass "TC-MM-15: --check with cap violation → exit 1, file NOT mutated, archive NOT created"
else
    _fail "TC-MM-15: --check should not mutate files" \
        "exit=$EXIT15 content_changed=$([ "$ORIGINAL_CONTENT15" != "$AFTER_CONTENT15" ] && echo yes || echo no) archive_created=$ARCHIVE_CREATED15"
fi

# ---------------------------------------------------------------------------
# TC-MM-16: --dry-run NEVER mutates (dedup violation)
# ---------------------------------------------------------------------------
GD16=$(_make_fixture "tc-mm-16")
mkdir -p "$GD16/developer"
{
    _learning_line "dup-key" "pattern" "2026-01-01T00:00:00Z" "old"
    _learning_line "dup-key" "pattern" "2026-03-01T00:00:00Z" "new"
} > "$GD16/developer/learnings.jsonl"
ORIGINAL_CONTENT16=$(cat "$GD16/developer/learnings.jsonl")

EXIT16=$(_run "$GD16" --role developer --dry-run > /dev/null 2>&1; echo $?)
AFTER_CONTENT16=$(cat "$GD16/developer/learnings.jsonl")

if [ "$EXIT16" -eq 1 ] && [ "$ORIGINAL_CONTENT16" = "$AFTER_CONTENT16" ]; then
    _pass "TC-MM-16: --dry-run with dedup violation → exit 1, learnings.jsonl NOT mutated"
else
    _fail "TC-MM-16: --dry-run should not mutate files" \
        "exit=$EXIT16 content_changed=$([ "$ORIGINAL_CONTENT16" != "$AFTER_CONTENT16" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# Helper: build a growth.json with trust section
# ---------------------------------------------------------------------------
_make_growth_with_trust() {
    local level="$1"
    local score="$2"
    local sessions_completed="$3"
    local denials="${4:-0}"
    python3 -c "
import json, sys
level = sys.argv[1]
score = int(sys.argv[2])
sessions_completed = int(sys.argv[3])
denials = int(sys.argv[4])
d = {
    'role': 'developer',
    'metric': 'implementation_quality',
    'sessions': [{'date': '2026-01-' + str(i+1).zfill(2), 'score': 8} for i in range(sessions_completed)],
    'summary': {'total_sessions': sessions_completed, 'avg_score': 8.0},
    'trust': {
        'level': level,
        'score': score,
        'history': {
            'approvals_granted': 0,
            'denials_received': denials,
            'violations_detected': 0,
            'sessions_completed': sessions_completed,
            'user_overrides': 0,
        },
        'last_promotion': None,
        'last_demotion': None,
    },
}
print(json.dumps(d, indent=2))
" "$level" "$score" "$sessions_completed" "$denials"
}

# ---------------------------------------------------------------------------
# TC-MM-17: verify_index_integrity — line with one valid + one broken link
#           keeps the valid link (M-1a: link-granular removal)
#           Uses paths relative to index_path.parent (artifacts/ subdir of team-sync/).
# ---------------------------------------------------------------------------
GD17=$(_make_fixture "tc-mm-17")
FAKE_PROJECT17="$TMPDIR_BASE/project17"
mkdir -p "$FAKE_PROJECT17/.claude/ainous-roles/team-sync/artifacts"

# Create the valid (existing) file
EXISTING17="$FAKE_PROJECT17/.claude/ainous-roles/team-sync/artifacts/existing.md"
echo "# exists" > "$EXISTING17"

# Index has one line with both a valid and a broken link (paths relative to index dir)
cat > "$FAKE_PROJECT17/.claude/ainous-roles/team-sync/index.md" << INDEX17_EOF
# Team Sync Index

- [Valid artifact](artifacts/existing.md) and [Missing artifact](artifacts/missing.md)
INDEX17_EOF

_run "$GD17" --project-root "$FAKE_PROJECT17" > /dev/null 2>&1

INDEX17_CONTENT=$(cat "$FAKE_PROJECT17/.claude/ainous-roles/team-sync/index.md" 2>/dev/null || echo "")
VALID_KEPT17=0
echo "$INDEX17_CONTENT" | grep -q "Valid artifact" && VALID_KEPT17=1
BROKEN_REMOVED17=1
echo "$INDEX17_CONTENT" | grep -q "Missing artifact" && BROKEN_REMOVED17=0
LINE_KEPT17=0
echo "$INDEX17_CONTENT" | grep -q "Valid artifact" && LINE_KEPT17=1

if [ $VALID_KEPT17 -eq 1 ] && [ $BROKEN_REMOVED17 -eq 1 ] && [ $LINE_KEPT17 -eq 1 ]; then
    _pass "TC-MM-17: line with valid+broken link: broken link removed, valid link and line preserved"
else
    _fail "TC-MM-17: link-granular removal on mixed line" \
        "valid_kept=$VALID_KEPT17 broken_removed=$BROKEN_REMOVED17 content=$(printf '%s' "$INDEX17_CONTENT")"
fi

# ---------------------------------------------------------------------------
# TC-MM-18: verify_index_integrity — relative link to sibling file is NOT removed
#           (M-1b: resolve relative links against index_path.parent)
# ---------------------------------------------------------------------------
GD18=$(_make_fixture "tc-mm-18")
FAKE_PROJECT18="$TMPDIR_BASE/project18"
mkdir -p "$FAKE_PROJECT18/.claude/ainous-roles/team-sync/artifacts"

# Create a sibling file in the same directory as index.md
SIBLING18="$FAKE_PROJECT18/.claude/ainous-roles/team-sync/sibling.md"
echo "# sibling" > "$SIBLING18"

# Index uses a relative path that is a sibling of index.md (NOT relative to project root)
cat > "$FAKE_PROJECT18/.claude/ainous-roles/team-sync/index.md" << INDEX18_EOF
# Team Sync Index

- [Sibling doc](sibling.md)
INDEX18_EOF

_run "$GD18" --project-root "$FAKE_PROJECT18" > /dev/null 2>&1

INDEX18_CONTENT=$(cat "$FAKE_PROJECT18/.claude/ainous-roles/team-sync/index.md" 2>/dev/null || echo "")
SIBLING_KEPT18=0
echo "$INDEX18_CONTENT" | grep -q "Sibling doc" && SIBLING_KEPT18=1

if [ $SIBLING_KEPT18 -eq 1 ]; then
    _pass "TC-MM-18: relative link to sibling file resolved against index_path.parent — NOT removed"
else
    _fail "TC-MM-18: sibling relative link should be kept (resolve against index dir, not project root)" \
        "content=$(printf '%s' "$INDEX18_CONTENT")"
fi

# ---------------------------------------------------------------------------
# TC-MM-19: trust_audit — stored level exceeds justified → clamped down
#           Role has trust.level="senior" but history only justifies "junior"
#           (sessions_completed=5, score reconstructed to 10 → floor=10 < 50 → intern;
#            wait: 5 sessions * 2 = 10 score → intern; that's < 50 threshold for junior.
#            Let us use 5 sessions with denials=0: score=10, which is < 50 → intern.
#            Actually let's use a more realistic case: 5 sessions, 0 denials → score=10
#            → justified="intern"; stored="senior" → clamp to "intern".)
# ---------------------------------------------------------------------------
GD19=$(_make_fixture "tc-mm-19")
mkdir -p "$GD19/developer"
# 5 sessions, no denials → reconstructed score = 10 → justified = intern
# stored level = "senior" → should be clamped to "intern"
_make_growth_with_trust "senior" 75 5 0 > "$GD19/developer/growth.json"

_run "$GD19" --role developer > /dev/null 2>&1
EXIT19=$?

STORED_LEVEL19=$(python3 -c "
import json
with open('$GD19/developer/growth.json') as f:
    d = json.load(f)
print(d.get('trust', {}).get('level', 'MISSING'))
" 2>/dev/null || echo "ERROR")

# score=5*2=10 → justified=intern; stored=senior → clamp expected
if [ "$STORED_LEVEL19" = "intern" ]; then
    _pass "TC-MM-19: trust.level clamped from 'senior' to 'intern' (5 sessions → score 10 → justified intern)"
else
    _fail "TC-MM-19: trust_audit should clamp over-privileged level" \
        "stored_level=$STORED_LEVEL19 expected=intern exit=$EXIT19"
fi

# ---------------------------------------------------------------------------
# TC-MM-20: trust_audit — stored level within justified → no change
#           Role has trust.level="junior" with enough sessions to justify junior
#           (25 sessions, 0 denials → score=50 → justified="junior"; stored="junior" → OK)
# ---------------------------------------------------------------------------
GD20=$(_make_fixture "tc-mm-20")
mkdir -p "$GD20/developer"
# 25 sessions, 0 denials → score = 50 → justified = "junior"; stored = "junior"
_make_growth_with_trust "junior" 50 25 0 > "$GD20/developer/growth.json"
ORIGINAL_HASH20=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD20/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD20" --role developer > /dev/null 2>&1
EXIT20=$?

AFTER_HASH20=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD20/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)
STORED_LEVEL20=$(python3 -c "
import json
with open('$GD20/developer/growth.json') as f:
    d = json.load(f)
print(d.get('trust', {}).get('level', 'MISSING'))
" 2>/dev/null || echo "ERROR")

if [ "$STORED_LEVEL20" = "junior" ] && [ "$ORIGINAL_HASH20" = "$AFTER_HASH20" ]; then
    _pass "TC-MM-20: justified level 'junior' — no change, file untouched"
else
    _fail "TC-MM-20: trust_audit should not modify a justified level" \
        "stored_level=$STORED_LEVEL20 hash_changed=$([ "$ORIGINAL_HASH20" != "$AFTER_HASH20" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-21: trust_audit — insufficient data → no clamp, function returns success
#           growth.json has trust section but sessions_completed is 0 and level
#           is "intern" (the floor) → compute_justified returns "intern"; stored
#           matches → no clamp. Also test the principal-skip path: principal stored
#           → function skips without clamping.
# ---------------------------------------------------------------------------
GD21=$(_make_fixture "tc-mm-21")
mkdir -p "$GD21/developer"
# Store "principal" (manual grant) — audit must NOT clamp this
_make_growth_with_trust "principal" 95 20 0 > "$GD21/developer/growth.json"
ORIGINAL_HASH21=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD21/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD21" --role developer > /dev/null 2>&1

AFTER_HASH21=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD21/developer/growth.json','rb').read()).hexdigest())" 2>/dev/null)
STORED_LEVEL21=$(python3 -c "
import json
with open('$GD21/developer/growth.json') as f:
    d = json.load(f)
print(d.get('trust', {}).get('level', 'MISSING'))
" 2>/dev/null || echo "ERROR")

if [ "$STORED_LEVEL21" = "principal" ] && [ "$ORIGINAL_HASH21" = "$AFTER_HASH21" ]; then
    _pass "TC-MM-21: 'principal' (manual grant) left untouched by trust_audit"
else
    _fail "TC-MM-21: trust_audit must not clamp 'principal' (manual grant)" \
        "stored_level=$STORED_LEVEL21 hash_changed=$([ "$ORIGINAL_HASH21" != "$AFTER_HASH21" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-22: trust_audit — dry-run with over-trust → exit 1, file NOT mutated
#           Same setup as TC-MM-19 (5 sessions, stored=senior) but with --check
# ---------------------------------------------------------------------------
GD22=$(_make_fixture "tc-mm-22")
mkdir -p "$GD22/developer"
_make_growth_with_trust "senior" 75 5 0 > "$GD22/developer/growth.json"
ORIGINAL_CONTENT22=$(cat "$GD22/developer/growth.json")

EXIT22=$(_run "$GD22" --role developer --check > /dev/null 2>&1; echo $?)
AFTER_CONTENT22=$(cat "$GD22/developer/growth.json")

STORED_LEVEL22=$(python3 -c "
import json
with open('$GD22/developer/growth.json') as f:
    d = json.load(f)
print(d.get('trust', {}).get('level', 'MISSING'))
" 2>/dev/null || echo "ERROR")

if [ "$EXIT22" -eq 1 ] && [ "$ORIGINAL_CONTENT22" = "$AFTER_CONTENT22" ] && [ "$STORED_LEVEL22" = "senior" ]; then
    _pass "TC-MM-22: --check with over-trust → exit 1, file NOT mutated, level unchanged"
else
    _fail "TC-MM-22: --check should not mutate trust level" \
        "exit=$EXIT22 stored_level=$STORED_LEVEL22 content_changed=$([ "$ORIGINAL_CONTENT22" != "$AFTER_CONTENT22" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-23: cap_sessions_archive — archive >500 trimmed to 500 keeping newest
# ---------------------------------------------------------------------------
GD23=$(_make_fixture "tc-mm-23")
mkdir -p "$GD23/developer"
# Write 503 JSONL lines to the archive (oldest have index 0..2, newest have larger indices)
python3 -c "
import json
for i in range(503):
    print(json.dumps({'date': '2026-01-01', 'summary': 'session ' + str(i), 'index': i}))
" > "$GD23/developer/sessions-archive.jsonl"

_run "$GD23" --role developer --verbose > /dev/null 2>&1

ARCHIVE_LINES23=$(grep -c . "$GD23/developer/sessions-archive.jsonl" 2>/dev/null || echo -1)
# Verify newest entries are kept (last entry should be index=502)
LAST_INDEX23=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD23/developer/sessions-archive.jsonl') if l.strip()]
if lines:
    print(json.loads(lines[-1]).get('index', -1))
else:
    print(-1)
" 2>/dev/null || echo -1)

if [ "$ARCHIVE_LINES23" -eq 500 ] && [ "$LAST_INDEX23" -eq 502 ]; then
    _pass "TC-MM-23: sessions-archive >500 trimmed to 500 keeping newest entries"
else
    _fail "TC-MM-23: cap_sessions_archive" \
        "archive_lines=$ARCHIVE_LINES23 (want 500) last_index=$LAST_INDEX23 (want 502)"
fi

# ---------------------------------------------------------------------------
# TC-MM-24: cap_sessions_archive — archive <=500 untouched
# ---------------------------------------------------------------------------
GD24=$(_make_fixture "tc-mm-24")
mkdir -p "$GD24/developer"
python3 -c "
import json
for i in range(10):
    print(json.dumps({'date': '2026-01-01', 'summary': 'session ' + str(i)}))
" > "$GD24/developer/sessions-archive.jsonl"
ORIGINAL_HASH24=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD24/developer/sessions-archive.jsonl','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD24" --role developer > /dev/null 2>&1

AFTER_HASH24=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD24/developer/sessions-archive.jsonl','rb').read()).hexdigest())" 2>/dev/null)

if [ "$ORIGINAL_HASH24" = "$AFTER_HASH24" ]; then
    _pass "TC-MM-24: sessions-archive <=500 entries — file untouched"
else
    _fail "TC-MM-24: sessions-archive within cap should be untouched" "hash changed unexpectedly"
fi

# ---------------------------------------------------------------------------
# TC-MM-25: cap_sessions_archive — --dry-run does NOT mutate, exits 1
# ---------------------------------------------------------------------------
GD25=$(_make_fixture "tc-mm-25")
mkdir -p "$GD25/developer"
python3 -c "
import json
for i in range(503):
    print(json.dumps({'date': '2026-01-01', 'summary': 'session ' + str(i)}))
" > "$GD25/developer/sessions-archive.jsonl"
ORIGINAL_CONTENT25=$(cat "$GD25/developer/sessions-archive.jsonl")

EXIT25=$(_run "$GD25" --role developer --dry-run > /dev/null 2>&1; echo $?)
AFTER_CONTENT25=$(cat "$GD25/developer/sessions-archive.jsonl")

if [ "$EXIT25" -eq 1 ] && [ "$ORIGINAL_CONTENT25" = "$AFTER_CONTENT25" ]; then
    _pass "TC-MM-25: --dry-run with sessions-archive >cap → exit 1, archive NOT mutated"
else
    _fail "TC-MM-25: --dry-run should not mutate sessions-archive" \
        "exit=$EXIT25 content_changed=$([ "$ORIGINAL_CONTENT25" != "$AFTER_CONTENT25" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-26: cap_sessions_archive — WAL leaves no .new residue after success
# ---------------------------------------------------------------------------
GD26=$(_make_fixture "tc-mm-26")
mkdir -p "$GD26/developer"
python3 -c "
import json
for i in range(503):
    print(json.dumps({'date': '2026-01-01', 'summary': 'session ' + str(i)}))
" > "$GD26/developer/sessions-archive.jsonl"

_run "$GD26" --role developer > /dev/null 2>&1

if [ ! -f "$GD26/developer/sessions-archive.jsonl.new" ]; then
    _pass "TC-MM-26: WAL leaves no .new residue after sessions-archive cap enforcement"
else
    _fail "TC-MM-26: .new file still present after WAL promotion" \
        "found: $GD26/developer/sessions-archive.jsonl.new"
fi

# ---------------------------------------------------------------------------
# TC-MM-27: cap_decisions_archive — archive >200 blocks trimmed to 200 keeping newest
# ---------------------------------------------------------------------------
GD27=$(_make_fixture "tc-mm-27")
mkdir -p "$GD27/authority"
# Write 202 decision blocks; newest has role=role202
python3 -c "
for i in range(202):
    print('- **role:** role' + str(i))
    print('- **path_pattern:** src/file' + str(i) + '.py')
    print('- **decision:** allow')
    print('- **scope:** session')
    print('- **expires:** 2020-01-01')
    print()
" > "$GD27/authority/decisions-archive.md"

_run "$GD27" --verbose > /dev/null 2>&1

# Count blocks after trimming
BLOCK_COUNT27=$(python3 -c "
blocks = 0
with open('$GD27/authority/decisions-archive.md') as f:
    for line in f:
        if line.strip().startswith('- **role:**'):
            blocks += 1
print(blocks)
" 2>/dev/null || echo -1)

# Verify newest entry is present (role201 is the newest)
HAS_NEWEST27=0
grep -q "role201" "$GD27/authority/decisions-archive.md" 2>/dev/null && HAS_NEWEST27=1
HAS_OLDEST27=1
grep -q "role0" "$GD27/authority/decisions-archive.md" 2>/dev/null || HAS_OLDEST27=0

if [ "$BLOCK_COUNT27" -eq 200 ] && [ "$HAS_NEWEST27" -eq 1 ] && [ "$HAS_OLDEST27" -eq 0 ]; then
    _pass "TC-MM-27: decisions-archive >200 blocks trimmed to 200 keeping newest"
else
    _fail "TC-MM-27: cap_decisions_archive" \
        "block_count=$BLOCK_COUNT27 (want 200) has_newest=$HAS_NEWEST27 has_oldest=$HAS_OLDEST27"
fi

# ---------------------------------------------------------------------------
# TC-MM-28: cap_decisions_archive — archive <=200 blocks untouched
# ---------------------------------------------------------------------------
GD28=$(_make_fixture "tc-mm-28")
mkdir -p "$GD28/authority"
python3 -c "
for i in range(5):
    print('- **role:** role' + str(i))
    print('- **path_pattern:** src/file.py')
    print('- **decision:** allow')
    print('- **scope:** session')
    print('- **expires:** 2020-01-01')
    print()
" > "$GD28/authority/decisions-archive.md"
ORIGINAL_HASH28=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD28/authority/decisions-archive.md','rb').read()).hexdigest())" 2>/dev/null)

_run "$GD28" > /dev/null 2>&1

AFTER_HASH28=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD28/authority/decisions-archive.md','rb').read()).hexdigest())" 2>/dev/null)

if [ "$ORIGINAL_HASH28" = "$AFTER_HASH28" ]; then
    _pass "TC-MM-28: decisions-archive <=200 blocks — file untouched"
else
    _fail "TC-MM-28: decisions-archive within cap should be untouched" "hash changed unexpectedly"
fi

# ---------------------------------------------------------------------------
# TC-MM-29: cap_decisions_archive — --dry-run does NOT mutate, exits 1
# ---------------------------------------------------------------------------
GD29=$(_make_fixture "tc-mm-29")
mkdir -p "$GD29/authority"
python3 -c "
for i in range(202):
    print('- **role:** role' + str(i))
    print('- **path_pattern:** src/file.py')
    print('- **decision:** allow')
    print('- **scope:** session')
    print('- **expires:** 2020-01-01')
    print()
" > "$GD29/authority/decisions-archive.md"
ORIGINAL_CONTENT29=$(cat "$GD29/authority/decisions-archive.md")

EXIT29=$(_run "$GD29" --dry-run > /dev/null 2>&1; echo $?)
AFTER_CONTENT29=$(cat "$GD29/authority/decisions-archive.md")

if [ "$EXIT29" -eq 1 ] && [ "$ORIGINAL_CONTENT29" = "$AFTER_CONTENT29" ]; then
    _pass "TC-MM-29: --dry-run with decisions-archive >cap → exit 1, archive NOT mutated"
else
    _fail "TC-MM-29: --dry-run should not mutate decisions-archive" \
        "exit=$EXIT29 content_changed=$([ "$ORIGINAL_CONTENT29" != "$AFTER_CONTENT29" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# TC-MM-30: cap_decisions_archive — WAL leaves no .new residue after success
# ---------------------------------------------------------------------------
GD30=$(_make_fixture "tc-mm-30")
mkdir -p "$GD30/authority"
python3 -c "
for i in range(202):
    print('- **role:** role' + str(i))
    print('- **path_pattern:** src/file.py')
    print('- **decision:** allow')
    print('- **scope:** session')
    print('- **expires:** 2020-01-01')
    print()
" > "$GD30/authority/decisions-archive.md"

_run "$GD30" > /dev/null 2>&1

if [ ! -f "$GD30/authority/decisions-archive.md.new" ]; then
    _pass "TC-MM-30: WAL leaves no .new residue after decisions-archive cap enforcement"
else
    _fail "TC-MM-30: .new file still present after WAL promotion" \
        "found: $GD30/authority/decisions-archive.md.new"
fi

# ---------------------------------------------------------------------------
# TC-MM-31: external mutation detection — file changed externally after baseline
#           → WARNING emitted on next run
# ---------------------------------------------------------------------------
GD31=$(_make_fixture "tc-mm-31")
mkdir -p "$GD31/developer"

# Write a playbook so the script has something to process
cat > "$GD31/developer/playbook.md" << PB31_EOF
# Playbook

### strategy-1
Do things well.
PB31_EOF

# First run: establishes baseline (last_written_by_us: true)
_run "$GD31" --role developer > /dev/null 2>&1

# Simulate external mutation: change the file AFTER baseline was written
# (do NOT go through memory-maintain — simulates AutoDream or other agent)
echo "EXTERNALLY ADDED LINE" >> "$GD31/developer/playbook.md"
echo "EXTERNALLY ADDED LINE 2" >> "$GD31/developer/playbook.md"
echo "EXTERNALLY ADDED LINE 3" >> "$GD31/developer/playbook.md"

# Second run: should detect the mutation and emit WARNING
OUTPUT31=$(_run "$GD31" --role developer 2>&1)

if echo "$OUTPUT31" | grep -q "external modification detected"; then
    _pass "TC-MM-31: external mutation after baseline → WARNING emitted"
else
    _fail "TC-MM-31: should warn on external mutation" \
        "output did not contain 'external modification detected'; output=${OUTPUT31}"
fi

# ---------------------------------------------------------------------------
# TC-MM-32: our own write updates baseline — no false warning on next run
# ---------------------------------------------------------------------------
GD32=$(_make_fixture "tc-mm-32")
mkdir -p "$GD32/developer"

# Create a playbook with >50 sessions to trigger a mutation via session cap
_make_growth_json 55 > "$GD32/developer/growth.json"
cat > "$GD32/developer/playbook.md" << PB32_EOF
# Playbook

### strategy-1
Do things well.
PB32_EOF

# First run: establishes baseline + may mutate growth.json
_run "$GD32" --role developer > /dev/null 2>&1

# Second run immediately after — no external changes; should NOT warn
OUTPUT32=$(_run "$GD32" --role developer 2>&1)

if echo "$OUTPUT32" | grep -q "external modification detected"; then
    _fail "TC-MM-32: false positive — our own write should not trigger external-mutation warning" \
        "output=${OUTPUT32}"
else
    _pass "TC-MM-32: no false positive after our own write updates the baseline"
fi

# ---------------------------------------------------------------------------
# TC-MM-33: --dry-run does NOT write the baseline
# ---------------------------------------------------------------------------
GD33=$(_make_fixture "tc-mm-33")
mkdir -p "$GD33/developer"

cat > "$GD33/developer/playbook.md" << PB33_EOF
# Playbook

### strategy-1
Something useful.
PB33_EOF

# Run with --dry-run — must NOT create .memory-baseline.json
_run "$GD33" --role developer --dry-run > /dev/null 2>&1

if [ ! -f "$GD33/developer/.memory-baseline.json" ]; then
    _pass "TC-MM-33: --dry-run does NOT write .memory-baseline.json"
else
    _fail "TC-MM-33: --dry-run must not write baseline" \
        "baseline file was created: $GD33/developer/.memory-baseline.json"
fi

# ---------------------------------------------------------------------------
# TC-MM-34: first run (no baseline) → no warning, baseline created
# ---------------------------------------------------------------------------
GD34=$(_make_fixture "tc-mm-34")
mkdir -p "$GD34/developer"

cat > "$GD34/developer/playbook.md" << PB34_EOF
# Playbook

### strategy-1
First time.
PB34_EOF

# First run with no pre-existing baseline — must NOT warn about external mutation
OUTPUT34=$(_run "$GD34" --role developer 2>&1)

BASELINE_CREATED34=0
[ -f "$GD34/developer/.memory-baseline.json" ] && BASELINE_CREATED34=1

HAS_WARN34=0
echo "$OUTPUT34" | grep -q "external modification detected" && HAS_WARN34=1

if [ "$HAS_WARN34" -eq 0 ] && [ "$BASELINE_CREATED34" -eq 1 ]; then
    _pass "TC-MM-34: first run — no warning, baseline created"
else
    _fail "TC-MM-34: first run should create baseline without warning" \
        "has_warn=$HAS_WARN34 baseline_created=$BASELINE_CREATED34"
fi

# ---------------------------------------------------------------------------
# TC-MM-35: protective header added once, not duplicated
# ---------------------------------------------------------------------------
GD35=$(_make_fixture "tc-mm-35")
mkdir -p "$GD35/developer"

HEADER_LINE="<!-- ainous-team managed memory — do not auto-prune; see docs/REFERENCES.md -->"

cat > "$GD35/developer/playbook.md" << PB35_EOF
# Playbook

### strategy-1
Some strategy.
PB35_EOF

# First run: header should be added
_run "$GD35" --role developer > /dev/null 2>&1

HEADER_COUNT35=$(grep -cF "$HEADER_LINE" "$GD35/developer/playbook.md" 2>/dev/null || echo 0)

if [ "$HEADER_COUNT35" -ne 1 ]; then
    _fail "TC-MM-35 (first run): header should appear exactly once after first run" \
        "header_count=$HEADER_COUNT35"
else
    # Second run: header must NOT be duplicated
    _run "$GD35" --role developer > /dev/null 2>&1
    HEADER_COUNT35B=$(grep -cF "$HEADER_LINE" "$GD35/developer/playbook.md" 2>/dev/null || echo 0)
    if [ "$HEADER_COUNT35B" -eq 1 ]; then
        _pass "TC-MM-35: protective header added once on first run, not duplicated on second run"
    else
        _fail "TC-MM-35: header should not be duplicated" \
            "header_count after second run=$HEADER_COUNT35B"
    fi
fi

# ---------------------------------------------------------------------------
# Helper: build a learning line with a utility field
# ---------------------------------------------------------------------------
_learning_line_with_utility() {
    local key="$1" ltype="$2" ts="$3" insight="$4" confidence="$5" utility="$6" files="${7:-[]}"
    python3 -c "
import json, sys
print(json.dumps({
    'timestamp': sys.argv[3],
    'role': 'developer',
    'type': sys.argv[2],
    'key': sys.argv[1],
    'insight': sys.argv[4],
    'confidence': float(sys.argv[5]),
    'utility': int(sys.argv[6]),
    'files': json.loads(sys.argv[7]),
}))
" "$key" "$ltype" "$ts" "$insight" "$confidence" "$utility" "$files"
}

# ---------------------------------------------------------------------------
# TC-MM-36: dedup_learnings — higher utility wins over lower utility (same key/type)
#           Entry with utility=5 should beat entry with utility=1, regardless
#           of which was written last (utility is the primary tiebreak).
# ---------------------------------------------------------------------------
GD36=$(_make_fixture "tc-mm-36")
mkdir -p "$GD36/developer"
# Write lower-utility entry first, then higher-utility entry second.
# Old behaviour (confidence-only) would keep the second (last-write);
# new behaviour: second has lower utility (1 < 5), so FIRST must win.
{
    _learning_line_with_utility "util-key" "pattern" "2026-01-01T00:00:00Z" "high utility insight" "0.7" "5"
    _learning_line_with_utility "util-key" "pattern" "2026-03-01T00:00:00Z" "low utility insight"  "0.9" "1"
} > "$GD36/developer/learnings.jsonl"

_run "$GD36" --role developer > /dev/null 2>&1

AFTER_LINES36=$(grep -c . "$GD36/developer/learnings.jsonl" 2>/dev/null || echo 0)
KEPT_INSIGHT36=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD36/developer/learnings.jsonl') if l.strip()]
for e in (json.loads(l) for l in lines):
    if e.get('key') == 'util-key':
        print(e.get('insight',''))
        break
" 2>/dev/null || echo "")
KEPT_UTILITY36=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD36/developer/learnings.jsonl') if l.strip()]
for e in (json.loads(l) for l in lines):
    if e.get('key') == 'util-key':
        print(e.get('utility', 'MISSING'))
        break
" 2>/dev/null || echo "")

if [ "$AFTER_LINES36" -eq 1 ] && [ "$KEPT_UTILITY36" = "5" ]; then
    _pass "TC-MM-36: dedup prefers higher utility (utility=5 kept over utility=1)"
else
    _fail "TC-MM-36: dedup should prefer higher utility" \
        "after_lines=$AFTER_LINES36 kept_utility=$KEPT_UTILITY36 kept_insight=${KEPT_INSIGHT36@Q}"
fi

# ---------------------------------------------------------------------------
# TC-MM-37: dedup_learnings — equal utility falls back to higher confidence
#           Both entries have utility=3; entry with confidence=0.9 must win.
# ---------------------------------------------------------------------------
GD37=$(_make_fixture "tc-mm-37")
mkdir -p "$GD37/developer"
{
    _learning_line_with_utility "conf-key" "pattern" "2026-01-01T00:00:00Z" "low conf" "0.5" "3"
    _learning_line_with_utility "conf-key" "pattern" "2026-03-01T00:00:00Z" "high conf" "0.9" "3"
} > "$GD37/developer/learnings.jsonl"

_run "$GD37" --role developer > /dev/null 2>&1

KEPT_CONF37=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD37/developer/learnings.jsonl') if l.strip()]
for e in (json.loads(l) for l in lines):
    if e.get('key') == 'conf-key':
        print(e.get('insight',''))
        break
" 2>/dev/null || echo "")

if [ "$KEPT_CONF37" = "high conf" ]; then
    _pass "TC-MM-37: dedup equal-utility falls back to confidence (higher confidence kept)"
else
    _fail "TC-MM-37: equal utility should fall back to confidence tiebreak" \
        "kept_insight=${KEPT_CONF37@Q} (expected 'high conf')"
fi

# ---------------------------------------------------------------------------
# TC-MM-38: dedup_learnings — entry with utility > 0 beats entry with utility=0
#           (utility=0 is the default for entries missing the field; a positive
#           utility entry should always replace a zero-utility one)
# ---------------------------------------------------------------------------
GD38=$(_make_fixture "tc-mm-38")
mkdir -p "$GD38/developer"
# Entry 1: utility=0 (default/neutral), written first
# Entry 2: utility=2 (positive), written second with lower confidence
{
    python3 -c "
import json
print(json.dumps({'timestamp':'2026-01-01T00:00:00Z','role':'developer','type':'pattern','key':'zero-util','insight':'no utility field','confidence':0.9}))
"
    _learning_line_with_utility "zero-util" "pattern" "2026-03-01T00:00:00Z" "positive utility insight" "0.5" "2"
} > "$GD38/developer/learnings.jsonl"

_run "$GD38" --role developer > /dev/null 2>&1

KEPT_INSIGHT38=$(python3 -c "
import json
lines = [l.strip() for l in open('$GD38/developer/learnings.jsonl') if l.strip()]
for e in (json.loads(l) for l in lines):
    if e.get('key') == 'zero-util':
        print(e.get('insight',''))
        break
" 2>/dev/null || echo "")

if [ "$KEPT_INSIGHT38" = "positive utility insight" ]; then
    _pass "TC-MM-38: dedup: utility=2 beats utility=0 (missing field default)"
else
    _fail "TC-MM-38: positive utility should win over zero/default utility" \
        "kept_insight=${KEPT_INSIGHT38@Q} (expected 'positive utility insight')"
fi

# ---------------------------------------------------------------------------
# TC-MM-39: report_utility flags utility<=0 entries in --check/--verbose output
#           Three entries: one utility=5 (positive), two with utility<=0.
#           In --check mode, the report must mention the utility<=0 count and
#           the keys of the low-utility entries.
# ---------------------------------------------------------------------------
GD39=$(_make_fixture "tc-mm-39")
mkdir -p "$GD39/developer"
{
    _learning_line_with_utility "good-key"    "pattern"     "2026-01-01T00:00:00Z" "good insight"    "0.8" "5"
    _learning_line_with_utility "zero-key"    "operational" "2026-01-01T00:00:00Z" "zero insight"    "0.7" "0"
    _learning_line_with_utility "neg-key"     "pitfall"     "2026-01-01T00:00:00Z" "negative insight" "0.6" "-1"
} > "$GD39/developer/learnings.jsonl"

OUTPUT39=$(_run "$GD39" --role developer --check 2>&1)

# Report must mention utility_le_0=2 (zero-key and neg-key)
HAS_LE0_COUNT39=0
echo "$OUTPUT39" | grep -q "utility_le_0=2" && HAS_LE0_COUNT39=1

# Report must name the low-utility keys
HAS_ZERO_KEY39=0
echo "$OUTPUT39" | grep -q "zero-key" && HAS_ZERO_KEY39=1
HAS_NEG_KEY39=0
echo "$OUTPUT39" | grep -q "neg-key" && HAS_NEG_KEY39=1

if [ "$HAS_LE0_COUNT39" -eq 1 ] && [ "$HAS_ZERO_KEY39" -eq 1 ] && [ "$HAS_NEG_KEY39" -eq 1 ]; then
    _pass "TC-MM-39: report_utility flags utility<=0 entries in --check output"
else
    _fail "TC-MM-39: report_utility should surface utility<=0 keys in --check mode" \
        "has_le0_count=$HAS_LE0_COUNT39 has_zero_key=$HAS_ZERO_KEY39 has_neg_key=$HAS_NEG_KEY39"
fi

# ---------------------------------------------------------------------------
# TC-MM-40: report_utility in --check mode writes nothing (read-only contract)
#           Confirm no new files appear in the role directory after report_utility.
# ---------------------------------------------------------------------------
GD40=$(_make_fixture "tc-mm-40")
mkdir -p "$GD40/developer"
{
    _learning_line_with_utility "any-key" "pattern" "2026-01-01T00:00:00Z" "some insight" "0.8" "-1"
} > "$GD40/developer/learnings.jsonl"

# Snapshot files before run
FILES_BEFORE40=$(ls "$GD40/developer/" 2>/dev/null | sort)

_run "$GD40" --role developer --check > /dev/null 2>&1

# Snapshot files after run (exclude .memory-baseline.json — baseline is NOT
# written in --dry-run mode; however --check does NOT write it per TC-MM-33).
FILES_AFTER40=$(ls "$GD40/developer/" 2>/dev/null | sort)

# The only extra files that may appear in --check mode are lock files that
# get cleaned up; learnings.jsonl must NOT have changed.
LEARNINGS_HASH_BEFORE40=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD40/developer/learnings.jsonl','rb').read()).hexdigest())" 2>/dev/null)
_run "$GD40" --role developer --check > /dev/null 2>&1
LEARNINGS_HASH_AFTER40=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD40/developer/learnings.jsonl','rb').read()).hexdigest())" 2>/dev/null)

if [ "$LEARNINGS_HASH_BEFORE40" = "$LEARNINGS_HASH_AFTER40" ]; then
    _pass "TC-MM-40: report_utility in --check mode writes nothing to learnings.jsonl"
else
    _fail "TC-MM-40: report_utility must be read-only" \
        "learnings.jsonl was modified by --check run"
fi

# ---------------------------------------------------------------------------
# TC-MM-41: enforce_playbook_cap over-cap names lowest-utility candidates
#           Playbook has 32 strategies (2 over cap=30); learnings has utility
#           data for some.  The over-cap log must name the lowest-utility ones.
# ---------------------------------------------------------------------------
GD41=$(_make_fixture "tc-mm-41")
mkdir -p "$GD41/developer"

# Build a playbook with 32 strategies
python3 -c "
print('# Playbook')
print()
# strategies 0-29 are ordinary; 30 and 31 are the low-utility ones
for i in range(30):
    print('### strategy-' + str(i))
    print('Some description.')
    print()
print('### low-util-alpha')
print('This strategy has low utility.')
print()
print('### low-util-beta')
print('This strategy also has low utility.')
print()
" > "$GD41/developer/playbook.md"

# Learnings: link 'low-util-alpha' and 'low-util-beta' to negative utility
{
    _learning_line_with_utility "low-util-alpha" "pattern" "2026-01-01T00:00:00Z" "low utility alpha" "0.5" "-2"
    _learning_line_with_utility "low-util-beta"  "pattern" "2026-01-01T00:00:00Z" "low utility beta"  "0.5" "-1"
    # Add a high-utility entry for an unrelated key (should NOT appear in candidates)
    _learning_line_with_utility "strategy-0"     "pattern" "2026-01-01T00:00:00Z" "strategy zero"     "0.8" "10"
} > "$GD41/developer/learnings.jsonl"

OUTPUT41=$(_run "$GD41" --role developer --check 2>&1)

HAS_LOW_ALPHA41=0
echo "$OUTPUT41" | grep -q "low-util-alpha" && HAS_LOW_ALPHA41=1
HAS_LOW_BETA41=0
echo "$OUTPUT41" | grep -q "low-util-beta" && HAS_LOW_BETA41=1
HAS_CONSOLIDATOR_NOTE41=0
echo "$OUTPUT41" | grep -qi "consolidator" && HAS_CONSOLIDATOR_NOTE41=1

if [ "$HAS_LOW_ALPHA41" -eq 1 ] && [ "$HAS_LOW_BETA41" -eq 1 ] && [ "$HAS_CONSOLIDATOR_NOTE41" -eq 1 ]; then
    _pass "TC-MM-41: enforce_playbook_cap over-cap names lowest-utility candidates with consolidator note"
else
    _fail "TC-MM-41: over-cap should surface low-utility candidates with consolidator note" \
        "has_alpha=$HAS_LOW_ALPHA41 has_beta=$HAS_LOW_BETA41 has_consolidator_note=$HAS_CONSOLIDATOR_NOTE41"
fi

# ---------------------------------------------------------------------------
# TC-MM-42: enforce_playbook_cap over-cap with --dry-run writes nothing
#           (regression: the new retirement-candidate logging must not
#            trigger any writes even when it reads learnings.jsonl)
# ---------------------------------------------------------------------------
GD42=$(_make_fixture "tc-mm-42")
mkdir -p "$GD42/developer"

python3 -c "
print('# Playbook')
print()
for i in range(32):
    print('### strategy-' + str(i))
    print('Description.')
    print()
" > "$GD42/developer/playbook.md"

{
    _learning_line_with_utility "strategy-0" "pattern" "2026-01-01T00:00:00Z" "low" "0.5" "-1"
} > "$GD42/developer/learnings.jsonl"

LEARNINGS_HASH_BEFORE42=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD42/developer/learnings.jsonl','rb').read()).hexdigest())" 2>/dev/null)
PLAYBOOK_HASH_BEFORE42=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD42/developer/playbook.md','rb').read()).hexdigest())" 2>/dev/null)

EXIT42=$(_run "$GD42" --role developer --dry-run > /dev/null 2>&1; echo $?)

LEARNINGS_HASH_AFTER42=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD42/developer/learnings.jsonl','rb').read()).hexdigest())" 2>/dev/null)
PLAYBOOK_HASH_AFTER42=$(python3 -c "import hashlib; print(hashlib.md5(open('$GD42/developer/playbook.md','rb').read()).hexdigest())" 2>/dev/null)

if [ "$EXIT42" -eq 1 ] \
        && [ "$LEARNINGS_HASH_BEFORE42" = "$LEARNINGS_HASH_AFTER42" ] \
        && [ "$PLAYBOOK_HASH_BEFORE42" = "$PLAYBOOK_HASH_AFTER42" ]; then
    _pass "TC-MM-42: enforce_playbook_cap over-cap with --dry-run writes nothing (exit 1)"
else
    _fail "TC-MM-42: --dry-run must not write any files even with retirement candidate logging" \
        "exit=$EXIT42 learnings_changed=$([ "$LEARNINGS_HASH_BEFORE42" != "$LEARNINGS_HASH_AFTER42" ] && echo yes || echo no) playbook_changed=$([ "$PLAYBOOK_HASH_BEFORE42" != "$PLAYBOOK_HASH_AFTER42" ] && echo yes || echo no)"
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
