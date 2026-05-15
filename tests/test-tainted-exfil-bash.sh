#!/usr/bin/env bash
# test-tainted-exfil-bash.sh — TC-CRED-6..15: Item 1 security patch tests
#
# Tests for v5.8.1 Item 1:
#   - Tainted sessions block credential paths even without redirect (stdout=exfil)
#   - Non-tainted sessions block unconditional secret paths (e.g. cat ~/.ssh/id_rsa)
#   - No false positives on non-credential paths
#
# TC-CRED-6:  non-tainted + cat ~/.ssh/id_rsa → exit 2 (unconditional secret block)
# TC-CRED-7:  tainted + grep . ~/.ssh/id_rsa → exit 2 (tainted-stdout-as-egress)
# TC-CRED-8:  tainted + find / -name '*.nonce' -print → exit 2
# TC-CRED-9:  tainted + ls ~/.claude/teams/X/nonces/ → exit 2
# TC-CRED-10: tainted + cat /etc/passwd → exit 2 (unconditional secret block, tainted)
# TC-CRED-11: tainted + cat hello.txt → exit 0 (no false positive)
# TC-CRED-12: non-tainted + grep TODO src/foo.py → exit 0 (no regression)
# TC-CRED-13: non-tainted + cat ~/.aws/credentials → exit 2 (unconditional block)
# TC-CRED-14: tainted + cat ~/.aws/credentials → exit 2 (tainted+unconditional)
# TC-CRED-15: non-tainted + grep pattern src/app.py → exit 0 (no false positive)
#
# Run: bash tests/test-tainted-exfil-bash.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/hooks/authority-enforce.sh"
TESTS_PASS=0
TESTS_FAIL=0

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d /tmp/test-tainted-exfil-bash.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT INT TERM

FAKE_HOME="$TMPDIR_BASE/home"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/developer"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/tester"
mkdir -p "$FAKE_HOME/.claude/ainous-roles/authority"

cat > "$FAKE_HOME/.claude/ainous-roles/developer/growth.json" <<'EOF'
{"trust":{"level":"senior"}}
EOF
touch "$FAKE_HOME/.claude/ainous-roles/authority/decisions.md"
echo "developer" > "$FAKE_HOME/.claude/.session-role"

FAKE_PROJECT="$TMPDIR_BASE/project"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"
mkdir -p "$FAKE_PROJECT/src"
cat > "$FAKE_PROJECT/.claude/ainous-roles/baselines.json" <<'EOF'
{"developer":["src/","scripts/","docs/"]}
EOF

# ---------------------------------------------------------------------------
# Taint state setup
# ---------------------------------------------------------------------------
FAKE_NONCE_DIR="$FAKE_HOME/.claude/.taint-nonces"
mkdir -p "$FAKE_NONCE_DIR"

TAINTED_SESSION_ID="tainted-exfil-test-xyz123"
CLEAN_SESSION_ID="clean-exfil-test-abc000"

# Compute nonce filename for tainted session
HASHED_SID=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" \
    "$TAINTED_SESSION_ID" 2>/dev/null)
NONCE_BYTES="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
NONCE_FILE="$FAKE_NONCE_DIR/${HASHED_SID}.nonce"
printf '%s' "$NONCE_BYTES" > "$NONCE_FILE"
chmod 600 "$NONCE_FILE"

# Compute hashed flag filename for tainted session
HASHED_FLAG=$(python3 -c "
import hashlib, sys
sid = sys.argv[1]
nonce = sys.argv[2].encode()
combined = sid.encode() + nonce
print(hashlib.sha256(combined).hexdigest())
" "$TAINTED_SESSION_ID" "$NONCE_BYTES" 2>/dev/null)

TAINT_FLAGS_DIR="$FAKE_PROJECT/.claude/ainous-roles/team-sync/state/taint-flags"
FLAG_FILE="$TAINT_FLAGS_DIR/${HASHED_FLAG}.jsonl"

# Write a taint flag record to mark the session as tainted
echo '{"ts":"2026-04-18T10:00:00Z","tool":"WebFetch","url":"https://evil.example/","content_hash":"abc123","role":"developer","schema":"1"}' > "$FLAG_FILE"

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
_pass() { echo "PASS: $1"; ((TESTS_PASS++)) || true; }
_fail() { echo "FAIL: $1"; echo "      $2" >&2; ((TESTS_FAIL++)) || true; }

_run_bash() {
    local command="$1"
    local session_id="${2:-$TAINTED_SESSION_ID}"
    local role="${3:-developer}"
    echo "$role" > "$FAKE_HOME/.claude/.session-role"
    local json_input
    json_input=$(python3 -c "import json,sys; print(json.dumps({'command':sys.argv[1]}))" "$command" 2>/dev/null)
    (
        cd "$FAKE_PROJECT"
        HOME="$FAKE_HOME" \
        TOOL_USE_NAME="Bash" \
        CLAUDE_SESSION_ID="$session_id" \
        CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
        bash "$HOOK" <<< "$json_input" 2>/dev/null
    )
    return $?
}

# ---------------------------------------------------------------------------
# TC-CRED-6: non-tainted + cat ~/.ssh/id_rsa → exit 2 (unconditional secret block)
# ---------------------------------------------------------------------------
_run_bash "cat ~/.ssh/id_rsa" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-6: non-tainted + cat ~/.ssh/id_rsa → exit 2 (unconditional secret block)"
else
    _fail "TC-CRED-6: expected exit 2, got $EXIT_CODE" "~/.ssh/id_rsa should be unconditionally blocked even without redirect"
fi

# ---------------------------------------------------------------------------
# TC-CRED-7: tainted + grep . ~/.ssh/id_rsa → exit 2 (tainted-stdout-as-egress)
# In a tainted session, even grep without redirect is blocked — stdout IS egress.
# ---------------------------------------------------------------------------
_run_bash "grep . ~/.ssh/id_rsa" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-7: tainted + grep . ~/.ssh/id_rsa → exit 2 (tainted-stdout-as-egress)"
else
    _fail "TC-CRED-7: expected exit 2, got $EXIT_CODE" "grep of credential path in tainted session should be blocked (stdout=exfil)"
fi

# ---------------------------------------------------------------------------
# TC-CRED-8: tainted + find / -name '*.nonce' -print → exit 2
# find without -exec is normally in allowlist; but .nonce appears in the command path.
# The command itself doesn't have a credential path directly... but the taint-nonces
# pattern would match any *.nonce reference. Actually the command "find / -name *.nonce"
# doesn't contain a credential path per se — the deny triggers on nonce FILE paths.
# Let's use a more concrete case: find the nonce dir itself.
# ---------------------------------------------------------------------------
_run_bash "find $FAKE_NONCE_DIR -name '*.nonce' -print" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-8: tainted + find on nonce directory path → exit 2"
else
    _fail "TC-CRED-8: expected exit 2, got $EXIT_CODE" "find mentioning nonce dir in tainted session should be blocked"
fi

# ---------------------------------------------------------------------------
# TC-CRED-9: tainted + ls ~/.claude/teams/X/nonces/ → exit 2
# ---------------------------------------------------------------------------
_run_bash "ls $FAKE_HOME/.claude/teams/myteam/nonces/" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-9: tainted + ls of nonce directory → exit 2"
else
    _fail "TC-CRED-9: expected exit 2, got $EXIT_CODE" "ls of nonce dir path in tainted session should be blocked"
fi

# ---------------------------------------------------------------------------
# TC-CRED-10: tainted + cat /etc/passwd → exit 2
# /etc/passwd is in unconditional patterns — blocked even in tainted session without redirect
# ---------------------------------------------------------------------------
_run_bash "cat /etc/passwd" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-10: tainted + cat /etc/passwd → exit 2 (unconditional secret block)"
else
    _fail "TC-CRED-10: expected exit 2, got $EXIT_CODE" "/etc/passwd should be unconditionally blocked"
fi

# ---------------------------------------------------------------------------
# TC-CRED-11: tainted + cat hello.txt → exit 0 (non-credential path — no false positive)
# ---------------------------------------------------------------------------
touch "$FAKE_PROJECT/hello.txt"
_run_bash "cat $FAKE_PROJECT/hello.txt" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-11: tainted + cat hello.txt → exit 0 (no false positive for non-credential path)"
else
    _fail "TC-CRED-11: expected exit 0, got $EXIT_CODE" "cat of non-credential file in tainted session should be allowed"
fi

# ---------------------------------------------------------------------------
# TC-CRED-12: non-tainted + grep TODO src/foo.py → exit 0 (no regression)
# ---------------------------------------------------------------------------
touch "$FAKE_PROJECT/src/foo.py"
_run_bash "grep TODO $FAKE_PROJECT/src/foo.py" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-12: non-tainted + grep TODO src/foo.py → exit 0 (no regression)"
else
    _fail "TC-CRED-12: expected exit 0, got $EXIT_CODE" "grep on non-credential file should be allowed (non-tainted session)"
fi

# ---------------------------------------------------------------------------
# TC-CRED-13: non-tainted + cat ~/.aws/credentials → exit 2
# ---------------------------------------------------------------------------
_run_bash "cat ~/.aws/credentials" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-13: non-tainted + cat ~/.aws/credentials → exit 2 (unconditional secret block)"
else
    _fail "TC-CRED-13: expected exit 2, got $EXIT_CODE" "~/.aws/credentials should be unconditionally blocked"
fi

# ---------------------------------------------------------------------------
# TC-CRED-14: tainted + cat ~/.aws/credentials → exit 2
# ---------------------------------------------------------------------------
_run_bash "cat ~/.aws/credentials" "$TAINTED_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-14: tainted + cat ~/.aws/credentials → exit 2 (tainted+unconditional)"
else
    _fail "TC-CRED-14: expected exit 2, got $EXIT_CODE" "~/.aws/credentials should be blocked in tainted session"
fi

# ---------------------------------------------------------------------------
# TC-CRED-15: non-tainted + grep pattern src/app.py → exit 0 (no false positive)
# ---------------------------------------------------------------------------
touch "$FAKE_PROJECT/src/app.py"
_run_bash "grep pattern $FAKE_PROJECT/src/app.py" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-15: non-tainted + grep pattern src/app.py → exit 0 (no false positive)"
else
    _fail "TC-CRED-15: expected exit 0, got $EXIT_CODE" "grep on project source file should be allowed (non-tainted session)"
fi

# ---------------------------------------------------------------------------
# TC-CRED-16 through TC-CRED-21: v5.8.2 Item 1 & 2 pattern-tightening tests
# ---------------------------------------------------------------------------

# TC-CRED-16: .env.example → exit 0 (extension variant, DX fix)
_run_bash "cat .env.example" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-16: cat .env.example → exit 0 (extension variant allowed by negative lookahead)"
else
    _fail "TC-CRED-16: expected exit 0, got $EXIT_CODE" ".env.example should NOT be blocked — only bare .env is sensitive"
fi

# TC-CRED-17: .envrc (direnv config) → exit 0
_run_bash "cat src/.envrc" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-17: cat src/.envrc → exit 0 (direnv config allowed)"
else
    _fail "TC-CRED-17: expected exit 0, got $EXIT_CODE" ".envrc should NOT be blocked — it is not a secret file"
fi

# TC-CRED-18: test fixture key with no credential dir signal → exit 0
_run_bash "cat test/fixtures/testkey.key" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-18: cat test/fixtures/testkey.key → exit 0 (no credential dir signal)"
else
    _fail "TC-CRED-18: expected exit 0, got $EXIT_CODE" "test/fixtures/testkey.key should NOT be blocked — no cred-dir signal"
fi

# TC-CRED-19: ~/.ssh/id_rsa.pem → exit 2 (credential dir signal present)
_run_bash "cat ~/.ssh/id_rsa.pem" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-19: cat ~/.ssh/id_rsa.pem → exit 2 (credential dir signal: .ssh/)"
else
    _fail "TC-CRED-19: expected exit 2, got $EXIT_CODE" "~/.ssh/id_rsa.pem must be blocked — .ssh/ is a credential dir"
fi

# TC-CRED-20: /etc/ssl/certs/ca.crt → exit 2 (in /etc/)
_run_bash "cat /etc/ssl/certs/ca.crt" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-20: cat /etc/ssl/certs/ca.crt → exit 2 (/etc/ credential dir signal)"
else
    _fail "TC-CRED-20: expected exit 2, got $EXIT_CODE" "/etc/ssl/certs/ca.crt must be blocked — /etc/ is a credential dir signal"
fi

# TC-CRED-21: public deploy cert without credential dir signal → exit 0
_run_bash "cat public-deploy.crt" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    _pass "TC-CRED-21: cat public-deploy.crt → exit 0 (no credential dir signal)"
else
    _fail "TC-CRED-21: expected exit 0, got $EXIT_CODE" "public-deploy.crt should NOT be blocked — no cred-dir signal"
fi

# ---------------------------------------------------------------------------
# TC-CRED-22 through TC-CRED-25: v5.8.2 Item 6 — credential-assign variants
# ---------------------------------------------------------------------------

# TC-CRED-22: export P=~/.ssh/id_rsa; cat $P → exit 2
_run_bash "export P=~/.ssh/id_rsa; cat \$P" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-22: export P=~/.ssh/id_rsa; cat \$P → exit 2 (export assignment blocked)"
else
    _fail "TC-CRED-22: expected exit 2, got $EXIT_CODE" "export of SSH key path should be blocked at assignment"
fi

# TC-CRED-23: declare -x P=~/.ssh/id_rsa → exit 2
_run_bash "declare -x P=~/.ssh/id_rsa" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-23: declare -x P=~/.ssh/id_rsa → exit 2 (declare assignment blocked)"
else
    _fail "TC-CRED-23: expected exit 2, got $EXIT_CODE" "declare -x of SSH key path should be blocked at assignment"
fi

# TC-CRED-24: readonly P=/etc/shadow; cat $P → exit 2
_run_bash "readonly P=/etc/shadow; cat \$P" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-24: readonly P=/etc/shadow; cat \$P → exit 2 (readonly assignment blocked)"
else
    _fail "TC-CRED-24: expected exit 2, got $EXIT_CODE" "readonly of /etc/shadow path should be blocked at assignment"
fi

# TC-CRED-25: arr=(~/.ssh/id_rsa); cat "${arr[0]}" → exit 2
_run_bash "arr=(~/.ssh/id_rsa); cat \"\${arr[0]}\"" "$CLEAN_SESSION_ID"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 2 ]; then
    _pass "TC-CRED-25: arr=(~/.ssh/id_rsa); cat \"\${arr[0]}\" → exit 2 (array assignment with SSH key blocked)"
else
    _fail "TC-CRED-25: expected exit 2, got $EXIT_CODE" "array assignment of SSH key path should be blocked"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASS passed, $TESTS_FAIL failed"
if [ $TESTS_FAIL -gt 0 ]; then
    exit 1
fi
exit 0
