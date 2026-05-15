#!/usr/bin/env bash
# log-event.sh — Validated event writer for task-history.jsonl
#
# Usage: log-event <event-type> key=value key=value ...
#
# Env:
#   LOG_EVENT_MODE=warn (default) | enforce
#     warn:    validation failures log a warning but event is still appended
#     enforce: validation failures exit 2 and nothing is appended
#
#   CLAUDE_PROJECT_DIR — project root (defaults to cwd)
#
# Exit 0: event appended (with or without validation success in warn mode)
# Exit 2: validation failed in enforce mode — nothing appended
#
# Always sets schema: "1" on emitted events.
# Validation warnings logged to ~/.claude/ainous-team-telemetry.log
#
# Known event types (not exhaustive — schema validation is file-driven):
#   spawn, completed, failed, retried, gate-passed, gate-failed, skill-invoked,
#   hook-write, HALT, routing-decision, phase-transition, framing-doubt
#   teammate-nonce — emitted by coordinator before Agent spawn (v5.5.1 Option 2);
#     required fields: role, teammate_name, team_name, nonce (hex)

set -uo pipefail

LOG_EVENT_MODE="${LOG_EVENT_MODE:-warn}"
_DEBUG_LOG="${HOME}/.claude/ainous-team-telemetry.log"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TASK_HISTORY="${PROJECT_ROOT}/.claude/ainous-roles/team-sync/state/task-history.jsonl"
SCHEMAS_DIR="${PROJECT_ROOT}/schemas/events"

if [ $# -lt 1 ]; then
    printf 'Usage: log-event <event-type> key=value ...\n' >&2
    exit 2
fi

EVENT_TYPE="$1"
shift
KVARGS=("$@")

# Pass all arguments to python3 for JSON construction and validation
python3 - "$EVENT_TYPE" "$LOG_EVENT_MODE" "$TASK_HISTORY" "$SCHEMAS_DIR" "$_DEBUG_LOG" "${KVARGS[@]+"${KVARGS[@]}"}" << 'PYEOF'
import sys, json, os, re
from datetime import datetime, timezone

event_type = sys.argv[1]
mode       = sys.argv[2]   # warn | enforce
hist_path  = sys.argv[3]
schema_dir = sys.argv[4]
debug_log  = sys.argv[5]
kv_args    = sys.argv[6:]  # key=value pairs

def _log_warn(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(debug_log, "a", encoding="utf-8") as _f:
            _f.write(f"[{ts}] log-event schema-validation-warn: {msg}\n")
    except OSError:
        pass

# --- Parse key=value pairs ---
# Handles:
#   scope=a,b,c  → list ["a","b","c"]
#   mode=agent   → str "agent"
#   attempt=2    → int 2 (numeric strings become int)
#   blocking=false → bool False

def _coerce(key, val):
    """Coerce value: numeric → int, true/false → bool, comma-list for scope."""
    # scope and artifacts always become lists
    if key in ("scope", "artifacts", "phases", "artifacts_verified", "typed_candidates", "filtered", "uncertain_areas"):
        if val == "":
            return []
        return [v.strip() for v in val.split(",")]
    # boolean
    if val.lower() == "true":
        return True
    if val.lower() == "false":
        return False
    # integer
    try:
        return int(val)
    except ValueError:
        pass
    return val

event = {}
for arg in kv_args:
    if "=" not in arg:
        _log_warn(f"ignoring malformed kv arg (no '='): {arg!r}")
        continue
    k, _, v = arg.partition("=")
    k = k.strip()
    if not k:
        continue
    event[k] = _coerce(k, v)

# --- Auto-fill timestamp if missing ---
if "timestamp" not in event:
    event["timestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# --- Always set event field and schema ---
# event field: use provided value or default to event_type
if "event" not in event:
    event["event"] = event_type

event["schema"] = "1"

# --- Load schema ---
schema_path = os.path.join(schema_dir, f"{event_type}.json")
schema = None
if os.path.isfile(schema_path):
    try:
        with open(schema_path, encoding="utf-8") as sf:
            schema = json.load(sf)
    except (json.JSONDecodeError, OSError) as exc:
        _log_warn(f"could not load schema for {event_type}: {exc}")
else:
    _log_warn(f"no schema file for event type '{event_type}' at {schema_path}")

# --- Validate ---
validation_errors = []
if schema:
    required = schema.get("required", [])
    enums    = schema.get("enums", {})

    for field in required:
        if field not in event:
            validation_errors.append(f"missing required field '{field}'")

    for field, allowed in enums.items():
        if field in event:
            val = event[field]
            # For list fields, check each element
            if isinstance(val, list):
                for item in val:
                    if item not in allowed:
                        validation_errors.append(
                            f"field '{field}' contains invalid enum value '{item}'; allowed: {allowed}"
                        )
            elif val not in allowed:
                validation_errors.append(
                    f"field '{field}' has invalid enum value '{val}'; allowed: {allowed}"
                )

if validation_errors:
    for err in validation_errors:
        msg = f"event_type={event_type} — {err}"
        _log_warn(msg)
        if mode == "enforce":
            print(f"log-event: validation error: {msg}", file=sys.stderr)

    if mode == "enforce":
        sys.exit(2)
    # warn mode: fall through and append anyway

# --- Append to task-history.jsonl ---
os.makedirs(os.path.dirname(hist_path), exist_ok=True)
try:
    with open(hist_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(event) + "\n")
except OSError as exc:
    _log_warn(f"failed to write event to {hist_path}: {exc}")
    print(f"log-event: failed to write: {exc}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
