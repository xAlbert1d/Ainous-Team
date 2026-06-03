#!/usr/bin/env bash
# pre-ship-gate.sh — Combined release gate (v5.12.0)
#
# Runs all pre-ship checks in order. Exit 0 iff ALL checks pass.
#
# Checks:
#   1. verify-role-infrastructure.sh    — all roles have complete 4-file scaffold (v5.6.7)
#   2. verify-hook-env-vars.sh          — hook env-var references verified in Claude Code binary (v5.9.1 R-6)
#   3. memory-maintain.py --check       — memory cap violations (P0, v5.11.0)
#   4. memory-maintain.py --check       — trust level audit (P1 architectural safety net, v5.11.0)
#                                         (Gates 3 and 4 both run memory-maintain --check; Gate 4
#                                          reports trust violations separately for clarity.  A single
#                                          --check pass covers both because trust_audit is wired into
#                                          the main per-role loop.)
#   5. verify-model-consistency.sh      — model field in agents/<role>.md == capabilities/<role>.json
#                                         (P2 drift guard: agents-md is authoritative)
#   6. gen-hook-manifest.sh diff        — committed hooks/manifest.sha256 is current
#                                         (P0-2, OWASP ASI04: forces shipping a fresh
#                                          hook/script integrity manifest; tamper-EVIDENCE
#                                          for the plugin's own executable surface)
#   7. gen-skill-index.py --check       — committed index.json skills block is current (Gate 7a)
#                                         + reachability: every skills/ dir cataloged; every
#                                           invocable:true skill has ≥1 owning_role; the ONLY
#                                           invocable:false entry is image-craft-base (Gate 7b)
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
#   5 — model consistency drift detected
#   6 — hook-integrity manifest stale (regenerate via gen-hook-manifest.sh)
#   7 — skill-index stale or reachability violation (regenerate via gen-skill-index.py)

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
MODEL_EXIT=0
MANIFEST_EXIT=0
SKILLIDX_EXIT=0

printf '=%.0s' {1..70}; printf '\n'
printf 'pre-ship-gate.sh — ainous-team release gate\n'
printf '=%.0s' {1..70}; printf '\n\n'

# ---------------------------------------------------------------------------
# Gate 1: Role infrastructure check (verify-role-infrastructure.sh)
# ---------------------------------------------------------------------------
printf '[Gate 1/7] Role infrastructure check (verify-role-infrastructure.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

# shellcheck disable=SC2086
bash "$SCRIPT_DIR/verify-role-infrastructure.sh" $VERBOSE_FLAG
INFRA_EXIT=$?

if [ "$INFRA_EXIT" -eq 0 ]; then
    printf '[Gate 1/7] PASS\n\n'
else
    printf '[Gate 1/7] FAIL (exit %d) — role infrastructure gaps found\n\n' "$INFRA_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 2: Hook env-var liveness check (verify-hook-env-vars.sh)
# ---------------------------------------------------------------------------
printf '[Gate 2/7] Hook env-var liveness check (verify-hook-env-vars.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

bash "$SCRIPT_DIR/verify-hook-env-vars.sh" $VERBOSE_FLAG
ENVVAR_EXIT=$?

if [ "$ENVVAR_EXIT" -eq 0 ]; then
    printf '[Gate 2/7] PASS\n\n'
else
    printf '[Gate 2/7] FAIL (exit %d) — fabricated env var(s) referenced in hooks\n\n' "$ENVVAR_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 3: Memory cap check (scripts/memory-maintain.py --check)
# P0: mechanical memory cap enforcement — detect violations before shipping.
# ---------------------------------------------------------------------------
printf '[Gate 3/7] Memory cap check (scripts/memory-maintain.py --check)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

if command -v python3 &>/dev/null && [ -f "$SCRIPT_DIR/memory-maintain.py" ]; then
    python3 "$SCRIPT_DIR/memory-maintain.py" --check ${VERBOSE_FLAG:+--verbose}
    MEMCAP_EXIT=$?
else
    printf '[Gate 3/7] SKIP — python3 not found or memory-maintain.py missing\n\n'
    MEMCAP_EXIT=0
fi

if [ "$MEMCAP_EXIT" -eq 0 ]; then
    printf '[Gate 3/7] PASS\n\n'
else
    printf '[Gate 3/7] FAIL (exit %d) — memory cap violations detected\n\n' "$MEMCAP_EXIT"
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
printf '[Gate 4/7] Trust audit (scripts/memory-maintain.py --check)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

if command -v python3 &>/dev/null && [ -f "$SCRIPT_DIR/memory-maintain.py" ]; then
    python3 "$SCRIPT_DIR/memory-maintain.py" --check --verbose 2>&1 | grep -i "trust\|CLAMP" || true
    # Re-run for the exit code (grep above eats it)
    python3 "$SCRIPT_DIR/memory-maintain.py" --check ${VERBOSE_FLAG:+--verbose} > /dev/null 2>&1
    TRUST_EXIT=$?
else
    printf '[Gate 4/7] SKIP — python3 not found or memory-maintain.py missing\n\n'
    TRUST_EXIT=0
fi

if [ "$TRUST_EXIT" -eq 0 ]; then
    printf '[Gate 4/7] PASS\n\n'
else
    printf '[Gate 4/7] FAIL (exit %d) — trust audit violations detected\n\n' "$TRUST_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 5: Model consistency check (scripts/verify-model-consistency.sh)
# P2: single-source-of-truth guard — agents/<role>.md frontmatter model: is
# authoritative; capabilities/<role>.json model must match.
# ---------------------------------------------------------------------------
printf '[Gate 5/7] Model consistency check (scripts/verify-model-consistency.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

if [ -f "$SCRIPT_DIR/verify-model-consistency.sh" ]; then
    # shellcheck disable=SC2086
    bash "$SCRIPT_DIR/verify-model-consistency.sh" $VERBOSE_FLAG
    MODEL_EXIT=$?
else
    printf '[Gate 5/7] SKIP — verify-model-consistency.sh not found\n\n'
    MODEL_EXIT=0
fi

if [ "$MODEL_EXIT" -eq 0 ]; then
    printf '[Gate 5/7] PASS\n\n'
else
    printf '[Gate 5/7] FAIL (exit %d) — model consistency drift detected\n\n' "$MODEL_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 6: Hook-integrity manifest freshness (scripts/gen-hook-manifest.sh)
# P0-2 (OWASP ASI04): regenerate the manifest into a temp file and diff against
# the committed hooks/manifest.sha256. FAIL if they differ — this forces every
# release to ship a current manifest, so session-start's tamper-evidence check
# has an accurate baseline. (Comment/header lines are excluded from the diff so
# only the actual digest data is compared.)
# ---------------------------------------------------------------------------
printf '[Gate 6/7] Hook-integrity manifest freshness (scripts/gen-hook-manifest.sh)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

_MANIFEST_COMMITTED="$SCRIPT_DIR/../hooks/manifest.sha256"
if [ ! -f "$SCRIPT_DIR/gen-hook-manifest.sh" ]; then
    printf '[Gate 6/7] SKIP — gen-hook-manifest.sh not found\n\n'
    MANIFEST_EXIT=0
elif [ ! -f "$_MANIFEST_COMMITTED" ]; then
    printf '[Gate 6/7] FAIL — committed hooks/manifest.sha256 is missing; run gen-hook-manifest.sh\n\n'
    MANIFEST_EXIT=6
    GATE_FAILED=1
else
    _MANIFEST_TMP="$(mktemp 2>/dev/null || echo "/tmp/ainous-manifest.$$.tmp")"
    # Regenerate to stdout (does not touch the committed file).
    if bash "$SCRIPT_DIR/gen-hook-manifest.sh" --stdout > "$_MANIFEST_TMP" 2>/dev/null; then
        # Compare data lines only (strip comments/blank lines from both sides).
        if diff <(grep -v -e '^#' -e '^[[:space:]]*$' "$_MANIFEST_COMMITTED") \
                <(grep -v -e '^#' -e '^[[:space:]]*$' "$_MANIFEST_TMP") >/dev/null 2>&1; then
            MANIFEST_EXIT=0
        else
            MANIFEST_EXIT=6
            if [ -n "$VERBOSE_FLAG" ]; then
                printf 'Manifest drift (committed vs freshly generated):\n'
                diff <(grep -v -e '^#' -e '^[[:space:]]*$' "$_MANIFEST_COMMITTED") \
                     <(grep -v -e '^#' -e '^[[:space:]]*$' "$_MANIFEST_TMP") || true
            fi
        fi
    else
        # gen-hook-manifest.sh failed (e.g. a covered file missing) — that is a
        # ship-blocking condition for the integrity surface.
        MANIFEST_EXIT=6
        printf 'gen-hook-manifest.sh failed to regenerate manifest.\n'
    fi
    rm -f "$_MANIFEST_TMP" 2>/dev/null || true
fi

if [ "$MANIFEST_EXIT" -eq 0 ]; then
    printf '[Gate 6/7] PASS\n\n'
else
    printf '[Gate 6/7] FAIL (exit %d) — committed hooks/manifest.sha256 is stale; run: bash scripts/gen-hook-manifest.sh\n\n' "$MANIFEST_EXIT"
    GATE_FAILED=1
fi

# ---------------------------------------------------------------------------
# Gate 7a: Skill-index freshness (scripts/gen-skill-index.py --check)
# Gate 7b: Reachability — every skills/ dir is cataloged; every invocable:true
#          skill has >=1 owning_role; the ONLY invocable:false entry is
#          image-craft-base (any other invocable:false skill → FAIL).
# ---------------------------------------------------------------------------
printf '[Gate 7/7] Skill-index freshness + reachability (scripts/gen-skill-index.py)\n'
printf '%s\n' "$(printf '%0.s-' {1..70})"

_INDEX_JSON="$SCRIPT_DIR/../agents/capabilities/index.json"

if [ ! -f "$SCRIPT_DIR/gen-skill-index.py" ]; then
    printf '[Gate 7/7] SKIP — gen-skill-index.py not found\n\n'
    SKILLIDX_EXIT=0
elif ! command -v python3 &>/dev/null; then
    printf '[Gate 7/7] SKIP — python3 not found\n\n'
    SKILLIDX_EXIT=0
else
    # Gate 7a: freshness check — exits 2 on drift
    python3 "$SCRIPT_DIR/gen-skill-index.py" --check
    _7a_exit=$?

    # Gate 7b: reachability checks via index.json + skills/ dir
    _7b_exit=0

    if [ "$_7a_exit" -ne 0 ]; then
        _7b_exit=7   # skip reachability if index is stale (stale data is unreliable)
    elif [ -f "$_INDEX_JSON" ]; then
        # 7b-i: every skills/ dir has a catalog entry
        _disk_only=$(_GATE7_SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PYEOF' 2>/dev/null
import os, json
script_dir = os.environ.get("_GATE7_SCRIPT_DIR", "")
skills_dir = os.path.join(script_dir, "..", "skills")
index_path = os.path.join(script_dir, "..", "agents", "capabilities", "index.json")
with open(index_path) as f:
    idx = json.load(f)
catalog = set(idx.get("skills", {}).keys())
missing = []
for entry in sorted(os.listdir(skills_dir)):
    skill_md = os.path.join(skills_dir, entry, "SKILL.md")
    if os.path.isdir(os.path.join(skills_dir, entry)) and os.path.isfile(skill_md):
        content = open(skill_md).read()
        name = ""
        if content.startswith("---"):
            end = content.find("---", 3)
            if end != -1:
                for line in content[3:end].strip().splitlines():
                    if line.strip().startswith("name:"):
                        name = line.split(":", 1)[1].strip().strip('"').strip("'")
        if name and name not in catalog:
            missing.append(name)
for m in missing:
    print(m)
PYEOF
)
        if [ -n "$_disk_only" ]; then
            printf 'Gate 7b FAIL — skills on disk with no catalog entry:\n'
            printf '  %s\n' "$_disk_only"
            _7b_exit=7
        fi

        # 7b-ii: every invocable:true skill has >=1 owning_role
        _no_owner=$(_GATE7_SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PYEOF2' 2>/dev/null
import os, json
script_dir = os.environ.get("_GATE7_SCRIPT_DIR", "")
index_path = os.path.join(script_dir, "..", "agents", "capabilities", "index.json")
with open(index_path) as f:
    idx = json.load(f)
for name, entry in sorted(idx.get("skills", {}).items()):
    invocable = entry.get("invocable", True)
    if invocable is True and not entry.get("owning_roles"):
        print(name)
PYEOF2
)
        if [ -n "$_no_owner" ]; then
            printf 'Gate 7b FAIL — invocable:true skills with no owning_role:\n'
            printf '  %s\n' "$_no_owner"
            _7b_exit=7
        fi

        # 7b-iii: the ONLY invocable:false entry is image-craft-base
        _extra_non_invocable=$(_GATE7_SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PYEOF3' 2>/dev/null
import os, json
script_dir = os.environ.get("_GATE7_SCRIPT_DIR", "")
index_path = os.path.join(script_dir, "..", "agents", "capabilities", "index.json")
with open(index_path) as f:
    idx = json.load(f)
for name, entry in sorted(idx.get("skills", {}).items()):
    invocable = entry.get("invocable", True)
    if invocable is False and name != "image-craft-base":
        print(name)
PYEOF3
)
        if [ -n "$_extra_non_invocable" ]; then
            printf 'Gate 7b FAIL — unexpected invocable:false skills (only image-craft-base is allowed):\n'
            printf '  %s\n' "$_extra_non_invocable"
            _7b_exit=7
        fi
    else
        printf 'Gate 7b SKIP — index.json not found\n'
    fi

    if [ "$_7a_exit" -ne 0 ]; then
        SKILLIDX_EXIT=7
    elif [ "$_7b_exit" -ne 0 ]; then
        SKILLIDX_EXIT=7
    else
        SKILLIDX_EXIT=0
    fi
fi

if [ "$SKILLIDX_EXIT" -eq 0 ]; then
    printf '[Gate 7/7] PASS\n\n'
else
    printf '[Gate 7/7] FAIL (exit %d) — skill-index stale or reachability violation; run: python3 scripts/gen-skill-index.py\n\n' "$SKILLIDX_EXIT"
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
    printf '  Gate 1 (role-infrastructure):    exit %d\n' "$INFRA_EXIT"
    printf '  Gate 2 (hook-env-vars):          exit %d\n' "$ENVVAR_EXIT"
    printf '  Gate 3 (memory-cap-check):       exit %d\n' "$MEMCAP_EXIT"
    printf '  Gate 4 (trust-audit):            exit %d\n' "$TRUST_EXIT"
    printf '  Gate 5 (model-consistency):      exit %d\n' "$MODEL_EXIT"
    printf '  Gate 6 (hook-integrity-manifest): exit %d\n' "$MANIFEST_EXIT"
    printf '  Gate 7 (skill-index):            exit %d\n' "$SKILLIDX_EXIT"
    # Return most specific exit code
    FAIL_COUNT=0
    [ "$INFRA_EXIT"    -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$ENVVAR_EXIT"   -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$MEMCAP_EXIT"   -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$TRUST_EXIT"    -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$MODEL_EXIT"    -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$MANIFEST_EXIT" -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$SKILLIDX_EXIT" -ne 0 ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_COUNT" -gt 1 ]; then
        exit 3
    elif [ "$SKILLIDX_EXIT" -ne 0 ]; then
        exit 7
    elif [ "$MANIFEST_EXIT" -ne 0 ]; then
        exit 6
    elif [ "$MODEL_EXIT" -ne 0 ]; then
        exit 5
    elif [ "$MEMCAP_EXIT" -ne 0 ] || [ "$TRUST_EXIT" -ne 0 ]; then
        exit 4
    elif [ "$ENVVAR_EXIT" -ne 0 ]; then
        exit 2
    else
        exit 1
    fi
fi
