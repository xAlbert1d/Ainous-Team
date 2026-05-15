#!/usr/bin/env bash
# compute-envelope-hmac.sh — Canonical HMAC helper for write-proxy envelopes.
#
# Usage:
#   HMAC=$(echo "<full envelope text>" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/compute-envelope-hmac.sh" "$NONCE")
#
# Stdin:  Full envelope text including the '<!-- WRITE-PROXY-ENVELOPE v1 -->'
#         marker. The hmac: line may be empty or absent — it is stripped before
#         computation (same as the write-proxy hook does on verification).
# Stdout: Hex HMAC string.
# Exit:   0 on success, 2 on any error (missing marker, invalid nonce hex, etc.)
#
# This script wraps hooks/_hmac_common.py — the same module hooks/write-proxy
# uses for verification. They cannot disagree because they share one formula.

set -uo pipefail

NONCE="${1:-}"

if [ -z "$NONCE" ]; then
    echo "usage: compute-envelope-hmac.sh <nonce_hex>" >&2
    exit 2
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    # Best-effort: resolve relative to this script's location
    PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

HMAC_MODULE="${PLUGIN_ROOT}/hooks/_hmac_common.py"

if [ ! -f "$HMAC_MODULE" ]; then
    echo "error: _hmac_common.py not found at ${HMAC_MODULE}" >&2
    exit 2
fi

# Pass stdin directly to the Python module (do not buffer in a shell variable —
# that would strip trailing newlines and <<< would add one back, changing the HMAC body).
python3 "$HMAC_MODULE" "$NONCE"
