#!/usr/bin/env bash
# test-self-improve-check.sh — Test suite for scripts/self-improve-check.py (v5.20.0)
#
# The checker is the single source of truth for "is self-improvement due?".
# It reads, fail-open, from:
#   playbooks:   <home>/.claude/ainous-roles/<role>/playbook.md   (last_consolidated: frontmatter)
#   journals:    <root>/.claude/ainous-roles/<role>/journal.md    (## YYYY-MM-DD headings)
#   reviews:     <root>/.claude/ainous-roles/coordinator/reviews.md
#   coord journal: <root>/.claude/ainous-roles/coordinator/journal.md
#
# SPEC (tested here):
#   consolidation_due: some role unconsolidated>=3 AND (hours_since>=24 OR never OR sessions>=5)
#   really_critical: days_stale>2 ; stale_roles: days_stale 1..2
#   retro_due: days_since>=7 OR commits_since>=10
#   journal_due: newest coord-journal entry >=24h old (or none + role activity)
#
# Run: bash tests/test-self-improve-check.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/self-improve-check.py"

TESTS_PASS=0
TESTS_FAIL=0
FINDINGS=()

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }
_finding() { echo "FINDING: $1"; FINDINGS+=("$1"); }

TMPDIR_BASE=$(mktemp -d /tmp/test-self-improve.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Echo a UTC date N days ago as YYYY-MM-DD (matches the checker's UTC clock).
_days_ago() {
    python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=$1)).strftime('%Y-%m-%d'))"
}

# Run the checker against an isolated fixture tree; capture JSON.
_run() {  # _run <root> <home>  -> stdout JSON
    python3 "$CHECKER" --root "$1" --home "$2" --json 2>/dev/null
}

# Extract a value from JSON via a python expression on the parsed dict `d`.
_jget() {  # _jget <json> <python-expr over d>  e.g. 'd["consolidation_due"]'
    python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" <<<"$1"
}

# Build a role playbook with a given last_consolidated value.
_playbook() {  # _playbook <home> <role> <last_consolidated_value>
    local home="$1" role="$2" lc="$3"
    mkdir -p "$home/.claude/ainous-roles/$role"
    cat > "$home/.claude/ainous-roles/$role/playbook.md" <<EOF
---
version: 1
last_consolidated: $lc
---
# Playbook
EOF
}

# Build a role journal with N date-headed entries, each dated `days_ago` (descending).
_journal_entries() {  # _journal_entries <root> <role> <date1> [date2] [date3] ...
    local root="$1" role="$2"; shift 2
    mkdir -p "$root/.claude/ainous-roles/$role"
    local f="$root/.claude/ainous-roles/$role/journal.md"
    : > "$f"
    local d
    for d in "$@"; do
        printf '## %s entry\nsome work done\n\n' "$d" >> "$f"
    done
}

# ---------------------------------------------------------------------------
# T1: consolidation DUE — role 3d stale + 3 newer entries -> due, really_critical
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t1/root"; H="$TMPDIR_BASE/t1/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "$(_days_ago 3)"
_journal_entries "$R" developer "$(_days_ago 2)" "$(_days_ago 1)" "$(_days_ago 0)"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["consolidation_due"]')" = "True" ] \
   && [ "$(_jget "$OUT" '"developer" in d["consolidation"]["really_critical"]')" = "True" ]; then
    _pass "T1: 3d-stale role + 3 entries -> consolidation_due + really_critical"
else
    _fail "T1: expected due+really_critical" "$OUT"
fi

# ---------------------------------------------------------------------------
# T2: consolidation NOT due — only 2 unconsolidated entries (volume gate)
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t2/root"; H="$TMPDIR_BASE/t2/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "$(_days_ago 3)"
_journal_entries "$R" developer "$(_days_ago 2)" "$(_days_ago 1)"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["consolidation_due"]')" = "False" ]; then
    _pass "T2: only 2 entries -> consolidation_due=false (volume gate at exactly 3)"
else
    _fail "T2: expected not due with 2 entries" "$OUT"
fi

# ---------------------------------------------------------------------------
# T3: critical+stale split — X(3d,3) critical, Y(2d,3) stale, both surfaced
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t3/root"; H="$TMPDIR_BASE/t3/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "$(_days_ago 3)"
_journal_entries "$R" developer "$(_days_ago 2)" "$(_days_ago 1)" "$(_days_ago 0)"
_playbook "$H" tester "$(_days_ago 2)"
_journal_entries "$R" tester "$(_days_ago 1)" "$(_days_ago 1)" "$(_days_ago 0)"
OUT=$(_run "$R" "$H")
RC=$(_jget "$OUT" '"developer" in d["consolidation"]["really_critical"]')
SR=$(_jget "$OUT" '"tester" in d["consolidation"]["stale_roles"]')
if [ "$RC" = "True" ] && [ "$SR" = "True" ]; then
    _pass "T3: X in really_critical AND Y in stale_roles (no swallow)"
else
    _fail "T3: expected developer critical + tester stale" "$OUT"
fi

# ---------------------------------------------------------------------------
# T3b (boundary): days_stale == 1 -> due via 24h gate but in NEITHER named bucket
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t3b/root"; H="$TMPDIR_BASE/t3b/home"; mkdir -p "$R" "$H"
# consolidated ~1 day ago (>24h since midnight, days_stale==1); 3 newer entries
_playbook "$H" developer "$(_days_ago 1)"
_journal_entries "$R" developer "$(_days_ago 0)" "$(_days_ago 0)" "$(_days_ago 0)"
OUT=$(_run "$R" "$H")
DUE=$(_jget "$OUT" 'd["consolidation_due"]')
INRC=$(_jget "$OUT" '"developer" in d["consolidation"]["really_critical"]')
INSR=$(_jget "$OUT" '"developer" in d["consolidation"]["stale_roles"]')
# entries dated today vs last_cons yesterday: today>yesterday so they count (=3); hours_since>=24 -> due
if [ "$DUE" = "True" ] && [ "$INRC" = "False" ] && [ "$INSR" = "False" ]; then
    _pass "T3b: days_stale==1 -> due but unnamed (boundary of really_critical/stale buckets)"
else
    _fail "T3b: expected due + unnamed at days_stale==1" "$OUT"
fi

# ---------------------------------------------------------------------------
# T4: never-consolidated + 3 entries -> due (the is-None / never path)
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t4/root"; H="$TMPDIR_BASE/t4/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "never"
_journal_entries "$R" developer "$(_days_ago 5)" "$(_days_ago 3)" "$(_days_ago 1)"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["consolidation_due"]')" = "True" ]; then
    _pass "T4: never-consolidated + 3 entries -> due"
else
    _fail "T4: expected due for never-consolidated" "$OUT"
fi

# ---------------------------------------------------------------------------
# T5: SESSIONS-PATH PROBE — recently consolidated (<24h) with same-day entries
#     SPEC says due if sessions_since>=5; code implements only hours>=24 OR never.
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t5/root"; H="$TMPDIR_BASE/t5/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "$(_days_ago 0)"   # consolidated today (<24h since midnight)
_journal_entries "$R" developer "$(_days_ago 0)" "$(_days_ago 0)" "$(_days_ago 0)"
OUT=$(_run "$R" "$H")
DUE=$(_jget "$OUT" 'd["consolidation_due"]')
UNCOUNT_NOTE="entries dated == last_consolidated are not counted (> comparison)"
if [ "$DUE" = "False" ]; then
    _pass "T5: same-day consolidation + same-day entries -> not due (documented)"
    _finding "DOCUMENTED BEHAVIOUR (not a defect): the consolidator's '>= 5 sessions' path is intentionally NOT implemented in this date-granularity detector — session-count isn't derivable from playbook dates + dated journal entries, and the path is unreachable anyway (>= 3 unconsolidated entries must be dated strictly after last_consolidated, which already forces hours_since >= 24). The detector implements (hours>=24 OR never) AND volume>=3; the consolidator applies its own session-aware self-gate when invoked. Docstring corrected to match (self-improve-check.py). ($UNCOUNT_NOTE)"
else
    _fail "T5: unexpected due state for same-day consolidation" "$OUT"
fi

# ---------------------------------------------------------------------------
# T6 (boundary): retro DUE by age at exactly 7 days
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t6/root"; H="$TMPDIR_BASE/t6/home"; mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
printf '## %s retro\n' "$(_days_ago 7)" > "$R/.claude/ainous-roles/coordinator/reviews.md"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["retro_due"]')" = "True" ]; then
    _pass "T6: retro 7d old -> retro_due (>=7 boundary)"
else
    _fail "T6: expected retro_due at exactly 7 days" "$OUT"
fi

# ---------------------------------------------------------------------------
# T7: retro DUE by commits — real temp git repo with >=10 commits since review
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t7/root"; H="$TMPDIR_BASE/t7/home"; mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
REVIEW_DATE=$(_days_ago 2)   # 2d ago: NOT date-due (<7); only commits can make it due
printf '## %s retro\n' "$REVIEW_DATE" > "$R/.claude/ainous-roles/coordinator/reviews.md"
GIT_OK=1
(
  cd "$R" || exit 1
  git init -q . 2>/dev/null || exit 1
  git config user.email t@t.t; git config user.name t
  for i in $(seq 1 11); do
      echo "$i" > "f$i.txt"
      git add "f$i.txt" 2>/dev/null
      git commit -q -m "c$i" 2>/dev/null || exit 1
  done
) || GIT_OK=0
if [ "$GIT_OK" = "1" ]; then
    OUT=$(_run "$R" "$H")
    CS=$(_jget "$OUT" 'd["retro"]["commits_since"]')
    DUE=$(_jget "$OUT" 'd["retro_due"]')
    if [ "$DUE" = "True" ] && [ "$CS" != "None" ] && [ "$CS" -ge 10 ] 2>/dev/null; then
        _pass "T7: 11 commits since 2d-old review -> retro_due via commits ($CS counted)"
    else
        _fail "T7: expected retro_due via commits>=10" "commits_since=$CS due=$DUE :: $OUT"
    fi
else
    _finding "T7: could not create a temp git repo in this environment; commit-path coverage skipped (date-path covered by T6/T8)."
    _pass "T7: (skipped — git unavailable; documented, not a failure)"
fi

# ---------------------------------------------------------------------------
# T8: retro NOT due — review 2d ago, no git repo (commits None) -> false
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t8/root"; H="$TMPDIR_BASE/t8/home"; mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
printf '## %s retro\n' "$(_days_ago 2)" > "$R/.claude/ainous-roles/coordinator/reviews.md"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["retro_due"]')" = "False" ]; then
    _pass "T8: review 2d ago, no commits -> retro_due=false"
else
    _fail "T8: expected not due" "$OUT"
fi

# ---------------------------------------------------------------------------
# T9: journal DUE — newest coord-journal entry 2d old
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t9/root"; H="$TMPDIR_BASE/t9/home"; mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
printf '## %s note\n' "$(_days_ago 2)" > "$R/.claude/ainous-roles/coordinator/journal.md"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["journal_due"]')" = "True" ]; then
    _pass "T9: coord journal 2d old -> journal_due"
else
    _fail "T9: expected journal_due" "$OUT"
fi

# ---------------------------------------------------------------------------
# T10: journal NOT due — newest entry dated today (<24h since midnight)
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t10/root"; H="$TMPDIR_BASE/t10/home"; mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
printf '## %s note\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/journal.md"
OUT=$(_run "$R" "$H")
if [ "$(_jget "$OUT" 'd["journal_due"]')" = "False" ]; then
    _pass "T10: coord journal entry today -> journal_due=false"
else
    _fail "T10: expected not due for same-day journal entry" "$OUT"
fi

# ---------------------------------------------------------------------------
# T11: FAIL-OPEN — nonexistent root+home -> exit 0, all due=false, no traceback
# ---------------------------------------------------------------------------
ERR=$(python3 "$CHECKER" --root /nonexistent/xyz --home /nonexistent/xyz --json 2>&1 >/dev/null)
OUT=$(python3 "$CHECKER" --root /nonexistent/xyz --home /nonexistent/xyz --json 2>/dev/null)
CODE=$?
if [ "$CODE" = "0" ] && [ -z "$ERR" ] \
   && [ "$(_jget "$OUT" 'd["any_due"]')" = "False" ]; then
    _pass "T11: nonexistent paths -> exit 0, any_due=false, no stderr"
else
    _fail "T11: expected clean fail-open" "code=$CODE err=$ERR out=$OUT"
fi

# ---------------------------------------------------------------------------
# T12: FAIL-OPEN malformed — garbage last_consolidated + junk journal -> no crash
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t12/root"; H="$TMPDIR_BASE/t12/home"; mkdir -p "$R" "$H"
_playbook "$H" developer "*** NOT A DATE GARBAGE ***"
mkdir -p "$R/.claude/ainous-roles/developer"
printf '## not-a-date\n\xff\xfe binary junk\n## 2026-13-99 bad\n' > "$R/.claude/ainous-roles/developer/journal.md"
ERR=$(python3 "$CHECKER" --root "$R" --home "$H" --json 2>&1 >/dev/null)
OUT=$(python3 "$CHECKER" --root "$R" --home "$H" --json 2>/dev/null); CODE=$?
if [ "$CODE" = "0" ] && [ -z "$ERR" ]; then
    _pass "T12: malformed playbook/journal -> exit 0, no traceback (strptime(None) regression guard)"
else
    _fail "T12: expected clean fail-open on malformed input" "code=$CODE err=$ERR"
fi

# ---------------------------------------------------------------------------
# T13: any_due aggregation — consolidation due, retro+journal cold
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t13/root"; H="$TMPDIR_BASE/t13/home"
mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
_playbook "$H" developer "$(_days_ago 3)"
_journal_entries "$R" developer "$(_days_ago 2)" "$(_days_ago 1)" "$(_days_ago 0)"
# retro cold: review today ; journal cold: entry today
printf '## %s retro\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/reviews.md"
printf '## %s note\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/journal.md"
OUT=$(_run "$R" "$H")
CD=$(_jget "$OUT" 'd["consolidation_due"]')
RD=$(_jget "$OUT" 'd["retro_due"]')
JD=$(_jget "$OUT" 'd["journal_due"]')
AD=$(_jget "$OUT" 'd["any_due"]')
if [ "$CD" = "True" ] && [ "$RD" = "False" ] && [ "$JD" = "False" ] && [ "$AD" = "True" ]; then
    _pass "T13: any_due=true with only consolidation due (exact sub-flags)"
else
    _fail "T13: expected consolidation-only any_due" "cons=$CD retro=$RD journal=$JD any=$AD :: $OUT"
fi

# ---------------------------------------------------------------------------
# T14: CWD-DRIFT REGRESSION — cwd inside a subdir of project, no --root
#      Proves the _resolve_root walk-up fix: verdict from subdir == verdict from root.
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t14/root"; H="$TMPDIR_BASE/t14/home"
mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
# Build a project with consolidation NOT due (all cold) so we can confirm the
# subdir verdict matches the root verdict exactly (not just "both due" which any
# directory without journals would give).
_playbook "$H" developer "$(_days_ago 0)"
_journal_entries "$R" developer "$(_days_ago 0)" "$(_days_ago 0)"
printf '## %s retro\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/reviews.md"
printf '## %s note\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/journal.md"
# Capture the reference result using explicit --root (always correct)
REF=$(_run "$R" "$H")
# Now create a nested subdir and run WITHOUT --root, using --home for home (home is stable)
SUBDIR="$R/nested/subdir"
mkdir -p "$SUBDIR"
# Run the checker from the subdir with no --root; home still passed explicitly
SUBOUT=$(cd "$SUBDIR" && python3 "$CHECKER" --home "$H" --json 2>/dev/null)
REF_CD=$(_jget "$REF" 'd["consolidation_due"]')
REF_RD=$(_jget "$REF" 'd["retro_due"]')
REF_JD=$(_jget "$REF" 'd["journal_due"]')
SUB_CD=$(_jget "$SUBOUT" 'd["consolidation_due"]')
SUB_RD=$(_jget "$SUBOUT" 'd["retro_due"]')
SUB_JD=$(_jget "$SUBOUT" 'd["journal_due"]')
if [ "$REF_CD" = "$SUB_CD" ] && [ "$REF_RD" = "$SUB_RD" ] && [ "$REF_JD" = "$SUB_JD" ]; then
    _pass "T14: cwd-drift regression — subdir verdict matches --root verdict (cons=$SUB_CD retro=$SUB_RD journal=$SUB_JD)"
else
    _fail "T14: cwd-drift mismatch: ref cons=$REF_CD retro=$REF_RD journal=$REF_JD vs sub cons=$SUB_CD retro=$SUB_RD journal=$SUB_JD" \
          "ref=$REF :: sub=$SUBOUT"
fi

# ---------------------------------------------------------------------------
# T15: OUTSIDE-PROJECT FALLBACK — cwd has no .claude/ainous-roles ancestor
#      Proves the fallback path: no ancestor match -> uses cwd (fail-open, no crash).
# ---------------------------------------------------------------------------
OUTSIDE_DIR="$TMPDIR_BASE/t15/outside"
mkdir -p "$OUTSIDE_DIR"
H15="$TMPDIR_BASE/t15/home"
mkdir -p "$H15"
OUTSIDE_OUT=$(cd "$OUTSIDE_DIR" && python3 "$CHECKER" --home "$H15" --json 2>/dev/null)
OUTSIDE_CODE=$?
OUTSIDE_ERR=$(cd "$OUTSIDE_DIR" && python3 "$CHECKER" --home "$H15" --json 2>&1 >/dev/null)
if [ "$OUTSIDE_CODE" = "0" ] && [ -z "$OUTSIDE_ERR" ] \
   && [ "$(_jget "$OUTSIDE_OUT" 'd["any_due"]')" = "False" ]; then
    _pass "T15: outside-project fallback -> exit 0, any_due=false, no stderr (cwd used as root)"
else
    _fail "T15: expected clean fail-open when outside any project" \
          "code=$OUTSIDE_CODE err=$OUTSIDE_ERR out=$OUTSIDE_OUT"
fi

# ---------------------------------------------------------------------------
# T16: EXPLICIT --root OVERRIDES cwd resolution
#      Proves that passing --root bypasses _resolve_root entirely.
# ---------------------------------------------------------------------------
R="$TMPDIR_BASE/t16/root"; H="$TMPDIR_BASE/t16/home"
mkdir -p "$R/.claude/ainous-roles/coordinator" "$H"
_playbook "$H" developer "$(_days_ago 3)"
_journal_entries "$R" developer "$(_days_ago 2)" "$(_days_ago 1)" "$(_days_ago 0)"
printf '## %s note\n' "$(_days_ago 0)" > "$R/.claude/ainous-roles/coordinator/journal.md"
# cwd is a random tmpdir outside the project tree — but --root overrides
UNRELATED_DIR="$TMPDIR_BASE/t16/unrelated"
mkdir -p "$UNRELATED_DIR"
EXPLICIT_OUT=$(cd "$UNRELATED_DIR" && python3 "$CHECKER" --root "$R" --home "$H" --json 2>/dev/null)
if [ "$(_jget "$EXPLICIT_OUT" 'd["consolidation_due"]')" = "True" ]; then
    _pass "T16: explicit --root from unrelated cwd -> sees correct project tree (consolidation due)"
else
    _fail "T16: explicit --root did not override cwd; expected consolidation_due=True" "$EXPLICIT_OUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed"
if [ "${#FINDINGS[@]}" -gt 0 ]; then
    echo ""
    echo "Findings (${#FINDINGS[@]}):"
    for f in "${FINDINGS[@]}"; do echo "  - $f"; done
fi
[ "$TESTS_FAIL" -eq 0 ]
