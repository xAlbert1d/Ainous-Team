#!/usr/bin/env bash
# test-gen-skill-index.sh — Test suite for scripts/gen-skill-index.py
#
# TC-GSI-1: every on-disk skill in skills/ is present in the catalog
# TC-GSI-2: only image-craft-base is invocable:false in the catalog
# TC-GSI-3: every invocable:true skill has >=1 owning_role
# TC-GSI-4: regenerating twice produces no diff (idempotent)
# TC-GSI-5: --check detects an injected card change (uses a temp copy)
#
# Run: bash tests/test-gen-skill-index.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN_SCRIPT="$PROJECT_ROOT/scripts/gen-skill-index.py"
INDEX_JSON="$PROJECT_ROOT/agents/capabilities/index.json"
SKILLS_DIR="$PROJECT_ROOT/skills"

TESTS_PASS=0
TESTS_FAIL=0

_pass() { printf 'PASS: %s\n' "$1"; ((TESTS_PASS++)) || true; }
_fail() { printf 'FAIL: %s\n' "$1"; printf '      %s\n' "$2" >&2; ((TESTS_FAIL++)) || true; }

# Require python3
if ! command -v python3 &>/dev/null; then
    printf 'SKIP: python3 not found — cannot run test suite\n' >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Build a fresh snapshot of the catalog to test against (without modifying
# the real index.json — use --stdout for reads).
# ---------------------------------------------------------------------------
_catalog_json="$(python3 "$GEN_SCRIPT" --stdout 2>&1)"
if [ $? -ne 0 ] || [ -z "$_catalog_json" ]; then
    printf 'ERROR: gen-skill-index.py --stdout failed; cannot run tests\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# TC-GSI-1: every on-disk skill in skills/ is present in the catalog
# ---------------------------------------------------------------------------
_missing_from_catalog=""
while IFS= read -r -d '' skill_md; do
    skill_dir="$(dirname "$skill_md")"
    # parse name from frontmatter
    _name=""
    while IFS= read -r line; do
        case "$line" in
            "---") break ;;
            name:*) _name="${line#name:}"; _name="${_name## }"; _name="${_name%\"*}"; _name="${_name#\"}" ;;
        esac
    done < <(tail -n +2 "$skill_md")

    # Use python to parse properly
    _name="$(python3 - "$skill_md" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
if not content.startswith("---"):
    sys.exit(0)
end = content.find("---", 3)
if end == -1:
    sys.exit(0)
for line in content[3:end].strip().splitlines():
    if line.strip().startswith("name:"):
        name = line.split(":", 1)[1].strip().strip('"').strip("'")
        print(name)
        break
PYEOF
)"

    if [ -z "$_name" ]; then
        continue
    fi

    _in_catalog="$(printf '%s' "$_catalog_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
name = sys.argv[1]
print('yes' if name in d else 'no')
" "$_name" 2>/dev/null)"

    if [ "$_in_catalog" != "yes" ]; then
        _missing_from_catalog="${_missing_from_catalog} ${_name}"
    fi
done < <(find "$SKILLS_DIR" -name "SKILL.md" -print0 | sort -z)

if [ -z "$_missing_from_catalog" ]; then
    _pass "TC-GSI-1: every on-disk skill is present in the catalog"
else
    _fail "TC-GSI-1: every on-disk skill is present in the catalog" \
          "missing from catalog:$_missing_from_catalog"
fi

# ---------------------------------------------------------------------------
# TC-GSI-2: only image-craft-base is invocable:false in the catalog
# ---------------------------------------------------------------------------
_unexpected_non_invocable="$(printf '%s' "$_catalog_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [name for name, entry in d.items() if entry.get('invocable', True) is False and name != 'image-craft-base']
for b in sorted(bad):
    print(b)
" 2>/dev/null)"

_icb_invocable="$(printf '%s' "$_catalog_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
entry = d.get('image-craft-base', {})
print(entry.get('invocable', True))
" 2>/dev/null)"

if [ "$_icb_invocable" = "False" ] && [ -z "$_unexpected_non_invocable" ]; then
    _pass "TC-GSI-2: only image-craft-base is invocable:false"
else
    _detail=""
    [ "$_icb_invocable" != "False" ] && _detail="image-craft-base.invocable=$_icb_invocable (expected False)"
    [ -n "$_unexpected_non_invocable" ] && _detail="${_detail} unexpected non-invocable: $_unexpected_non_invocable"
    _fail "TC-GSI-2: only image-craft-base is invocable:false" "$_detail"
fi

# ---------------------------------------------------------------------------
# TC-GSI-3: every invocable:true skill has >=1 owning_role
# ---------------------------------------------------------------------------
_no_owner="$(printf '%s' "$_catalog_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [name for name, entry in sorted(d.items())
       if entry.get('invocable', True) is True and not entry.get('owning_roles')]
for b in bad:
    print(b)
" 2>/dev/null)"

if [ -z "$_no_owner" ]; then
    _pass "TC-GSI-3: every invocable:true skill has >=1 owning_role"
else
    _fail "TC-GSI-3: every invocable:true skill has >=1 owning_role" \
          "skills with no owning_role: $_no_owner"
fi

# ---------------------------------------------------------------------------
# TC-GSI-4: regenerate twice = no diff (idempotent)
# ---------------------------------------------------------------------------
TMPDIR_IDEM=$(mktemp -d /tmp/test-gsi-idem.XXXXXX)
trap 'rm -rf "$TMPDIR_IDEM"' EXIT INT TERM

_run1="$(python3 "$GEN_SCRIPT" --stdout 2>/dev/null)"
_run2="$(python3 "$GEN_SCRIPT" --stdout 2>/dev/null)"

if [ "$_run1" = "$_run2" ]; then
    _pass "TC-GSI-4: two consecutive --stdout runs produce identical output (idempotent)"
else
    _fail "TC-GSI-4: two consecutive --stdout runs produce identical output (idempotent)" \
          "outputs differ"
fi

# ---------------------------------------------------------------------------
# TC-GSI-5: --check detects an injected card change (temp copy)
# ---------------------------------------------------------------------------
TMPDIR_CHK=$(mktemp -d /tmp/test-gsi-chk.XXXXXX)
# trap cleanup already set above; extend it
trap 'rm -rf "$TMPDIR_IDEM" "$TMPDIR_CHK"' EXIT INT TERM

# Copy the whole project into a temp dir so we can mutate without touching the real tree
FAKE_ROOT="$TMPDIR_CHK/plugin"
cp -R "$PROJECT_ROOT" "$FAKE_ROOT"

# Verify --check passes on the unmodified copy
_check_out="$(python3 "$FAKE_ROOT/scripts/gen-skill-index.py" --check 2>&1)"
_check_exit=$?

if [ "$_check_exit" -eq 0 ]; then
    _pass "TC-GSI-5a: --check passes on unmodified copy"
else
    _fail "TC-GSI-5a: --check passes on unmodified copy" \
          "exit $_check_exit; output: $_check_out"
fi

# Inject a change: add a new fake skill card to the copy
FAKE_SKILL_DIR="$FAKE_ROOT/skills/test-injected-skill-$$"
mkdir -p "$FAKE_SKILL_DIR"
cat > "$FAKE_SKILL_DIR/SKILL.md" <<'SKILL_EOF'
---
name: test-injected-skill
description: A synthetic skill injected by the test suite to verify --check drift detection.
---
SKILL_EOF

# --check should now exit 2 (drift)
_check_out2="$(python3 "$FAKE_ROOT/scripts/gen-skill-index.py" --check 2>&1)"
_check_exit2=$?

if [ "$_check_exit2" -eq 2 ]; then
    _pass "TC-GSI-5b: --check exits 2 after injected skill card change"
else
    _fail "TC-GSI-5b: --check exits 2 after injected skill card change" \
          "exit $_check_exit2; output: $_check_out2"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_TESTS=$((TESTS_PASS + TESTS_FAIL))
printf '\n%d/%d tests passed.\n' "$TESTS_PASS" "$TOTAL_TESTS"

if [ "$TESTS_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
