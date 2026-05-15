#!/usr/bin/env bash
# pre-ship-gate.sh — Combined release gate (v5.9.1)
#
# Runs all pre-ship checks in order. Exit 0 iff ALL checks pass.
#
# Checks:
#   1. verify-role-infrastructure.sh — all roles have complete 4-file scaffold (v5.6.7)
#   2. verify-hook-env-vars.sh       — hook env-var references verified in Claude Code binary (v5.9.1 R-6)
#
# Usage:
#   bash scripts/pre-ship-gate.sh [--verbose]
#
# Exit codes:
#   0 — all checks pass; safe to ship
#   1 — role infrastructure gaps found
#   2 — hook env-var liveness failure (fabricated var referenced)
#   3 — multiple checks failed

set -uo pipefail

VERBOSE_FLAG=""
for _arg in "$@"; do
    case "$_arg" in
        --verbose) VERBOSE_FLAG="--verbose" ;;
        *) printf 'Usage: pre-ship-gate.sh [--verbose]\n' >&2; exit 3 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GATE_FAILED=0
INFRA_EXIT=0
ENVVAR_EXIT=0

printf '=%.0s' {1..70}; printf '\n'
printf 'pre-ship-gate.sh — ainous-team release gate\n'
printf '=%.0s' {1..70}; printf '\n\n'

# ---------------------------------------------------------------------------
# Gate 1: Role infrastructure check (verify-role-infrastructure.sh)
# ---------------------------------------------------------------------------
printf '[Gate 1/2] Role infrastructure check (verify-role-infrastructure.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

# shellcheck disable=SC2086
bash "$SCRIPT_DIR/verify-role-infrastructure.sh" $VERBOSE_FLAG
INFRA_EXIT=$?

if [ "$INFRA_EXIT" -eq 0 ]; then
    printf '[Gate 1/2] PASS\n\n'
else
    printf '[Gate 1/2] FAIL (exit %d) — role infrastructure gaps found\n\n' "$INFRA_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 2: Hook env-var liveness check (verify-hook-env-vars.sh)
# ---------------------------------------------------------------------------
printf '[Gate 2/2] Hook env-var liveness check (verify-hook-env-vars.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

bash "$SCRIPT_DIR/verify-hook-env-vars.sh" $VERBOSE_FLAG
ENVVAR_EXIT=$?

if [ "$ENVVAR_EXIT" -eq 0 ]; then
    printf '[Gate 2/2] PASS\n\n'
else
    printf '[Gate 2/2] FAIL (exit %d) — fabricated env var(s) referenced in hooks\n\n' "$ENVVAR_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '=%.0s' {1..70}; printf '\n'
if [ "$GATE_FAILED" -eq 0 ]; then
    printf 'pre-ship-gate: ALL CHECKS PASSED — safe to ship\n'
    exit 0
else
    printf 'pre-ship-gate: FAILED\n'
    printf '  Gate 1 (role-infrastructure): exit %d\n' "$INFRA_EXIT"
    printf '  Gate 2 (hook-env-vars):       exit %d\n' "$ENVVAR_EXIT"
    # Return most specific exit code: if only one failed, return its code
    if [ "$INFRA_EXIT" -ne 0 ] && [ "$ENVVAR_EXIT" -ne 0 ]; then
        exit 3
    elif [ "$ENVVAR_EXIT" -ne 0 ]; then
        exit 2
    else
        exit 1
    fi
fi
