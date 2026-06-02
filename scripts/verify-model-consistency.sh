#!/usr/bin/env bash
# verify-model-consistency.sh — Mechanical model-drift cross-check
#
# For every role, asserts that the `model:` value in agents/<role>.md YAML
# frontmatter equals the `"model"` value in agents/capabilities/<role>.json.
# agents/<role>.md frontmatter is AUTHORITATIVE per CLAUDE.md.
#
# On mismatch, reports:
#   role: agents-md=X vs capabilities-json=Y
# and exits non-zero.
#
# NOTE: This script does NOT remove or restructure the model field in either
# source — the goal is to CATCH drift, not restructure.  The coordinator's
# routing logic may read capabilities.json's model field independently.
#
# Exit codes:
#   0 — all roles consistent (or no roles found)
#   1 — one or more roles have mismatched model values
#   2 — usage / environment error
#
# Usage:
#   bash scripts/verify-model-consistency.sh [--verbose]

set -uo pipefail

VERBOSE=0
for _arg in "$@"; do
    case "$_arg" in
        --verbose) VERBOSE=1 ;;
        *) printf 'Usage: verify-model-consistency.sh [--verbose]\n' >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$PROJECT_ROOT/agents"
CAPABILITIES_DIR="$AGENTS_DIR/capabilities"

if [ ! -d "$CAPABILITIES_DIR" ]; then
    printf 'error: capabilities dir not found: %s\n' "$CAPABILITIES_DIR" >&2
    exit 2
fi

if ! command -v python3 &>/dev/null; then
    printf 'error: python3 not found — required for JSON parsing\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Discover roles from capabilities/*.json (exclude index.json)
# ---------------------------------------------------------------------------
ROLES=()
while IFS= read -r _role; do
    ROLES+=("$_role")
done < <(
    for _f in "$CAPABILITIES_DIR"/*.json; do
        [ -f "$_f" ] || continue
        _base="$(basename "$_f" .json)"
        [ "$_base" = "index" ] && continue
        printf '%s\n' "$_base"
    done | sort
)

if [ ${#ROLES[@]} -eq 0 ]; then
    printf 'warning: no roles discovered in %s\n' "$CAPABILITIES_DIR"
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

printf 'Model consistency check: agents/<role>.md (authoritative) vs capabilities/<role>.json\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

for _role in "${ROLES[@]}"; do
    _md_file="$AGENTS_DIR/${_role}.md"
    _json_file="$CAPABILITIES_DIR/${_role}.json"

    # Check both files exist
    if [ ! -f "$_md_file" ]; then
        printf '  SKIP  %-18s agents/%s.md not found\n' "$_role" "$_role"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    if [ ! -f "$_json_file" ]; then
        printf '  SKIP  %-18s capabilities/%s.json not found\n' "$_role" "$_role"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Extract model from agents/<role>.md YAML frontmatter.
    # The frontmatter is between the first pair of `---` delimiters.
    # We extract the `model:` line from within that block.
    _md_model=$(python3 - "$_md_file" << 'PYEOF'
import sys, re

path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        content = f.read()
except OSError as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)

# Find YAML frontmatter between first pair of --- delimiters
lines = content.splitlines()
in_frontmatter = False
for i, line in enumerate(lines):
    if i == 0 and line.strip() == '---':
        in_frontmatter = True
        continue
    if in_frontmatter:
        if line.strip() == '---':
            break
        m = re.match(r'^model:\s*(\S+)', line)
        if m:
            print(m.group(1))
            sys.exit(0)

# Not found
sys.exit(1)
PYEOF
    )
    _md_exit=$?

    if [ "$_md_exit" -ne 0 ] || [ -z "$_md_model" ]; then
        printf '  SKIP  %-18s no model: field in agents/%s.md frontmatter\n' "$_role" "$_role"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Extract model from capabilities/<role>.json
    _json_model=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    m = d.get('model', '')
    if m:
        print(m)
        sys.exit(0)
    sys.exit(1)
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" "$_json_file" 2>/dev/null)
    _json_exit=$?

    if [ "$_json_exit" -ne 0 ] || [ -z "$_json_model" ]; then
        printf '  SKIP  %-18s no model field in capabilities/%s.json\n' "$_role" "$_role"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Compare
    if [ "$_md_model" = "$_json_model" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        if [ "$VERBOSE" -eq 1 ]; then
            printf '  OK    %-18s model=%s\n' "$_role" "$_md_model"
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  MISMATCH  %s: agents-md=%s vs capabilities-json=%s\n' \
            "$_role" "$_md_model" "$_json_model"
    fi
done

printf '%s\n' "$(printf '%0.s-' {1..70})"
printf 'Results: %d consistent, %d mismatched, %d skipped (of %d roles)\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "${#ROLES[@]}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\nFAILURE: %d role(s) have mismatched model values.\n' "$FAIL_COUNT"
    printf 'agents/<role>.md frontmatter is authoritative — update capabilities/<role>.json to match.\n'
    exit 1
fi

printf '\nAll roles consistent.\n'
exit 0
