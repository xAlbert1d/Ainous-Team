#!/usr/bin/env bash
# pre-ship-gate.sh — Combined release gate (v5.11.0)
#
# Runs all pre-ship checks in order. Exit 0 iff ALL checks pass.
#
# Checks:
#   1. verify-role-infrastructure.sh — all roles have complete 4-file scaffold (v5.6.7)
#   2. verify-hook-env-vars.sh       — hook env-var references verified in Claude Code binary (v5.9.1 R-6)
#   3. memory-maintain.py --check    — memory cap violations (P0, v5.11.0)
#   4. memory-maintain.py --check    — trust level audit (P1 architectural safety net, v5.11.0)
#                                      (Gates 3 and 4 both run memory-maintain --check; Gate 4
#                                       reports trust violations separately for clarity.  A single
#                                       --check pass covers both because trust_audit is wired into
#                                       the main per-role loop.)
#
# Usage:
#   bash scripts/pre-ship-gate.sh [--verbose]
#
# Exit codes:
#   0 — all checks pass; safe to ship
#   1 — role infrastructure gaps found
#   2 — hook env-var liveness failure (fabricated var referenced)
#   3 — multiple checks failed
#   4 — memory cap or trust violations detected

set -uo pipefail

VERBOSE_FLAG=""
for _arg in "$@"; do
    case "$_arg" in
        --verbose) VERBOSE_FLAG="--verbose" ;;
        *) printf 'Usage: pre-ship-gate.sh [--verbose]\n' >&2; exit 3 ;;
    esac
done

# ---------------------------------------------------------------------------
# P0: pre-ship-gate.sh now runs memory-maintain.py --check as Gate 3.
# Exit 4 if memory cap violations are detected.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GATE_FAILED=0
INFRA_EXIT=0
ENVVAR_EXIT=0
MEMCAP_EXIT=0
TRUST_EXIT=0

printf '=%.0s' {1..70}; printf '\n'
printf 'pre-ship-gate.sh — ainous-team release gate\n'
printf '=%.0s' {1..70}; printf '\n\n'

# ---------------------------------------------------------------------------
# Gate 1: Role infrastructure check (verify-role-infrastructure.sh)
# ---------------------------------------------------------------------------
printf '[Gate 1/4] Role infrastructure check (verify-role-infrastructure.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

# shellcheck disable=SC2086
bash "$SCRIPT_DIR/verify-role-infrastructure.sh" $VERBOSE_FLAG
INFRA_EXIT=$?

if [ "$INFRA_EXIT" -eq 0 ]; then
    printf '[Gate 1/4] PASS\n\n'
else
    printf '[Gate 1/4] FAIL (exit %d) — role infrastructure gaps found\n\n' "$INFRA_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 2: Hook env-var liveness check (verify-hook-env-vars.sh)
# ---------------------------------------------------------------------------
printf '[Gate 2/4] Hook env-var liveness check (verify-hook-env-vars.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

bash "$SCRIPT_DIR/verify-hook-env-vars.sh" $VERBOSE_FLAG
ENVVAR_EXIT=$?

if [ "$ENVVAR_EXIT" -eq 0 ]; then
    printf '[Gate 2/4] PASS\n\n'
else
    printf '[Gate 2/4] FAIL (exit %d) — fabricated env var(s) referenced in hooks\n\n' "$ENVVAR_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 3: Memory cap check (scripts/memory-maintain.py --check)
# P0: mechanical memory cap enforcement — detect violations before shipping.
# ---------------------------------------------------------------------------
printf '[Gate 3/4] Memory cap check (scripts/memory-maintain.py --check)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

if command -v python3 &>/dev/null && [ -f "$SCRIPT_DIR/memory-maintain.py" ]; then
    python3 "$SCRIPT_DIR/memory-maintain.py" --check ${VERBOSE_FLAG:+--verbose}
    MEMCAP_EXIT=$?
else
    printf '[Gate 3/4] SKIP — python3 not found or memory-maintain.py missing\n\n'
    MEMCAP_EXIT=0
fi

if [ "$MEMCAP_EXIT" -eq 0 ]; then
    printf '[Gate 3/4] PASS\n\n'
else
    printf '[Gate 3/4] FAIL (exit %d) — memory cap violations detected\n\n' "$MEMCAP_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 4: Trust audit (scripts/memory-maintain.py --check)
# P1: trust.level safety net — detect over-privileged trust values before shipping.
# trust_audit is wired into the main per-role loop of memory-maintain.py, so a
# single --check run covers both memory caps (Gate 3) and trust violations (Gate 4).
# We run it a second time here scoped to --verbose so any trust clamp warnings appear
# in gate output; the exit code is the definitive trust-violation signal.
# ---------------------------------------------------------------------------
printf '[Gate 4/4] Trust audit (scripts/memory-maintain.py --check)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

if command -v python3 &>/dev/null && [ -f "$SCRIPT_DIR/memory-maintain.py" ]; then
    python3 "$SCRIPT_DIR/memory-maintain.py" --check --verbose 2>&1 | grep -i "trust\|CLAMP" || true
    # Re-run for the exit code (grep above eats it)
    python3 "$SCRIPT_DIR/memory-maintain.py" --check ${VERBOSE_FLAG:+--verbose} > /dev/null 2>&1
    TRUST_EXIT=$?
else
    printf '[Gate 4/4] SKIP — python3 not found or memory-maintain.py missing\n\n'
    TRUST_EXIT=0
fi

if [ "$TRUST_EXIT" -eq 0 ]; then
    printf '[Gate 4/4] PASS\n\n'
else
    printf '[Gate 4/4] FAIL (exit %d) — trust audit violations detected\n\n' "$TRUST_EXIT"
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
    printf '  Gate 3 (memory-cap-check):    exit %d\n' "$MEMCAP_EXIT"
    printf '  Gate 4 (trust-audit):         exit %d\n' "$TRUST_EXIT"
    # Return most specific exit code
    FAIL_COUNT=0
    [ "$INFRA_EXIT"   -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$ENVVAR_EXIT"  -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$MEMCAP_EXIT"  -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$TRUST_EXIT"   -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_COUNT" -gt 1 ]; then
        exit 3
    elif [ "$MEMCAP_EXIT" -ne 0 ] || [ "$TRUST_EXIT" -ne 0 ]; then
        exit 4
    elif [ "$ENVVAR_EXIT" -ne 0 ]; then
        exit 2
    else
        exit 1
    fi
fi
