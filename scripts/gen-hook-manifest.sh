#!/usr/bin/env bash
# gen-hook-manifest.sh — generate hooks/manifest.sha256 (P0-2, OWASP ASI04)
#
# Computes SHA-256 over the plugin's security-critical executable surface and
# writes hooks/manifest.sha256 (sorted, `<sha256>␠␠<relative-path>` per line).
# session-start recomputes these at load and warns on any mismatch.
#
# --------------------------------------------------------------------------
# HONESTY — what this is and what it is NOT
# --------------------------------------------------------------------------
# This is tamper-EVIDENCE, not tamper-PROOFing.
#
# An attacker who can rewrite the installed plugin cache
# (~/.claude/plugins/cache/ainous-team/.../) can ALSO rewrite hooks/session-start
# (the verifier) and hooks/manifest.sha256 (the baseline) to match their swapped
# files — fully defeating this check. There is no root of trust below the cache
# itself, so a fully-privileged cache-write attacker is out of scope.
#
# It still RAISES THE BAR and catches the most likely / partial cases:
#   - A single hook swapped (e.g. authority-enforce.sh replaced) without the
#     attacker also rewriting the manifest + session-start.
#   - Accidental corruption (truncated/partial file, failed update, bad merge).
#   - Incomplete substitution during a supply-chain push that misses the
#     manifest or the verifier.
#
# DELIBERATELY NOT DONE HERE: hard-fail enforcement (authority-enforce.sh
# refusing to operate on integrity failure). That is a viable stronger
# follow-up, but it risks bricking sessions on a false positive (e.g. a
# legitimately-edited-but-unregenerated hook in a dev checkout). This
# deliverable is detection + alert only; session-start is fail-OPEN.
# --------------------------------------------------------------------------
#
# Usage:
#   bash scripts/gen-hook-manifest.sh            # write hooks/manifest.sha256
#   bash scripts/gen-hook-manifest.sh --stdout   # print manifest, do not write
#
# Exit codes:
#   0 — manifest generated (or printed)
#   1 — no SHA-256 tool available, or a covered file is missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_PATH="$PLUGIN_ROOT/hooks/manifest.sha256"

TO_STDOUT=0
for _arg in "$@"; do
    case "$_arg" in
        --stdout) TO_STDOUT=1 ;;
        *) printf 'Usage: gen-hook-manifest.sh [--stdout]\n' >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Security-critical executable surface covered by integrity verification.
# Paths are relative to the plugin root. The manifest file itself is EXCLUDED
# (it cannot hash itself). Keep this list in sync with session-start's verifier
# — session-start reads the manifest, so adding a line here is enough.
# ---------------------------------------------------------------------------
COVERED_FILES=(
    "hooks/authority-enforce.sh"
    "hooks/write-proxy"
    "hooks/spawn-telemetry"
    "hooks/taint-flag"
    "hooks/skill-telemetry"
    "hooks/session-start"
    "hooks/session-end"
    "hooks/teammate-lifecycle-reaper"
    "hooks/_hmac_common.py"
    "hooks/_provenance_common.py"
    "scripts/memory-maintain.py"
)

# ---------------------------------------------------------------------------
# SHA-256 helper: prefer `shasum -a 256` (macOS/BSD), fall back to `sha256sum`
# (Linux). Echoes the bare hex digest for a single file path ($1).
# ---------------------------------------------------------------------------
_sha256_tool=""
if command -v shasum >/dev/null 2>&1; then
    _sha256_tool="shasum"
elif command -v sha256sum >/dev/null 2>&1; then
    _sha256_tool="sha256sum"
else
    printf 'gen-hook-manifest.sh: ERROR — no SHA-256 tool (shasum/sha256sum) found\n' >&2
    exit 1
fi

_sha256_of() {
    # $1 = absolute file path -> prints bare hex digest
    if [ "$_sha256_tool" = "shasum" ]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# Build manifest lines. Format: "<sha256>  <relative-path>" (two spaces) —
# matches the native `shasum`/`sha256sum` output format so the file is also
# checkable with `shasum -a 256 -c` from the plugin root if desired.
# ---------------------------------------------------------------------------
_manifest=""
_missing=0
for _rel in "${COVERED_FILES[@]}"; do
    _abs="$PLUGIN_ROOT/$_rel"
    if [ ! -f "$_abs" ]; then
        printf 'gen-hook-manifest.sh: ERROR — covered file missing: %s\n' "$_rel" >&2
        _missing=1
        continue
    fi
    _digest="$(_sha256_of "$_abs")"
    if [ -z "$_digest" ]; then
        printf 'gen-hook-manifest.sh: ERROR — could not hash: %s\n' "$_rel" >&2
        _missing=1
        continue
    fi
    _manifest+="${_digest}  ${_rel}"$'\n'
done

if [ "$_missing" -ne 0 ]; then
    printf 'gen-hook-manifest.sh: aborting — one or more covered files missing/unhashable\n' >&2
    exit 1
fi

# Sort by path for deterministic output (stable across runs / machines).
# LC_ALL=C for byte-stable ordering.
_manifest_sorted="$(printf '%s' "$_manifest" | LC_ALL=C sort -k2)"

if [ "$TO_STDOUT" -eq 1 ]; then
    printf '%s\n' "$_manifest_sorted"
    exit 0
fi

{
    printf '# ainous-team hook/script integrity manifest (P0-2, OWASP ASI04)\n'
    printf '# Generated by scripts/gen-hook-manifest.sh — DO NOT edit by hand.\n'
    printf '# Regenerate after any change to a covered file (pre-ship Gate 6 enforces this).\n'
    printf '# Format: <sha256>  <path-relative-to-plugin-root>\n'
    printf '# tamper-EVIDENCE, not tamper-PROOFing — see gen-hook-manifest.sh header.\n'
    printf '%s\n' "$_manifest_sorted"
} > "$MANIFEST_PATH"

printf 'gen-hook-manifest.sh: wrote %d entries to %s\n' \
    "${#COVERED_FILES[@]}" "$MANIFEST_PATH"
exit 0
