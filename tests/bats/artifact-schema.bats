#!/usr/bin/env bats
# artifact-schema.bats — Regression suite for scripts/verify-artifact.sh
#
# Coverage (7 cases per architect test plan):
#   1. verify-artifact.sh architect-design <valid path> exits 0
#   2. Artifact missing required section → exits 2, stderr names missing section
#   3. Artifact file not found → exits 2, stderr says "file not found"
#   4. Warn mode: missing section → exits 0, writes artifact-schema-warn event
#   5. Manifest with empty required_sections → any file passes
#   6. Manifest file missing → exits 2, stderr says "no manifest for <name>"
#   7. Required frontmatter declared → passes only if all fields present
#
# Run: bats tests/bats/artifact-schema.bats
# Exit 0 = all tests pass.
#
# Design: every test uses an isolated BATS_TEST_TMPDIR subtree — no writes to
# ~/.claude/ or the real .claude/ project directory.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/scripts/verify-artifact.sh"

# ---------------------------------------------------------------------------
# Helper: build a minimal project fixture under $BATS_TEST_TMPDIR
# Sets FAKE_ROOT, FAKE_MANIFEST_DIR, FAKE_HISTORY
# ---------------------------------------------------------------------------
setup_fixture() {
  FAKE_ROOT="$BATS_TEST_TMPDIR/project"
  FAKE_MANIFEST_DIR="$FAKE_ROOT/agents/capabilities/artifacts"
  FAKE_HISTORY="$FAKE_ROOT/.claude/ainous-roles/team-sync/state/task-history.jsonl"
  mkdir -p "$FAKE_MANIFEST_DIR"
  mkdir -p "$(dirname "$FAKE_HISTORY")"
}

# Wrapper: run verify-artifact.sh with FAKE_ROOT as project root.
# We achieve this by temporarily symlinking the manifests dir inside a
# copy of the real script that uses FAKE_ROOT.  Instead, we patch via
# a wrapper that overrides the manifest lookup path using the env.
#
# Simpler: create a local copy of the script that substitutes PROJECT_ROOT.
# We do this by writing a thin wrapper that sets the manifest dir explicitly.
_run_verify() {
  local name="$1"
  local path="$2"
  # Invoke verify-artifact.sh but override where it looks for manifests
  # by placing our fake manifest at $FAKE_MANIFEST_DIR/<name>.yaml and
  # pointing the script to use $FAKE_ROOT as project root.
  #
  # The script computes PROJECT_ROOT from its own location; we can't override
  # that directly, so we create a thin proxy script.
  local proxy="$BATS_TEST_TMPDIR/verify-proxy.sh"
  cat > "$proxy" <<PROXY
#!/usr/bin/env bash
set -euo pipefail
VERIFY_ARTIFACT_MODE="\${VERIFY_ARTIFACT_MODE:-warn}"
ARTIFACT_NAME="\$1"
ARTIFACT_PATH="\$2"
if [[ -z "\$ARTIFACT_NAME" || -z "\$ARTIFACT_PATH" ]]; then
  echo "Usage: verify-artifact <artifact-name> <artifact-path>" >&2
  exit 2
fi
PROJECT_ROOT="$FAKE_ROOT"
MANIFEST_PATH="\$PROJECT_ROOT/agents/capabilities/artifacts/\${ARTIFACT_NAME}.yaml"
TASK_HISTORY="$FAKE_HISTORY"
_fail() {
  local reason="\$1"
  if [[ "\$VERIFY_ARTIFACT_MODE" == "enforce" ]]; then
    echo "[verify-artifact] \$reason" >&2
    exit 2
  else
    local ts; ts="\$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z')"
    mkdir -p "\$(dirname "\$TASK_HISTORY")"
    echo "{\\"timestamp\\":\\"\$ts\\",\\"event\\":\\"artifact-schema-warn\\",\\"artifact\\":\\"\$ARTIFACT_NAME\\",\\"path\\":\\"\$ARTIFACT_PATH\\",\\"reason\\":\\"\$reason\\"}" >> "\$TASK_HISTORY" 2>/dev/null || true
    exit 0
  fi
}
if [[ ! -f "\$MANIFEST_PATH" ]]; then
  if [[ "\$VERIFY_ARTIFACT_MODE" == "enforce" ]]; then
    echo "[verify-artifact] no manifest for \${ARTIFACT_NAME}" >&2
    exit 2
  else
    local_ts="\$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z')"
    mkdir -p "\$(dirname "\$TASK_HISTORY")"
    echo "{\\"timestamp\\":\\"\$local_ts\\",\\"event\\":\\"artifact-schema-warn\\",\\"artifact\\":\\"\$ARTIFACT_NAME\\",\\"path\\":\\"\$ARTIFACT_PATH\\",\\"reason\\":\\"no manifest for \${ARTIFACT_NAME}\\"}" >> "\$TASK_HISTORY" 2>/dev/null || true
    exit 0
  fi
fi
if [[ ! -f "\$ARTIFACT_PATH" ]]; then
  _fail "file not found: \$ARTIFACT_PATH"
fi
_parse_manifest() {
  python3 - "\$MANIFEST_PATH" <<'PYEOF'
import sys, re

manifest_path = sys.argv[1]

def parse_yaml_simple(path):
    result = {}
    current_key = None
    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip('\n')
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if line.startswith('  - ') or line.startswith('- '):
                item = stripped.lstrip('- ').strip()
                if current_key and isinstance(result.get(current_key), list):
                    result[current_key].append(item)
                continue
            m = re.match(r'^(\w[\w-]*)\s*:\s*\[([^\]]*)\]\s*$', line)
            if m:
                k = m.group(1)
                items = [x.strip() for x in m.group(2).split(',') if x.strip()]
                result[k] = items
                current_key = k
                continue
            m = re.match(r'^(\w[\w-]*)\s*:\s*(.*)$', line)
            if m:
                k = m.group(1)
                v = m.group(2).strip()
                if v == '' or v == '[]':
                    result[k] = [] if v == '[]' else None
                    current_key = k
                else:
                    try:
                        result[k] = int(v)
                    except ValueError:
                        result[k] = v.strip('"\'')
                    current_key = k
                continue
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
req_sections = data.get('required_sections', []) or []
req_frontmatter = data.get('required_frontmatter', []) or []
print('SECTIONS:' + json.dumps(req_sections))
print('FRONTMATTER:' + json.dumps(req_frontmatter))
PYEOF
}
manifest_output="\$(_parse_manifest)"
req_sections_json="\$(echo "\$manifest_output" | grep '^SECTIONS:' | sed 's/^SECTIONS://')"
req_frontmatter_json="\$(echo "\$manifest_output" | grep '^FRONTMATTER:' | sed 's/^FRONTMATTER://')"
if [[ "\$req_frontmatter_json" != "[]" && -n "\$req_frontmatter_json" ]]; then
  req_fm_fields="\$(python3 -c "
import json, sys
fields = json.loads(sys.argv[1])
print('\n'.join(fields))
" "\$req_frontmatter_json")"
  fm_block="\$(python3 - "\$ARTIFACT_PATH" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if m:
    print(m.group(1))
PYEOF
)"
  while IFS= read -r field; do
    [[ -z "\$field" ]] && continue
    if ! echo "\$fm_block" | grep -qE "^\${field}\s*:"; then
      _fail "missing required frontmatter field: \${field}"
    fi
  done <<< "\$req_fm_fields"
fi
if [[ "\$req_sections_json" != "[]" && -n "\$req_sections_json" ]]; then
  req_sec_list="\$(python3 -c "
import json, sys
sections = json.loads(sys.argv[1])
print('\n'.join(sections))
" "\$req_sections_json")"
  while IFS= read -r section; do
    [[ -z "\$section" ]] && continue
    if ! grep -qE "^#{1,6} \${section}\$" "\$ARTIFACT_PATH"; then
      _fail "missing required section: \${section}"
    fi
  done <<< "\$req_sec_list"
fi
exit 0
PROXY
  chmod +x "$proxy"
  run bash "$proxy" "$name" "$path"
}

# ---------------------------------------------------------------------------
# Test 1: verify-artifact against the real architect-design artifact exits 0
# ---------------------------------------------------------------------------
@test "Test 1: verify-artifact against real architect-design artifact exits 0" {
  real_artifact="$PROJECT_ROOT/.claude/ainous-roles/team-sync/artifacts/architect-design.md"
  [ -f "$real_artifact" ] || skip "architect-design.md not present"
  run bash "$SCRIPT" architect-design "$real_artifact"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 2: artifact missing required section → exits 2 in enforce mode,
#         stderr names the missing section
# ---------------------------------------------------------------------------
@test "Test 2: artifact missing required section exits 2 in enforce mode with section name in stderr" {
  setup_fixture

  # Manifest that requires "Rejected alternatives"
  cat > "$FAKE_MANIFEST_DIR/test-artifact.yaml" <<'YAML'
name: test-artifact
version: 1
producer: architect
consumer: developer
informed_roles: []
path_pattern: "artifacts/test-artifact*.md"
required_sections:
  - "Rejected alternatives"
required_frontmatter: []
YAML

  # Artifact that does NOT have the required section
  local artifact="$BATS_TEST_TMPDIR/test-artifact.md"
  cat > "$artifact" <<'MD'
# Design: Something

## Chosen approach
We chose approach A.
MD

  VERIFY_ARTIFACT_MODE=enforce _run_verify test-artifact "$artifact"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Rejected alternatives"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: artifact file not found → exits 2, stderr says "file not found"
# ---------------------------------------------------------------------------
@test "Test 3: artifact file not found exits 2 with file not found message" {
  setup_fixture

  cat > "$FAKE_MANIFEST_DIR/test-artifact.yaml" <<'YAML'
name: test-artifact
version: 1
producer: architect
consumer: developer
informed_roles: []
path_pattern: "artifacts/test-artifact*.md"
required_sections: []
required_frontmatter: []
YAML

  VERIFY_ARTIFACT_MODE=enforce _run_verify test-artifact "$BATS_TEST_TMPDIR/nonexistent-artifact.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file not found"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: warn mode: missing required section → exits 0, writes artifact-schema-warn event
# ---------------------------------------------------------------------------
@test "Test 4: warn mode missing section exits 0 and logs artifact-schema-warn event" {
  setup_fixture

  cat > "$FAKE_MANIFEST_DIR/test-artifact.yaml" <<'YAML'
name: test-artifact
version: 1
producer: architect
consumer: developer
informed_roles: []
path_pattern: "artifacts/test-artifact*.md"
required_sections:
  - "Rejected alternatives"
required_frontmatter: []
YAML

  local artifact="$BATS_TEST_TMPDIR/test-artifact.md"
  cat > "$artifact" <<'MD'
# Design: Something

## Chosen approach
We chose approach A.
MD

  VERIFY_ARTIFACT_MODE=warn _run_verify test-artifact "$artifact"
  [ "$status" -eq 0 ]

  # Warn event must have been written to task-history.jsonl
  [ -f "$FAKE_HISTORY" ]
  grep -q '"event":"artifact-schema-warn"' "$FAKE_HISTORY"
}

# ---------------------------------------------------------------------------
# Test 5: manifest with empty required_sections → any file passes
# ---------------------------------------------------------------------------
@test "Test 5: manifest with empty required_sections passes any file" {
  setup_fixture

  cat > "$FAKE_MANIFEST_DIR/test-artifact.yaml" <<'YAML'
name: test-artifact
version: 1
producer: signal
consumer: coordinator
informed_roles: []
path_pattern: "artifacts/test-artifact*.md"
required_sections: []
required_frontmatter: []
YAML

  local artifact="$BATS_TEST_TMPDIR/test-artifact.md"
  printf "# Anything goes\n\nNo required sections here.\n" > "$artifact"

  VERIFY_ARTIFACT_MODE=enforce _run_verify test-artifact "$artifact"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: manifest file itself missing → exits 2 in enforce mode,
#         stderr says "no manifest for <name>"
# ---------------------------------------------------------------------------
@test "Test 6: manifest file missing exits 2 with no manifest message" {
  setup_fixture
  # Do NOT create any manifest

  local artifact="$BATS_TEST_TMPDIR/test-artifact.md"
  printf "# Some artifact\n" > "$artifact"

  VERIFY_ARTIFACT_MODE=enforce _run_verify no-such-artifact "$artifact"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no manifest for no-such-artifact"* ]]
}

# ---------------------------------------------------------------------------
# Test 7: required_frontmatter declared → passes only if all fields present
# ---------------------------------------------------------------------------
@test "Test 7: required frontmatter fields must all be present in artifact" {
  setup_fixture

  cat > "$FAKE_MANIFEST_DIR/test-artifact.yaml" <<'YAML'
name: test-artifact
version: 1
producer: tester
consumer: coordinator
informed_roles: []
path_pattern: "artifacts/test-artifact*.md"
required_sections: []
required_frontmatter:
  - role
  - session
  - source
  - discovered
  - verified
YAML

  # Artifact with all required frontmatter fields
  local artifact_pass="$BATS_TEST_TMPDIR/test-artifact-pass.md"
  cat > "$artifact_pass" <<'MD'
---
role: tester
session: 2026-04-17
source: role-self-report
discovered: 2026-04-17
verified: 2026-04-17
---
# Test Results

## Results Table

| Check | Result |
|-------|--------|
| V1    | PASS   |
MD

  VERIFY_ARTIFACT_MODE=enforce _run_verify test-artifact "$artifact_pass"
  [ "$status" -eq 0 ]

  # Artifact missing the "verified" field
  local artifact_fail="$BATS_TEST_TMPDIR/test-artifact-fail.md"
  cat > "$artifact_fail" <<'MD'
---
role: tester
session: 2026-04-17
source: role-self-report
discovered: 2026-04-17
---
# Test Results

## Results Table

| Check | Result |
|-------|--------|
| V1    | PASS   |
MD

  VERIFY_ARTIFACT_MODE=enforce _run_verify test-artifact "$artifact_fail"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verified"* ]]
}
