#!/usr/bin/env bash
# install-post-commit-journal-reminder.sh — installs a post-commit hook that
# reminds the coordinator to append a journal entry after every commit.
#
# Usage: bash scripts/install-post-commit-journal-reminder.sh
#
# Behavior:
#   - Detects existing .git/hooks/post-commit and checks for our sentinel.
#   - If sentinel found: no-op (already installed).
#   - If hook exists but no sentinel: prompts user to append or abort.
#   - If no hook exists: writes a fresh hook file.
#   - Marks the hook executable.
#
# Exit 0: installed or already present.
# Exit 1: user aborted or unexpected state.

set -euo pipefail

SENTINEL="# ainous-team:journal-reminder"

# Resolve git dir
if ! GIT_DIR=$(git rev-parse --git-dir 2>/dev/null); then
  printf 'error: not inside a git repository\n' >&2
  exit 1
fi

HOOK_PATH="$GIT_DIR/hooks/post-commit"

HOOK_SNIPPET=$(cat <<'HOOK'
#!/usr/bin/env bash
# ainous-team:journal-reminder — installed by scripts/install-post-commit-journal-reminder.sh
SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --format=%s)
printf '\n[coordinator] reminder: append journal entry for %s — "%s"\n' "$SHA" "$SUBJECT" >&2
printf '  path: .claude/ainous-roles/coordinator/journal.md\n' >&2
printf '  format: ## %s — <task title>\n\n' "$(date -u +%Y-%m-%d)" >&2
HOOK
)

# --- Already installed? ---
if [ -f "$HOOK_PATH" ] && grep -qF "$SENTINEL" "$HOOK_PATH"; then
  printf '[install] post-commit journal reminder already installed — no-op\n'
  exit 0
fi

# --- Hook exists but no sentinel ---
if [ -f "$HOOK_PATH" ]; then
  printf '[install] existing post-commit hook found at %s\n' "$HOOK_PATH"
  printf '[install] it does not contain our sentinel. Options:\n'
  printf '  a) append our reminder to the existing hook\n'
  printf '  b) abort (no changes made)\n'
  printf 'Choice [a/b]: '
  read -r choice </dev/tty
  case "$choice" in
    a|A)
      printf '\n%s\n' "$HOOK_SNIPPET" >> "$HOOK_PATH"
      chmod +x "$HOOK_PATH"
      printf '[install] appended journal reminder to existing hook\n'
      exit 0
      ;;
    *)
      printf '[install] aborted — no changes made\n'
      exit 1
      ;;
  esac
fi

# --- No hook exists — write fresh ---
printf '%s\n' "$HOOK_SNIPPET" > "$HOOK_PATH"
chmod +x "$HOOK_PATH"
printf '[install] post-commit journal reminder installed at %s\n' "$HOOK_PATH"
exit 0
