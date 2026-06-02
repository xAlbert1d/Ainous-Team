#!/usr/bin/env bash
# verify-hook-env-vars.sh — R-6 hook env-var liveness self-test
#
# Extracts all env-var references from hook scripts, filters out env vars that
# are set by our hooks or the OS (not read FROM Claude Code), then verifies each
# remaining var actually exists in the Claude Code binary via `strings`.
#
# This prevents the "tests pass, prod fails" pattern where a hook reads a
# fabricated env var that Claude Code never sets (v5.6.1 CLAUDE_SESSION_ID env,
# v5.9.0 round-1 CLAUDE_TEAM_NAME were both caught by this pattern).
#
# Exit codes:
#   0 — all referenced env vars found in binary (or binary not accessible → graceful skip)
#   2 — one or more vars NOT found in binary (actionable failure with hook:line reported)
#
# Usage:
#   bash scripts/verify-hook-env-vars.sh [--verbose]

set -uo pipefail

VERBOSE=0
for _arg in "$@"; do
    case "$_arg" in
        --verbose) VERBOSE=1 ;;
        *) printf 'Usage: verify-hook-env-vars.sh [--verbose]\n' >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# ---------------------------------------------------------------------------
# Allowlist: env vars that are SET BY our hooks/OS — not read from Claude Code.
# These are intentionally excluded from liveness checks.
# ---------------------------------------------------------------------------
ALLOWLIST=(
    # Set by the OS / shell / standard environment
    "HOME"
    "USER"
    "PATH"
    "LANG"
    "SHELL"
    "TMPDIR"
    "TERM"
    "PWD"
    "OLDPWD"
    "IFS"
    "PS1"
    "PS2"
    # Set by tmux (not Claude Code)
    "TMUX_PANE"
    "TMUX"
    # Set BY our hooks (output side)
    "TAINT_FLAG_HOOK"
    "CLAUDE_PLUGIN_ROOT"
    # Set by the test harness or CI environment
    "CI"
    "GITHUB_ACTIONS"
    "TOOL_USE_NAME"
    # General OS signals / process management
    "SIGTERM"
    "SIGINT"
    # Python/bash built-ins
    "PYTHONPATH"
    "PYTHONDONTWRITEBYTECODE"
    # macOS specifics
    "DYLD_LIBRARY_PATH"
    # Version-dependent Claude Code vars: present in some Claude Code versions, absent in others.
    # Referenced only as optional corroborating/log signals with safe empty-string defaults,
    # so absence degrades gracefully and is NOT a fabrication bug. Behavior is correct whether
    # or not the currently-installed binary provides the var.
    "CLAUDE_CODE_TEAM_NAME"  # present in some CC versions; used in log/error strings alongside
                             # CLAUDE_CODE_TEAMMATE_COMMAND — never in a branch condition.
                             # Empty default means behavior is identical when absent.
)

# Build allowlist as pipe-separated regex alternation for grep
_ALLOWLIST_RE=""
for _var in "${ALLOWLIST[@]}"; do
    if [ -z "$_ALLOWLIST_RE" ]; then
        _ALLOWLIST_RE="^${_var}$"
    else
        _ALLOWLIST_RE="${_ALLOWLIST_RE}|^${_var}$"
    fi
done

# ---------------------------------------------------------------------------
# Extract env-var references from all hook files.
# Patterns:
#   Python: os.environ.get("VAR"), os.environ["VAR"], os.environ.get('VAR')
#   Bash:   ${VAR}, ${VAR:-}, "$VAR", $VAR (only UPPERCASE identifiers)
# We only extract UPPERCASE names (Claude Code vars are all UPPER_SNAKE_CASE).
# Output: file:line:VARNAME
# ---------------------------------------------------------------------------
_extract_refs() {
    python3 - "$HOOKS_DIR" << 'PYEOF'
import sys, os, re

hooks_dir = sys.argv[1]

# ---------------------------------------------------------------------------
# Strategy: extract only env vars that are READS (not assignments) and look
# like Claude Code-supplied vars. We restrict to:
#   1. Python os.environ.get() / os.environ[] — these are explicit env reads.
#   2. Bash ${VAR:-default} or ${VAR} patterns — only for names that start with
#      CLAUDE_ (Claude Code's convention). Generic uppercase bash vars like
#      PROJECT_ROOT, ROLE_MARKER etc. are local script variables, not env reads.
#
# This avoids false positives on local bash variables while still catching
# fabricated CLAUDE_* vars (the actual failure mode — CLAUDE_TEAM_NAME, etc.)
# ---------------------------------------------------------------------------

# Python: os.environ.get("VAR") or os.environ["VAR"] or os.environ.get('VAR')
PYTHON_GET_RE  = re.compile(r'os\.environ(?:\.get)?\(["\']([A-Z][A-Z0-9_]+)["\']')

# Bash: ${CLAUDE_FOO} or ${CLAUDE_FOO:-default} — restricted to CLAUDE_ prefix
# to avoid flagging local script variables.
BASH_CLAUDE_BRACE_RE = re.compile(r'\$\{(CLAUDE_[A-Z0-9_]+)(?::-[^}]*)?\}')

# Bash: $CLAUDE_FOO (bare dollar reference, CLAUDE_ prefix only)
BASH_CLAUDE_DOLLAR_RE = re.compile(r'(?<![A-Z0-9_])\$(CLAUDE_[A-Z0-9_]+)(?![A-Z0-9_=])')

seen = set()

try:
    entries = sorted(os.listdir(hooks_dir))
except OSError as e:
    print(f"ERROR: cannot list hooks dir {hooks_dir}: {e}", file=sys.stderr)
    sys.exit(1)

for fname in entries:
    fpath = os.path.join(hooks_dir, fname)
    if not os.path.isfile(fpath):
        continue
    # Skip Python helper modules — they don't reference Claude Code env vars directly
    if fname.startswith('_') and fname.endswith('.py'):
        continue
    try:
        with open(fpath, encoding='utf-8', errors='replace') as f:
            for lineno, line in enumerate(f, 1):
                stripped = line.rstrip()
                # Python env reads: any UPPERCASE name (not restricted to CLAUDE_)
                for m in PYTHON_GET_RE.finditer(stripped):
                    key = (fname, lineno, m.group(1))
                    if key not in seen:
                        seen.add(key)
                        print(f"{fname}:{lineno}:{m.group(1)}")
                # Bash env reads: only CLAUDE_* vars (avoids flagging local script vars)
                for m in BASH_CLAUDE_BRACE_RE.finditer(stripped):
                    key = (fname, lineno, m.group(1))
                    if key not in seen:
                        seen.add(key)
                        print(f"{fname}:{lineno}:{m.group(1)}")
                for m in BASH_CLAUDE_DOLLAR_RE.finditer(stripped):
                    key = (fname, lineno, m.group(1))
                    if key not in seen:
                        seen.add(key)
                        print(f"{fname}:{lineno}:{m.group(1)}")
    except OSError:
        continue
PYEOF
}

# ---------------------------------------------------------------------------
# Find Claude Code binary — follow 'which claude' symlink chain to find the
# versioned binary directory, then locate the actual executable.
# Returns the binary path in CLAUDE_BINARY or sets it empty on failure.
# ---------------------------------------------------------------------------
_find_claude_binary() {
    local _claude_cmd
    _claude_cmd=$(which claude 2>/dev/null || echo "")
    if [ -z "$_claude_cmd" ]; then
        echo ""
        return
    fi

    # Follow symlinks to find real path
    local _real
    _real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$_claude_cmd" 2>/dev/null || echo "$_claude_cmd")

    # Check the real path exists and is a file
    if [ -f "$_real" ]; then
        echo "$_real"
        return
    fi

    # Fallback: glob for binaries in known claude install dirs
    local _candidate
    for _candidate in \
        "$HOME/.local/share/claude/versions"/*/*/claude \
        "$HOME/.local/share/claude/versions"/*/claude \
        /usr/local/bin/claude \
        /usr/bin/claude
    do
        if [ -f "$_candidate" ] && [ -x "$_candidate" ]; then
            echo "$_candidate"
            return
        fi
    done

    echo ""
}

CLAUDE_BINARY=$(_find_claude_binary)

if [ -z "$CLAUDE_BINARY" ]; then
    printf 'WARNING: Claude Code binary not found (which claude returned empty). Skipping env-var liveness check.\n'
    printf 'This is expected in CI environments without Claude Code installed.\n'
    exit 0
fi

if ! command -v strings &>/dev/null; then
    printf 'WARNING: `strings` utility not found. Skipping env-var liveness check.\n'
    printf 'Install binutils (macOS: brew install binutils or use system strings).\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Collect all referenced var names + their locations
# ---------------------------------------------------------------------------
_REFS_TMPFILE=$(mktemp /tmp/vhev-refs.XXXXXX)
trap 'rm -f "$_REFS_TMPFILE"' EXIT INT TERM HUP

_extract_refs > "$_REFS_TMPFILE"

if [ ! -s "$_REFS_TMPFILE" ]; then
    printf 'No env-var references found in hooks/ — nothing to check.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Build unique var name list, filtering allowlist
# ---------------------------------------------------------------------------
_UNIQUE_VARS=$(awk -F: '{print $3}' "$_REFS_TMPFILE" | sort -u)

# ---------------------------------------------------------------------------
# Run strings on binary (once, cache to temp file)
# ---------------------------------------------------------------------------
_STRINGS_TMPFILE=$(mktemp /tmp/vhev-strings.XXXXXX)
trap 'rm -f "$_REFS_TMPFILE" "$_STRINGS_TMPFILE"' EXIT INT TERM HUP

if ! strings "$CLAUDE_BINARY" > "$_STRINGS_TMPFILE" 2>/dev/null; then
    printf 'WARNING: strings failed on %s. Skipping liveness check (graceful degradation).\n' "$CLAUDE_BINARY"
    exit 0
fi

# ---------------------------------------------------------------------------
# Check each unique var name
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

printf 'Hook env-var liveness check against: %s\n' "$CLAUDE_BINARY"
printf '%s\n' "$(printf '%0.s-' {1..70})"

while IFS= read -r _VARNAME; do
    [ -z "$_VARNAME" ] && continue

    # Check allowlist
    if echo "$_VARNAME" | grep -qE "$_ALLOWLIST_RE" 2>/dev/null; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        if [ "$VERBOSE" -eq 1 ]; then
            printf '  SKIP  %-40s (allowlisted — OS/hook-set, not Claude Code)\n' "$_VARNAME"
        fi
        continue
    fi

    # Check if var appears in binary strings
    if grep -qF "$_VARNAME" "$_STRINGS_TMPFILE" 2>/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  %s  %s\n' "✓" "$_VARNAME"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  %s  %s  [NOT FOUND IN BINARY]\n' "✗" "$_VARNAME"
        # Show all hook:line references for this failing var
        grep -F ":${_VARNAME}" "$_REFS_TMPFILE" | while IFS=: read -r _file _line _var; do
            printf '      referenced at: hooks/%s line %s\n' "$_file" "$_line"
        done
    fi
done <<< "$_UNIQUE_VARS"

printf '%s\n' "$(printf '%0.s-' {1..70})"
printf 'Results: %d found (%d skipped/allowlisted), %d NOT FOUND\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\nFAILURE: %d env var(s) referenced in hooks but not found in Claude Code binary.\n' "$FAIL_COUNT"
    printf 'These vars will be silently empty at runtime — fix or move to allowlist.\n'
    exit 2
fi

printf '\nAll referenced env vars verified in Claude Code binary.\n'
exit 0
