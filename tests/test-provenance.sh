#!/usr/bin/env bash
# test-provenance.sh — Test suite for the signed-provenance layer (v1)
#
# Tests the _validate_provenance() function as integrated into authority-enforce.sh.
# Each test invokes authority-enforce.sh directly with synthetic tool inputs.
#
# Prerequisites:
#   - python3 available in PATH
#   - The role 'developer' must have a growth.json with trust != intern, OR
#     we bypass trust by pointing to a temp growth dir
#
# Run: bash tests/test-provenance.sh
# Exit 0 = all tests pass; exit 1 = at least one test failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"
TESTS_PASS=0
TESTS_FAIL=0

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

# Set up a temporary environment for each test run
# We need:
#   - A session role marker pointing to a known role
#   - A growth.json with trust level >= junior (so trust check passes)
#   - A decisions.md (empty — so no authority override)
#   - A task-history.jsonl (optional — no longer required for provenance tests)
#   - A project baselines.json that allows writes to ainous-roles paths

TMPDIR_BASE=$(mktemp -d /tmp/test-provenance.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

# Create temp home dir structure
FAKE_HOME="$TMPDIR_BASE/home"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/researcher"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/authority"

# Growth.json with senior trust so the role can write
cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
cat > "$FAKE_HOME/.claude/ainous-roles/researcher/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF

# Empty decisions.md
touch "$FAKE_HOME/.claude/ainous-roles/authority/decisions.md"

# Session role marker
echo "developer" > "$FAKE_HOME/.claude/.session-role"

# Create a fake project directory
FAKE_PROJECT="$TMPDIR_BASE/project"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"

# baselines.json: allow developer to write to developer/ paths
cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["journal.md","playbook.md","learnings.jsonl","team-knowledge.md","user-corrections.md"]}
EOF

# Phase 2 (v5.3.0): taint nonce setup for _validate_taint_field fail-closed requirement.
# All provenance surface writes now require CLAUDE_SESSION_ID + a readable nonce.
FAKE_SESSION_ID="prov-test-session-abc123"
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"
_HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" \
    "$FAKE_SESSION_ID" 2>/dev/null)
_NONCE_BYTES="aabbccdd1122334455667788aabbccdd1122334455667788aabbccdd11223344"
_NONCE_FILE="$FAKE_NONCE_DIR/${_HASHED_SID}.nonce"
printf '%s' "$_NONCE_BYTES" > "$_NONCE_FILE"
chmod 600 "$_NONCE_FILE"

# Target file paths for tests (use the fake project structure)
TARGET_PLAYBOOK="$FAKE_HOME/.claude/ainous-roles/developer/playbook.md"
TARGET_JOURNAL="$FAKE_HOME/.claude/ainous-roles/developer/journal.md"
TARGET_LEARNINGS="$FAKE_HOME/.claude/ainous-roles/developer/learnings.jsonl"
TARGET_TK="$FAKE_HOME/.claude/ainous-roles/team-knowledge.md"
TARGET_UC="$FAKE_HOME/.claude/ainous-roles/user-corrections.md"

# Helper: run the enforce hook with synthetic Write tool input
# Always runs from FAKE_PROJECT so baselines.json is found.
# Returns exit code of the hook.
_run_hook() {
    local file_path="$1"
    local content="$2"
    local role="${3:-developer}"

    # Write session role marker
    echo "$role" > "$FAKE_HOME/.claude/.session-role"

    # Build JSON input — inject session_id into payload (v5.6.2 belt+suspenders)
    local json_input json_with_sid
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':sys.argv[2]}))" \
        "$file_path" "$content" 2>/dev/null)
    json_with_sid=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['session_id']=sys.argv[2]; print(json.dumps(d))" \
        "$json_input" "$FAKE_SESSION_ID" 2>/dev/null)

    # Run hook from FAKE_PROJECT so baselines.json is found
    # Pass CLAUDE_SESSION_ID (env) AND session_id in stdin JSON (v5.6.2 dual-source)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        bash "$HOOK" <<< "$json_with_sid" 2>/dev/null
    )
    return $?
}

# Helper: run hook and capture stderr
_run_hook_stderr() {
    local file_path="$1"
    local content="$2"
    local role="${3:-developer}"

    echo "$role" > "$FAKE_HOME/.claude/.session-role"

    local json_input json_with_sid
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':sys.argv[2]}))" \
        "$file_path" "$content" 2>/dev/null)
    json_with_sid=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['session_id']=sys.argv[2]; print(json.dumps(d))" \
        "$json_input" "$FAKE_SESSION_ID" 2>/dev/null)

    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Write" \
        CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
        bash "$HOOK" <<< "$json_with_sid" 2>&1
    )
    return $?
}

# Test result reporter
_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Valid provenance for developer role (used as baseline in multiple tests)
# ---------------------------------------------------------------------------
VALID_MD_CONTENT='---
role: developer
session: 2026-04-17T10:00:00Z
source: observed
discovered: 2026-04-17
verified: null
---
# Playbook content here
'

VALID_JSONL_CONTENT='{"role":"developer","session":"2026-04-17T10:00:00Z","source":"observed","discovered":"2026-04-17","verified":null,"key":"test-entry","insight":"test insight"}'

# ---------------------------------------------------------------------------
# TEST 1: Valid provenance → hook allows (exit 0)
# ---------------------------------------------------------------------------
_run_hook "$TARGET_PLAYBOOK" "$VALID_MD_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC1: Valid md provenance passes (exit 0)"
else
    _fail "TC1: Valid md provenance should pass" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 2: Missing 'source' field → reject (exit 2)
# ---------------------------------------------------------------------------
MISSING_SOURCE='---
role: developer
session: 2026-04-17T10:00:00Z
discovered: 2026-04-17
verified: null
---
# Content
'
_run_hook "$TARGET_PLAYBOOK" "$MISSING_SOURCE" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC2: Missing 'source' field → rejected (exit 2)"
else
    _fail "TC2: Missing 'source' field should be rejected" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 3: Invalid source_type value → reject (exit 2)
# ---------------------------------------------------------------------------
INVALID_SOURCE='---
role: developer
session: 2026-04-17T10:00:00Z
source: totally-made-up-source
discovered: 2026-04-17
verified: null
---
# Content
'
_run_hook_stderr "$TARGET_PLAYBOOK" "$INVALID_SOURCE" "developer" > /tmp/tc3_out.txt 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC3: Invalid source_type → rejected (exit 2)"
else
    _fail "TC3: Invalid source_type should be rejected" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 4: Role mismatch — provenance role ≠ session role marker → reject (exit 2)
# ---------------------------------------------------------------------------
WRONG_ROLE_CONTENT='---
role: consolidator
session: 2026-04-17T10:00:00Z
source: observed
discovered: 2026-04-17
verified: null
---
# Content written by developer but claiming to be consolidator
'
# Session marker says "developer", but provenance says "consolidator"
_run_hook "$TARGET_PLAYBOOK" "$WRONG_ROLE_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC4: Role mismatch in provenance → rejected (exit 2)"
else
    _fail "TC4: Role mismatch should be rejected" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 5: source=user-confirmed → rejected by enum (retired source type)
# ---------------------------------------------------------------------------
USER_CONFIRMED_CONTENT='---
role: developer
session: 2026-04-17T10:00:00Z
source: user-confirmed
discovered: 2026-04-17
verified: 2026-04-17
---
# Content claiming user confirmed this
'
_run_hook "$TARGET_UC" "$USER_CONFIRMED_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC5: source=user-confirmed rejected by enum (exit 2)"
else
    _fail "TC5: source=user-confirmed should be rejected by enum" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 7: Valid JSONL provenance → allow (exit 0)
# ---------------------------------------------------------------------------
_run_hook "$TARGET_LEARNINGS" "$VALID_JSONL_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC7: Valid jsonl provenance passes (exit 0)"
else
    _fail "TC7: Valid jsonl provenance should pass" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 8: JSONL line missing 'source' field → reject (exit 2)
# ---------------------------------------------------------------------------
MISSING_SOURCE_JSONL='{"role":"developer","session":"2026-04-17T10:00:00Z","discovered":"2026-04-17","verified":null,"key":"x"}'
_run_hook "$TARGET_LEARNINGS" "$MISSING_SOURCE_JSONL" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC8: JSONL missing source field → rejected (exit 2)"
else
    _fail "TC8: JSONL missing source should be rejected" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 9: Non-provenance surface → hook does not gate on provenance (exit 0)
# ---------------------------------------------------------------------------
# A write to a regular file (not a provenance surface) should pass through
# with no provenance check
NON_SURFACE_FILE="$FAKE_PROJECT/src/foo.py"
mkdir -p "$(dirname "$NON_SURFACE_FILE")"
# Use a separate setup — developer can write to src/
cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
# Add src/ to baselines
cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["journal.md","playbook.md","learnings.jsonl","team-knowledge.md","user-corrections.md","src/"]}
EOF
NON_SURFACE_CONTENT='def hello(): return "world"'
(
    cd "$FAKE_PROJECT"
    echo "developer" > "$FAKE_HOME/.claude/.session-role"
    json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':sys.argv[2]}))" \
        "$NON_SURFACE_FILE" "$NON_SURFACE_CONTENT" 2>/dev/null)
    json_with_sid=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['session_id']=sys.argv[2]; print(json.dumps(d))" \
        "$json_input" "$FAKE_SESSION_ID" 2>/dev/null)
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" bash "$HOOK" <<< "$json_with_sid" 2>/dev/null
    exit $?
)
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC9: Non-provenance surface write bypasses provenance check (exit 0)"
else
    _fail "TC9: Non-provenance surface should not require provenance" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# TEST 10-12: Migration script tests (use a self-contained temp directory tree)
# The migration script is run via a wrapper that sets up an isolated directory.
# ---------------------------------------------------------------------------

MIGRATE_TMP="$TMPDIR_BASE/migrate_test"
mkdir -p "$MIGRATE_TMP/scripts"
mkdir -p "$MIGRATE_TMP/.claude/ainous-roles/developer"
mkdir -p "$MIGRATE_TMP/.claude/ainous-roles/authority"

# Create a wrapper migration script that runs in the temp directory context
cat > "$MIGRATE_TMP/scripts/migrate-legacy-provenance.sh" <<MIGSCRIPT
#!/usr/bin/env bash
# Thin wrapper: override project paths to point at $MIGRATE_TMP
set -uo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
PROJECT_ROOT="\$(cd "\$SCRIPT_DIR/.." && pwd)"
GLOBAL_ROLES_DIR="\$PROJECT_ROOT/.claude/ainous-roles"

$(grep -v '^GLOBAL_ROLES_DIR\|^SCRIPT_DIR\|^PROJECT_ROOT' "$PROJECT_ROOT/scripts/migrate-legacy-provenance.sh" | grep -v '^#!/')
MIGSCRIPT
chmod +x "$MIGRATE_TMP/scripts/migrate-legacy-provenance.sh"

# Create a legacy journal.md without provenance
LEGACY_JOURNAL="$MIGRATE_TMP/.claude/ainous-roles/developer/journal.md"
cat > "$LEGACY_JOURNAL" <<'EOF'
## 2026-01-01 — Old session
This is an old entry without provenance.
EOF

# ---------------------------------------------------------------------------
# TEST 10: --dry-run does not modify the file
# ---------------------------------------------------------------------------
ORIGINAL_CONTENT=$(cat "$LEGACY_JOURNAL")
bash "$MIGRATE_TMP/scripts/migrate-legacy-provenance.sh" --dry-run > /dev/null 2>&1
DRY_EXIT=$?
AFTER_CONTENT=$(cat "$LEGACY_JOURNAL")

if [ "$ORIGINAL_CONTENT" = "$AFTER_CONTENT" ] && [ $DRY_EXIT -eq 0 ]; then
    _pass "TC10: Migration --dry-run: legacy file not modified (exit 0)"
else
    if [ $DRY_EXIT -ne 0 ]; then
        _fail "TC10: Migration --dry-run exit code" "Got exit $DRY_EXIT"
    else
        _fail "TC10: Migration --dry-run should not modify file" "File was modified"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 11: --execute tags legacy file with legacy-unverified
# ---------------------------------------------------------------------------
bash "$MIGRATE_TMP/scripts/migrate-legacy-provenance.sh" --execute > /dev/null 2>&1
EXEC_EXIT=$?
MIGRATED_CONTENT=$(cat "$LEGACY_JOURNAL" 2>/dev/null || true)

if [ $EXEC_EXIT -eq 0 ] && echo "$MIGRATED_CONTENT" | grep -q 'source: legacy-unverified'; then
    _pass "TC11: Migration --execute tags legacy file as legacy-unverified (exit 0)"
else
    if [ $EXEC_EXIT -ne 0 ]; then
        _fail "TC11: Migration --execute exit code" "Got exit $EXEC_EXIT"
    else
        _fail "TC11: Migrated file should contain 'source: legacy-unverified'" \
            "Content: $(echo "$MIGRATED_CONTENT" | head -10)"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 12: Migration is idempotent — running --execute twice doesn't double-tag
# ---------------------------------------------------------------------------
bash "$MIGRATE_TMP/scripts/migrate-legacy-provenance.sh" --execute > /dev/null 2>&1
SECOND_RUN_EXIT=$?
CONTENT_AFTER_SECOND=$(cat "$LEGACY_JOURNAL" 2>/dev/null || true)
FRONTMATTER_COUNT=$(echo "$CONTENT_AFTER_SECOND" | grep -c '^---$' || true)

# Should still have exactly 2 --- markers (opening and closing frontmatter)
if [ $SECOND_RUN_EXIT -eq 0 ] && [ "$FRONTMATTER_COUNT" -le 2 ]; then
    _pass "TC12: Migration --execute is idempotent (exit 0, no double-tagging)"
else
    if [ $SECOND_RUN_EXIT -ne 0 ]; then
        _fail "TC12: Second migration run exit code" "Got exit $SECOND_RUN_EXIT"
    else
        _fail "TC12: Migration should be idempotent" "Found $FRONTMATTER_COUNT '---' markers"
    fi
fi

# ---------------------------------------------------------------------------
# TEST M3-A through M3-G: M-3 artifact provenance parity (v5.2.0)
# Covers all 7 artifacts declared in agents/capabilities/artifacts/index.yaml.
# ---------------------------------------------------------------------------

# Restore baselines to include provenance surfaces and declared artifact basenames.
# Layer-1 matches on fnmatch(basename, pattern) — use glob patterns for artifact filenames.
cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["journal.md","playbook.md","learnings.jsonl","team-knowledge.md","user-corrections.md","researcher-findings*.md","security-findings*.md","architect-design*.md","code-quality-findings*.md","tester-plan*.md","tester-results*.md","signal-findings*.md","semantic-supply-chain-*.md"]}
EOF

mkdir -p "$FAKE_HOME/.claude/ainous-roles/team-sync/artifacts"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/artifacts"

# Valid and missing-provenance content templates
_VALID_ARTIFACT_CONTENT() {
    local role="$1"
    cat <<EOF
---
role: $role
session: 2026-04-18
source: observed
discovered: 2026-04-18
verified: null
---
# Artifact content
EOF
}

NO_PROV_CONTENT='# Artifact content with no frontmatter at all'

# For each declared artifact, test:
#   (1) write without provenance → exit 2
#   (2) write with valid provenance → exit 0
_test_artifact() {
    local label="$1"   # e.g. "researcher-findings"
    local filename="$2" # actual filename to use
    local role="$3"     # writing role

    local ARTIFACT_PATH="$FAKE_HOME/.claude/ainous-roles/team-sync/artifacts/$filename"
    mkdir -p "$(dirname "$ARTIFACT_PATH")"

    # (1) No provenance → blocked
    _run_hook "$ARTIFACT_PATH" "$NO_PROV_CONTENT" "$role"
    local ex=$?
    if [ $ex -eq 2 ]; then
        _pass "TC-M3-${label}-noprov: artifact write without provenance → blocked (exit 2)"
    else
        _fail "TC-M3-${label}-noprov: artifact write without provenance should be blocked" "Got exit $ex"
    fi

    # (2) Valid provenance → allowed
    local valid_content
    valid_content=$(_VALID_ARTIFACT_CONTENT "$role")
    _run_hook "$ARTIFACT_PATH" "$valid_content" "$role"
    ex=$?
    if [ $ex -eq 0 ]; then
        _pass "TC-M3-${label}-valid: artifact write with valid provenance → allowed (exit 0)"
    else
        _fail "TC-M3-${label}-valid: artifact write with valid provenance should be allowed" "Got exit $ex"
    fi
}

_test_artifact "researcher-findings" "researcher-findings.md"   "developer"
_test_artifact "security-findings"   "security-findings.md"     "developer"
_test_artifact "architect-design"    "architect-design.md"      "developer"
_test_artifact "code-quality"        "code-quality-findings.md" "developer"
_test_artifact "tester-plan"         "tester-plan.md"           "developer"
_test_artifact "tester-results"      "tester-results.md"        "developer"
_test_artifact "signal-findings"     "signal-findings.md"       "developer"

# ---------------------------------------------------------------------------
# TEST M3-NC: Non-declared artifact in same directory → ungated (exit 0)
# semantic-supply-chain-critic.md is NOT in the registry index — must pass through.
# ---------------------------------------------------------------------------
NON_DECLARED_PATH="$FAKE_HOME/.claude/ainous-roles/team-sync/artifacts/semantic-supply-chain-critic.md"
mkdir -p "$(dirname "$NON_DECLARED_PATH")"
echo "developer" > "$FAKE_HOME/.claude/.session-role"
json_input=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':sys.argv[2]}))" \
    "$NON_DECLARED_PATH" "$NO_PROV_CONTENT" 2>/dev/null)
json_with_sid=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['session_id']=sys.argv[2]; print(json.dumps(d))" \
    "$json_input" "$FAKE_SESSION_ID" 2>/dev/null)
(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" bash "$HOOK" <<< "$json_with_sid" 2>/dev/null
    exit $?
)
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-M3-NC: non-declared artifact (semantic-supply-chain-critic.md) ungated → passes (exit 0)"
else
    _fail "TC-M3-NC: non-declared artifact should not be provenance-gated" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Regression: existing surfaces still enforce (TC-REG-*)
# ---------------------------------------------------------------------------
_run_hook "$TARGET_PLAYBOOK" "$NO_PROV_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-REG-playbook: playbook still enforces provenance (exit 2)"
else
    _fail "TC-REG-playbook: playbook enforcement regressed" "Got exit $EXIT_CODE"
fi

_run_hook "$TARGET_TK" "$NO_PROV_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-REG-team-knowledge: team-knowledge.md still enforces provenance (exit 2)"
else
    _fail "TC-REG-team-knowledge: team-knowledge.md enforcement regressed" "Got exit $EXIT_CODE"
fi

_run_hook "$TARGET_JOURNAL" "$NO_PROV_CONTENT" "developer"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-REG-journal: journal.md still enforces provenance (exit 2)"
else
    _fail "TC-REG-journal: journal.md enforcement regressed" "Got exit $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# v5.8.1 Item 2: TASK_HISTORY_WRITE_DENY — TC-TH-1..3
# ---------------------------------------------------------------------------
TASK_HISTORY_PATH="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/task-history.jsonl"

# TC-TH-1: operator role + Write to task-history.jsonl → exit 2
echo "operator" > "$FAKE_HOME/.claude/.session-role"
cat > "$FAKE_HOME/.claude/ainous-roles/operator-growth.json" <<'OPGEOF'
{"trust":{"level":"operator"}}
OPGEOF
# operator role uses a special trust path; use the existing operator flow
TH_JSON=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':'forged-event'}))" \
    "$TASK_HISTORY_PATH" 2>/dev/null)
TH_EXIT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    bash "$HOOK" <<< "$TH_JSON" 2>/dev/null
    echo $?
)
if [ "${TH_EXIT}" -eq 2 ]; then
    _pass "TC-TH-1: operator role + Write to task-history.jsonl → exit 2 (TASK_HISTORY_WRITE_DENY)"
else
    _fail "TC-TH-1: expected exit 2, got ${TH_EXIT}" "operator should not be able to write task-history.jsonl via tool surface"
fi
echo "developer" > "$FAKE_HOME/.claude/.session-role"

# TC-TH-2: developer role + Write to task-history.jsonl → exit 2
TH_DEV_JSON=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':'forged-spawn-event'}))" \
    "$TASK_HISTORY_PATH" 2>/dev/null)
TH_DEV_EXIT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    bash "$HOOK" <<< "$TH_DEV_JSON" 2>/dev/null
    echo $?
)
if [ "${TH_DEV_EXIT}" -eq 2 ]; then
    _pass "TC-TH-2: developer role + Write to task-history.jsonl → exit 2 (TASK_HISTORY_WRITE_DENY)"
else
    _fail "TC-TH-2: expected exit 2, got ${TH_DEV_EXIT}" "developer should not be able to write task-history.jsonl via tool surface"
fi

# TC-TH-3: developer role + Write to a sibling file (NOT task-history.jsonl) → allowed (not denied)
# Regression: ensure the pattern only blocks task-history.jsonl, not all JSONL in state/
SIBLING_JSONL="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/other-events.jsonl"
SIBLING_JSON=$(python3 -c "import json,sys; print(json.dumps({'file_path':sys.argv[1],'content':'data'}))" \
    "$SIBLING_JSONL" 2>/dev/null)
SIBLING_EXIT=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    bash "$HOOK" <<< "$SIBLING_JSON" 2>/dev/null
    echo $?
)
# This will be blocked by baseline/trust anyway (not a provenance surface, not in developer baseline)
# The key check: it should NOT be blocked specifically by TASK_HISTORY_WRITE_DENY
SIBLING_STDERR=$(
    cd "$FAKE_PROJECT"
    HOME="$FAKE_HOME" TOOL_USE_NAME="Write" CLAUDE_SESSION_ID="$FAKE_SESSION_ID" \
    bash "$HOOK" <<< "$SIBLING_JSON" 2>&1
)
if echo "$SIBLING_STDERR" | grep -q "TASK_HISTORY_WRITE_DENY"; then
    _fail "TC-TH-3: sibling JSONL file incorrectly blocked by TASK_HISTORY_WRITE_DENY" "pattern too broad"
else
    _pass "TC-TH-3: sibling JSONL file not blocked by TASK_HISTORY_WRITE_DENY (correct — pattern is precise)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed (of $((TESTS_PASS + TESTS_FAIL)) tests)"

if [ $TESTS_FAIL -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILURES: $TESTS_FAIL test(s) failed." >&2
    exit 1
fi
