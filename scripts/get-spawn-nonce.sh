#!/usr/bin/env bash
# get-spawn-nonce.sh — Read write_proxy_nonce from the canonical nonce file for a teammate.
#
# Usage: scripts/get-spawn-nonce.sh <teammate_name> [<team_name>]
#
# v5.7.0: nonce is no longer stored in task-history.jsonl (auth bypass fix).
# Canonical source is ~/.claude/teams/<team_name>/nonces/<teammate_name>.nonce (mode 0600).
# If team_name is not provided, scans the most recent spawn event in task-history to resolve it.
#
# Output: prints the nonce hex string to stdout, or exits 1 if not found.
# Used by tests to retrieve the nonce for HMAC construction.

set -uo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    printf 'Usage: get-spawn-nonce.sh <teammate_name> [<team_name>]\n' >&2
    exit 1
fi

TEAMMATE_NAME="$1"
TEAM_NAME="${2:-}"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TASK_HISTORY="${PROJECT_ROOT}/.claude/ainous-roles/team-sync/state/task-history.jsonl"

python3 - "$TEAMMATE_NAME" "$TEAM_NAME" "$TASK_HISTORY" << 'PYEOF'
import sys, json, os

teammate_name = sys.argv[1]
team_name     = sys.argv[2]   # May be empty
hist_path     = sys.argv[3]
teams_dir     = os.path.expanduser("~/.claude/teams")

# If team_name not provided, resolve it from the most recent spawn event
if not team_name:
    try:
        with open(hist_path, encoding='utf-8') as f:
            lines = f.readlines()
        for line in reversed(lines):
            try:
                ev = json.loads(line.strip())
                if ev.get('event') != 'spawn':
                    continue
                if ev.get('teammate_name') == teammate_name:
                    team_name = ev.get('team_name', '')
                    break
            except (json.JSONDecodeError, ValueError):
                continue
    except (FileNotFoundError, OSError) as exc:
        print(f"cannot read {hist_path}: {exc}", file=sys.stderr)

if not team_name:
    print(f"cannot resolve team_name for teammate_name={teammate_name!r}", file=sys.stderr)
    sys.exit(1)

# Read nonce from canonical nonce file
nonce_file = os.path.join(teams_dir, team_name, 'nonces', f'{teammate_name}.nonce')
try:
    with open(nonce_file, encoding='utf-8') as nf:
        nonce = nf.read().strip()
    if nonce:
        print(nonce)
        sys.exit(0)
    else:
        print(f"nonce file is empty: {nonce_file}", file=sys.stderr)
        sys.exit(1)
except (FileNotFoundError, PermissionError, OSError) as exc:
    print(f"cannot read nonce file {nonce_file}: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
