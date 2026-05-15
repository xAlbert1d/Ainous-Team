#!/usr/bin/env bash
# verify-role-infrastructure.sh — Release-gate: verify all roles have complete 4-file scaffold.
#
# Per-role checks:
#   Location A (~/.claude/ainous-roles/<role>/):
#     1. playbook.md
#     2. growth.json
#   Location B (.claude/ainous-roles/<role>/):
#     3. journal.md
#     4. learnings.jsonl
#   Plugin side:
#     5. agents/<role>.md
#     6. agents/capabilities/<role>.json
#
# Usage: bash scripts/verify-role-infrastructure.sh [--verbose]
#
# Exit 0: all roles complete.
# Exit 1: one or more roles have missing files.
# Exit 2: usage/environment error.

set -uo pipefail

VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        *) printf 'Usage: verify-role-infrastructure.sh [--verbose]\n' >&2; exit 2 ;;
    esac
done

# Resolve project root from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOBAL_ROLES="${HOME}/.claude/ainous-roles"
PROJECT_ROLES="${PROJECT_ROOT}/.claude/ainous-roles"
CAPABILITIES_DIR="${PROJECT_ROOT}/agents/capabilities"
AGENTS_DIR="${PROJECT_ROOT}/agents"

# Discover roles from agents/capabilities/*.json (minus index.json)
if [ ! -d "$CAPABILITIES_DIR" ]; then
    printf 'error: capabilities dir not found: %s\n' "$CAPABILITIES_DIR" >&2
    exit 2
fi

ROLES=()
while IFS= read -r line; do
    ROLES+=("$line")
done < <(
    for f in "$CAPABILITIES_DIR"/*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"
        [ "$base" = "index" ] && continue
        printf '%s\n' "$base"
    done | sort
)

if [ ${#ROLES[@]} -eq 0 ]; then
    printf 'error: no roles discovered in %s\n' "$CAPABILITIES_DIR" >&2
    exit 2
fi

# Column widths
COL_ROLE=16
COL_CHECK=10

# Print header
printf '%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n' \
    $COL_ROLE "Role" \
    $COL_CHECK "playbook" \
    $COL_CHECK "growth" \
    $COL_CHECK "journal" \
    $COL_CHECK "learnings" \
    $COL_CHECK "agent-def" \
    $COL_CHECK "capability-card"

TOTAL=0
COMPLETE=0
GAPS=0

for role in "${ROLES[@]}"; do
    TOTAL=$((TOTAL + 1))

    f_playbook="${GLOBAL_ROLES}/${role}/playbook.md"
    f_growth="${GLOBAL_ROLES}/${role}/growth.json"
    f_journal="${PROJECT_ROLES}/${role}/journal.md"
    f_learnings="${PROJECT_ROLES}/${role}/learnings.jsonl"
    f_agentdef="${AGENTS_DIR}/${role}.md"
    f_capcard="${CAPABILITIES_DIR}/${role}.json"

    # Use integer flags: 1=present, 0=missing
    flag() { [ -f "$1" ] && printf '1' || printf '0'; }
    sym()  { [ "$1" -eq 1 ] && printf '✓' || printf '✗'; }

    p_playbook=$(flag "$f_playbook")
    p_growth=$(flag "$f_growth")
    p_journal=$(flag "$f_journal")
    p_learnings=$(flag "$f_learnings")
    p_agentdef=$(flag "$f_agentdef")
    p_capcard=$(flag "$f_capcard")

    printf '%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n' \
        $COL_ROLE "$role" \
        $COL_CHECK "$(sym "$p_playbook")" \
        $COL_CHECK "$(sym "$p_growth")" \
        $COL_CHECK "$(sym "$p_journal")" \
        $COL_CHECK "$(sym "$p_learnings")" \
        $COL_CHECK "$(sym "$p_agentdef")" \
        $COL_CHECK "$(sym "$p_capcard")"

    role_complete=1
    missing_paths=()

    [ "$p_playbook"  -eq 0 ] && { role_complete=0; missing_paths+=("$f_playbook"); }
    [ "$p_growth"    -eq 0 ] && { role_complete=0; missing_paths+=("$f_growth"); }
    [ "$p_journal"   -eq 0 ] && { role_complete=0; missing_paths+=("$f_journal"); }
    [ "$p_learnings" -eq 0 ] && { role_complete=0; missing_paths+=("$f_learnings"); }
    [ "$p_agentdef"  -eq 0 ] && { role_complete=0; missing_paths+=("$f_agentdef"); }
    [ "$p_capcard"   -eq 0 ] && { role_complete=0; missing_paths+=("$f_capcard"); }

    if [ "$role_complete" -eq 1 ]; then
        COMPLETE=$((COMPLETE + 1))
    else
        GAPS=$((GAPS + 1))
        if [ "$VERBOSE" -eq 1 ]; then
            for p in "${missing_paths[@]}"; do
                printf '  MISSING: %s\n' "$p"
            done
        fi
    fi
done

printf '\nSummary: %d roles checked, %d complete, %d gaps.\n' "$TOTAL" "$COMPLETE" "$GAPS"

if [ "$GAPS" -eq 0 ]; then
    printf 'Exit: 0\n'
    exit 0
else
    printf 'Exit: 1\n'
    exit 1
fi
