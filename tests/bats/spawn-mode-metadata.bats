#!/usr/bin/env bats
# spawn-mode-metadata.bats — Validates preferred_spawn_mode in capability JSON files
#                            and confirms the spawn event schema accepts a "mode" field.
#
# Coverage:
#   Test 1: Every capability JSON has a preferred_spawn_mode field
#   Test 2: Every preferred_spawn_mode value is one of {agent, tmux, auto}
#   Test 3: index.json is still valid JSON (unchanged structure)
#   Test 4: A sample spawn event with "mode":"tmux" parses correctly as valid JSON
#
# Run: bats tests/bats/spawn-mode-metadata.bats
# Exit 0 = all tests pass.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CAPS_DIR="$PROJECT_ROOT/agents/capabilities"

# Dynamically discover all role capability files (index.json excluded).
# This avoids stale hardcoded lists when roles are added or removed.
load_role_files() {
  ROLE_FILES=()
  for f in "$CAPS_DIR"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "index.json" ] && continue
    ROLE_FILES+=("$base")
  done
}

@test "every capability JSON has a preferred_spawn_mode field" {
  load_role_files
  [ "${#ROLE_FILES[@]}" -gt 0 ] || fail "No capability JSON files found in $CAPS_DIR"
  for role_file in "${ROLE_FILES[@]}"; do
    path="$CAPS_DIR/$role_file"
    [ -f "$path" ] || fail "Missing capability file: $role_file"
    # python3 returns exit 1 if key missing (KeyError)
    python3 -c "
import json, sys
with open('$path') as f:
    d = json.load(f)
if 'preferred_spawn_mode' not in d:
    sys.exit(1)
" || fail "$role_file is missing preferred_spawn_mode"
  done
}

@test "every preferred_spawn_mode value is one of {agent, tmux, auto}" {
  load_role_files
  [ "${#ROLE_FILES[@]}" -gt 0 ] || fail "No capability JSON files found in $CAPS_DIR"
  valid_values='{"agent", "tmux", "auto"}'
  for role_file in "${ROLE_FILES[@]}"; do
    path="$CAPS_DIR/$role_file"
    python3 -c "
import json, sys
with open('$path') as f:
    d = json.load(f)
val = d.get('preferred_spawn_mode', '')
if val not in ('agent', 'tmux', 'auto'):
    print(f'Invalid preferred_spawn_mode \"{val}\" in $role_file', file=sys.stderr)
    sys.exit(1)
" || fail "$role_file has invalid preferred_spawn_mode value"
  done
}

@test "index.json is still valid JSON" {
  python3 -c "
import json
with open('$CAPS_DIR/index.json') as f:
    json.load(f)
" || fail "index.json is not valid JSON"
}

@test "spawn event with mode field parses as valid JSON" {
  sample='{"timestamp":"2026-04-17T00:00:00Z","event":"spawn","role":"developer","phase":"implement","detail":"build feature","scope":["agents/capabilities/*.json"],"mode":"tmux"}'
  python3 -c "
import json, sys
event = json.loads('$sample')
assert event['mode'] == 'tmux', 'mode field value mismatch'
assert event['event'] == 'spawn', 'event type mismatch'
" || fail "spawn event with mode field did not parse correctly"
}
