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
# ---------------------------------------------------------------------------
GD14=$(_make_fixture "tc-mm-14")
FAKE_PROJECT14="$TMPDIR_BASE/project14"
mkdir -p "$FAKE_PROJECT14/.claude/ainous-roles/team-sync"

# Create one existing file and reference it, plus a non-existing file
EXISTING_ARTIFACT="$FAKE_PROJECT14/.claude/ainous-roles/team-sync/artifacts/existing.md"
mkdir -p "$(dirname "$EXISTING_ARTIFACT")"
echo "# exists" > "$EXISTING_ARTIFACT"

cat > "$FAKE_PROJECT14/.claude/ainous-roles/team-sync/index.md" << INDEX_EOF
# Team Sync Index

- [Existing artifact](.claude/ainous-roles/team-sync/artifacts/existing.md)
- [Missing artifact](.claude/ainous-roles/team-sync/artifacts/missing.md)
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
