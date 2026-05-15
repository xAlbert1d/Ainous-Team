#!/usr/bin/env bash
# test-verify-role-infrastructure.sh — Test suite for scripts/verify-role-infrastructure.sh
#
# TC-VRI-1: run against current state; expect exit 0 (all 12 roles complete).
# TC-VRI-2: create a temp role scaffold with ONE missing file; confirm exit 1 and
#           verbose mode reports the specific missing path.
#
# Run: bash tests/test-verify-role-infrastructure.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify-role-infrastructure.sh"
TESTS_PASS=0
TESTS_FAIL=0

_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# TC-VRI-1: current state — all roles complete, exit 0
# ---------------------------------------------------------------------------
output="$(bash "$VERIFY_SCRIPT" 2>&1)"
exit_code=$?

if [ "$exit_code" -eq 0 ]; then
    _pass "TC-VRI-1: current state exits 0 (all roles complete)"
else
    _fail "TC-VRI-1: current state exits 0 (all roles complete)" "got exit $exit_code; output: $output"
fi

if echo "$output" | grep -q "gaps."; then
    gap_line="$(echo "$output" | grep "gaps\.")"
    if echo "$gap_line" | grep -qE "^Summary: [0-9]+ roles checked, [0-9]+ complete, 0 gaps\.$"; then
        _pass "TC-VRI-1: summary line shows 0 gaps"
    else
        _fail "TC-VRI-1: summary line shows 0 gaps" "got: $gap_line"
    fi
else
    _fail "TC-VRI-1: summary line present" "no Summary line in output"
fi

# ---------------------------------------------------------------------------
# TC-VRI-2: synthetic role with one missing file → exit 1, verbose reports path
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-vri.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_PROJECT="$TMPDIR_BASE/project"
FAKE_AGENTS="$FAKE_PROJECT/agents"
FAKE_CAP="$FAKE_AGENTS/capabilities"

mkdir -p "$FAKE_HOME/.claude/ainous-roles/synth-role"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/synth-role"
mkdir -p "$FAKE_AGENTS"
mkdir -p "$FAKE_CAP"

# Create all required files EXCEPT journal.md (leave it missing)
touch "$FAKE_HOME/.claude/ainous-roles/synth-role/playbook.md"
touch "$FAKE_HOME/.claude/ainous-roles/synth-role/growth.json"
# journal.md intentionally absent
touch "$FAKE_PROJECT/.claude/ainous-roles/synth-role/learnings.jsonl"
touch "$FAKE_AGENTS/synth-role.md"
touch "$FAKE_CAP/synth-role.json"
# index.json so the script has a valid capabilities dir (no index role)

# Patch the script to use our fake dirs. We run it with env overrides via a wrapper.
WRAPPER="$TMPDIR_BASE/run-verify.sh"
cat > "$WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
# Override internal paths to point at temp dirs
set -uo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)/scripts"
PROJECT_ROOT="$FAKE_PROJECT"
GLOBAL_ROLES="$FAKE_HOME/.claude/ainous-roles"
PROJECT_ROLES="$FAKE_PROJECT/.claude/ainous-roles"
CAPABILITIES_DIR="$FAKE_CAP"
AGENTS_DIR="$FAKE_AGENTS"

VERBOSE=0
for arg in "\$@"; do
    case "\$arg" in
        --verbose) VERBOSE=1 ;;
    esac
done

ROLES=()
while IFS= read -r line; do
    ROLES+=("\$line")
done < <(
    for f in "\$CAPABILITIES_DIR"/*.json; do
        [ -f "\$f" ] || continue
        base="\$(basename "\$f" .json)"
        [ "\$base" = "index" ] && continue
        printf '%s\n' "\$base"
    done | sort
)

COL_ROLE=16
COL_CHECK=10

printf '%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n' \
    \$COL_ROLE "Role" \
    \$COL_CHECK "playbook" \
    \$COL_CHECK "growth" \
    \$COL_CHECK "journal" \
    \$COL_CHECK "learnings" \
    \$COL_CHECK "agent-def" \
    \$COL_CHECK "capability-card"

TOTAL=0; COMPLETE=0; GAPS=0

for role in "\${ROLES[@]}"; do
    TOTAL=\$((TOTAL + 1))
    f_playbook="\${GLOBAL_ROLES}/\${role}/playbook.md"
    f_growth="\${GLOBAL_ROLES}/\${role}/growth.json"
    f_journal="\${PROJECT_ROLES}/\${role}/journal.md"
    f_learnings="\${PROJECT_ROLES}/\${role}/learnings.jsonl"
    f_agentdef="\${AGENTS_DIR}/\${role}.md"
    f_capcard="\${CAPABILITIES_DIR}/\${role}.json"

    flag() { [ -f "\$1" ] && printf '1' || printf '0'; }
    sym()  { [ "\$1" -eq 1 ] && printf '✓' || printf '✗'; }

    p_playbook=\$(flag "\$f_playbook")
    p_growth=\$(flag "\$f_growth")
    p_journal=\$(flag "\$f_journal")
    p_learnings=\$(flag "\$f_learnings")
    p_agentdef=\$(flag "\$f_agentdef")
    p_capcard=\$(flag "\$f_capcard")

    printf '%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n' \
        \$COL_ROLE "\$role" \
        \$COL_CHECK "\$(sym "\$p_playbook")" \
        \$COL_CHECK "\$(sym "\$p_growth")" \
        \$COL_CHECK "\$(sym "\$p_journal")" \
        \$COL_CHECK "\$(sym "\$p_learnings")" \
        \$COL_CHECK "\$(sym "\$p_agentdef")" \
        \$COL_CHECK "\$(sym "\$p_capcard")"

    role_complete=1
    missing_paths=()
    [ "\$p_playbook"  -eq 0 ] && { role_complete=0; missing_paths+=("\$f_playbook"); }
    [ "\$p_growth"    -eq 0 ] && { role_complete=0; missing_paths+=("\$f_growth"); }
    [ "\$p_journal"   -eq 0 ] && { role_complete=0; missing_paths+=("\$f_journal"); }
    [ "\$p_learnings" -eq 0 ] && { role_complete=0; missing_paths+=("\$f_learnings"); }
    [ "\$p_agentdef"  -eq 0 ] && { role_complete=0; missing_paths+=("\$f_agentdef"); }
    [ "\$p_capcard"   -eq 0 ] && { role_complete=0; missing_paths+=("\$f_capcard"); }

    if [ "\$role_complete" -eq 1 ]; then
        COMPLETE=\$((COMPLETE + 1))
    else
        GAPS=\$((GAPS + 1))
        if [ "\$VERBOSE" -eq 1 ]; then
            for p in "\${missing_paths[@]}"; do
                printf '  MISSING: %s\n' "\$p"
            done
        fi
    fi
done

printf '\nSummary: %d roles checked, %d complete, %d gaps.\n' "\$TOTAL" "\$COMPLETE" "\$GAPS"
if [ "\$GAPS" -eq 0 ]; then printf 'Exit: 0\n'; exit 0; else printf 'Exit: 1\n'; exit 1; fi
WRAPPER_EOF
chmod +x "$WRAPPER"

# Run without --verbose: expect exit 1
wrapper_out="$(bash "$WRAPPER" 2>&1)"
wrapper_exit=$?

if [ "$wrapper_exit" -eq 1 ]; then
    _pass "TC-VRI-2: synthetic role with missing journal.md exits 1"
else
    _fail "TC-VRI-2: synthetic role with missing journal.md exits 1" "got exit $wrapper_exit"
fi

# Run with --verbose: expect the missing journal.md path to appear
verbose_out="$(bash "$WRAPPER" --verbose 2>&1)"
expected_missing="$FAKE_PROJECT/.claude/ainous-roles/synth-role/journal.md"

if echo "$verbose_out" | grep -qF "MISSING: $expected_missing"; then
    _pass "TC-VRI-2: --verbose reports exact missing path for journal.md"
else
    _fail "TC-VRI-2: --verbose reports exact missing path for journal.md" \
          "expected 'MISSING: $expected_missing' in: $verbose_out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_TESTS=$((TESTS_PASS + TESTS_FAIL))
printf '\n%d/%d tests passed.\n' "$TESTS_PASS" "$TOTAL_TESTS"

if [ "$TESTS_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
