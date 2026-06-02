#!/usr/bin/env bash
# verify-artifact — validate an artifact file against its named manifest
#
# Usage: verify-artifact <artifact-name> <artifact-path>
# Exit 0: pass (or warn-mode failure — see VERIFY_ARTIFACT_MODE)
# Exit 2: fail (stderr has reason)
#
# Env:
#   VERIFY_ARTIFACT_MODE=warn (default) | enforce
#     warn:    failures log artifact-schema-warn event and exit 0
#     enforce: failures write reason to stderr and exit 2

set -euo pipefail

# ---------------------------------------------------------------------------
# Mode toggle — change to "enforce" to enable hard failures
# ---------------------------------------------------------------------------
VERIFY_ARTIFACT_MODE="${VERIFY_ARTIFACT_MODE:-warn}"

ARTIFACT_NAME="${1:-}"
ARTIFACT_PATH="${2:-}"

if [[ -z "$ARTIFACT_NAME" || -z "$ARTIFACT_PATH" ]]; then
  echo "Usage: verify-artifact <artifact-name> <artifact-path>" >&2
  exit 2
fi

# Locate project root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFEST_PATH="$PROJECT_ROOT/agents/capabilities/artifacts/${ARTIFACT_NAME}.yaml"
TASK_HISTORY="$PROJECT_ROOT/.claude/ainous-roles/team-sync/state/task-history.jsonl"

# ---------------------------------------------------------------------------
# _fail: emit warn event or hard exit depending on mode
# ---------------------------------------------------------------------------
_fail() {
  local reason="$1"
  if [[ "$VERIFY_ARTIFACT_MODE" == "enforce" ]]; then
    echo "[verify-artifact] $reason" >&2
    exit 2
  else
    # warn mode: log event and exit 0
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
    mkdir -p "$(dirname "$TASK_HISTORY")"
    echo "{\"timestamp\":\"$ts\",\"event\":\"artifact-schema-warn\",\"artifact\":\"$ARTIFACT_NAME\",\"path\":\"$ARTIFACT_PATH\",\"reason\":\"$reason\"}" >> "$TASK_HISTORY" 2>/dev/null || true
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# 1. Check manifest exists
# ---------------------------------------------------------------------------
if [[ ! -f "$MANIFEST_PATH" ]]; then
  if [[ "$VERIFY_ARTIFACT_MODE" == "enforce" ]]; then
    echo "[verify-artifact] no manifest for ${ARTIFACT_NAME}" >&2
    exit 2
  else
    local_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
    mkdir -p "$(dirname "$TASK_HISTORY")"
    echo "{\"timestamp\":\"$local_ts\",\"event\":\"artifact-schema-warn\",\"artifact\":\"$ARTIFACT_NAME\",\"path\":\"$ARTIFACT_PATH\",\"reason\":\"no manifest for ${ARTIFACT_NAME}\"}" >> "$TASK_HISTORY" 2>/dev/null || true
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 2. Check artifact file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$ARTIFACT_PATH" ]]; then
  _fail "file not found: $ARTIFACT_PATH"
fi

# ---------------------------------------------------------------------------
# 3. Parse manifest using python stdlib (yaml is NOT stdlib; use line parser)
#    Tries python yaml first; falls back to line regex parser.
# ---------------------------------------------------------------------------
_parse_manifest() {
  python3 - "$MANIFEST_PATH" <<'PYEOF'
import sys, re

manifest_path = sys.argv[1]

def parse_yaml_simple(path):
    """Minimal flat YAML parser sufficient for our manifest format.
    Handles: scalar fields, list fields (- item), nested maps (key:).
    Does NOT handle anchors, multi-line strings, or flow syntax beyond simple lists.
    """
    result = {}
    current_key = None
    in_list = False

    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip('\n')
            # Skip empty lines
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue

            # List item under current key
            if line.startswith('  - ') or line.startswith('- '):
                item = stripped.lstrip('- ').strip()
                # Remove inline brackets if accidentally present (shouldn't be, but safe)
                if current_key and isinstance(result.get(current_key), list):
                    result[current_key].append(item)
                continue

            # Inline list: key: [a, b, c]
            m = re.match(r'^(\w[\w-]*)\s*:\s*\[([^\]]*)\]\s*$', line)
            if m:
                k = m.group(1)
                items = [x.strip() for x in m.group(2).split(',') if x.strip()]
                result[k] = items
                current_key = k
                in_list = False
                continue

            # Scalar: key: value  OR  key: (empty, starts list)
            m = re.match(r'^(\w[\w-]*)\s*:\s*(.*)$', line)
            if m:
                k = m.group(1)
                v = m.group(2).strip()
                if v == '' or v == '[]':
                    result[k] = []
                    current_key = k
                    in_list = True
                else:
                    # Try to cast numbers
                    try:
                        result[k] = int(v)
                    except ValueError:
                        result[k] = v.strip('"\'')
                    current_key = k
                    in_list = False
                continue

    # Normalise: None lists → []
    for k, v in result.items():
        if v is None:
            result[k] = []

    return result

try:
    import yaml
    with open(manifest_path) as f:
        data = yaml.safe_load(f)
    if data is None:
        data = {}
except ImportError:
    data = parse_yaml_simple(manifest_path)

import json

# Emit required_sections and required_frontmatter as JSON lines
req_sections = data.get('required_sections', []) or []
req_frontmatter = data.get('required_frontmatter', []) or []

print('SECTIONS:' + json.dumps(req_sections))
print('FRONTMATTER:' + json.dumps(req_frontmatter))
PYEOF
}

if ! manifest_output="$(_parse_manifest)"; then
  _fail "failed to parse manifest for ${ARTIFACT_NAME}"
fi

req_sections_json="$(echo "$manifest_output" | grep '^SECTIONS:' | sed 's/^SECTIONS://')"
req_frontmatter_json="$(echo "$manifest_output" | grep '^FRONTMATTER:' | sed 's/^FRONTMATTER://')"

# ---------------------------------------------------------------------------
# 4. Check required_frontmatter — parse the first --- ... --- block
# ---------------------------------------------------------------------------
if [[ "$req_frontmatter_json" != "[]" && -n "$req_frontmatter_json" ]]; then
  # Extract required fields as newline-separated list via python
  req_fm_fields="$(python3 -c "
import json, sys
fields = json.loads(sys.argv[1])
print('\n'.join(fields))
" "$req_frontmatter_json")"

  # Parse frontmatter block from artifact (between first --- pair)
  fm_block="$(python3 - "$ARTIFACT_PATH" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Match first --- ... --- block at start of file
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if m:
    print(m.group(1))
PYEOF
)"

  while IFS= read -r field; do
    [[ -z "$field" ]] && continue
    if ! echo "$fm_block" | grep -qE "^${field}\s*:"; then
      _fail "missing required frontmatter field: ${field}"
    fi
  done <<< "$req_fm_fields"
fi

# ---------------------------------------------------------------------------
# 5. Check required_sections — grep for ^#+ <section>$ (any heading level)
# ---------------------------------------------------------------------------
if [[ "$req_sections_json" != "[]" && -n "$req_sections_json" ]]; then
  req_sec_list="$(python3 -c "
import json, sys
sections = json.loads(sys.argv[1])
print('\n'.join(sections))
" "$req_sections_json")"

  while IFS= read -r section; do
    [[ -z "$section" ]] && continue
    # Match any heading level: # Title, ## Title, ### Title, etc.
    if ! grep -qE "^#{1,6} ${section}$" "$ARTIFACT_PATH"; then
      _fail "missing required section: ${section}"
    fi
  done <<< "$req_sec_list"
fi

exit 0
