#!/usr/bin/env bash
# setup.sh — Initialize ainous-roles for a new Ainous Team installation
# Usage: bash setup.sh [--agentmode]
#   Default:      Claude Code becomes the coordinator (plans, delegates, synthesizes automatically)
#   --agentmode:  Manual mode — invoke roles explicitly with @coordinator, @developer, etc.
set -euo pipefail

COORDINATOR_MODE=true
for arg in "$@"; do
    case "$arg" in
        --agentmode) COORDINATOR_MODE=false ;;
    esac
done

# Check prerequisites
if ! command -v python3 &>/dev/null; then
    echo "Error: Python 3 is required but not found."
    echo "Install Python 3 (https://www.python.org/) and try again."
    exit 1
fi
if ! command -v git &>/dev/null; then
    echo "Error: git is required but not found."
    exit 1
fi

ROLES_DIR="$HOME/.claude/ainous-roles"
OLD_ROLES_DIR="$HOME/.claude/persistent-roles"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$(cd "$SCRIPT_DIR/../templates" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROLES_DIR="${PROJECT_ROOT}/.claude/ainous-roles"

# Migrate from old directory name if it exists
if [ -d "$OLD_ROLES_DIR" ] && [ ! -d "$ROLES_DIR" ]; then
    echo "Migrating $OLD_ROLES_DIR → $ROLES_DIR..."
    mv "$OLD_ROLES_DIR" "$ROLES_DIR"
    echo "  Migration complete. All learned data preserved."
fi

echo "Initializing Ainous Team roles at $ROLES_DIR..."

# Role → metric mapping (portable — no bash 4+ associative arrays needed)
get_metric() {
    case "$1" in
        coordinator)   echo "routing_accuracy" ;;
        developer)     echo "implementation_quality" ;;
        architect)     echo "design_quality" ;;
        code-quality)  echo "issues_found_accuracy" ;;
        tester)        echo "coverage_and_catch_rate" ;;
        researcher)    echo "finding_relevance" ;;
        writer)        echo "doc_completeness" ;;
        security)      echo "threat_detection_quality" ;;
        authority)     echo "approval_accuracy" ;;
        consolidator)  echo "distillation_quality" ;;
        retriever)     echo "retrieval_relevance" ;;
        signal)        echo "signal_relevance" ;;
        designer)      echo "design_fitness" ;;
        *)             echo "unknown_metric" ;;
    esac
}

for role in coordinator developer architect code-quality tester researcher writer security authority consolidator retriever signal designer; do
    mkdir -p "$ROLES_DIR/$role"
    if [ ! -f "$ROLES_DIR/$role/playbook.md" ]; then
        cp "$TEMPLATES/playbook.md" "$ROLES_DIR/$role/playbook.md"
        echo "  Created playbook for $role"
    fi
    if [ ! -f "$ROLES_DIR/$role/growth.json" ]; then
        metric="$(get_metric "$role")"
        sed -e "s/ROLE_NAME/$role/" -e "s/METRIC_NAME/$metric/" "$TEMPLATES/growth.json" > "$ROLES_DIR/$role/growth.json"
        echo "  Created growth.json for $role (metric: $metric)"
    fi

    # Project-level scaffold: journal.md and learnings.jsonl (.claude/ainous-roles/<role>/)
    mkdir -p "$PROJECT_ROLES_DIR/$role"
    if [ ! -f "$PROJECT_ROLES_DIR/$role/journal.md" ]; then
        sed -e "s/\[Role\]/$role/" "$TEMPLATES/journal.md" > "$PROJECT_ROLES_DIR/$role/journal.md"
        echo "  Created project journal.md for $role"
    fi
    if [ ! -f "$PROJECT_ROLES_DIR/$role/learnings.jsonl" ]; then
        : > "$PROJECT_ROLES_DIR/$role/learnings.jsonl"
        echo "  Created project learnings.jsonl for $role"
    fi
done

# Authority-specific files
if [ ! -f "$ROLES_DIR/authority/authority-book.md" ]; then
    cp "$TEMPLATES/authority-book.md" "$ROLES_DIR/authority/authority-book.md"
    echo "  Created authority-book.md"
fi
if [ ! -f "$ROLES_DIR/authority/decisions.md" ]; then
    cp "$TEMPLATES/decisions.md" "$ROLES_DIR/authority/decisions.md"
    echo "  Created decisions.md"
fi
if [ ! -f "$ROLES_DIR/authority/incident-response.md" ]; then
    cp "$TEMPLATES/incident-response.md" "$ROLES_DIR/authority/incident-response.md"
    echo "  Created incident-response.md"
fi

# Shared team knowledge base
if [ ! -f "$ROLES_DIR/team-knowledge.md" ]; then
    cp "$TEMPLATES/team-knowledge.md" "$ROLES_DIR/team-knowledge.md"
    echo "  Created team-knowledge.md (shared knowledge base)"
fi

# Generate project-level baselines.json (Layer 1 authority enforcement)
generate_baselines() {
    local baselines_dir=".claude/ainous-roles"
    local baselines_path="$baselines_dir/baselines.json"
    if [ -f "$baselines_path" ]; then
        echo "  baselines.json already exists — skipping generation"
        return
    fi
    mkdir -p "$baselines_dir"
    local generated
    generated="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$baselines_path" << BASEEOF
{
  "version": 1,
  "generated": "$generated",
  "developer": ["*.py", "*.js", "*.ts", "*.tsx", "*.jsx", "*.go", "*.rs", "*.java", "*.rb", "*.php", "*.c", "*.cpp", "*.h", "*.cs", "*.swift", "*.kt", "*.sh", "*.bash", "*.zsh", "Makefile", "*.mk", "package.json", "requirements.txt", "go.mod", "Cargo.toml", "pom.xml", "build.gradle", "src/", "lib/", "pkg/", "cmd/", "internal/", "app/", "api/", "services/", "utils/", "helpers/", "scripts/"],
  "architect": ["*.md", "*.yaml", "*.yml", "*.json", "*.toml", "*.ini", "*.cfg", "Dockerfile", "*.tf", "*.hcl", "docs/", "design/", "architecture/", "infra/", "terraform/", "k8s/"],
  "tester": ["*test*", "*spec*", "*.test.*", "*.spec.*", "*_test.*", "jest.config.*", "pytest.ini", ".coveragerc", "vitest.config.*", "test/", "tests/", "spec/", "specs/", "__tests__/", "e2e/", "integration/"],
  "writer": ["*.md", "*.txt", "*.rst", "*.adoc", "CHANGELOG*", "README*", "LICENSE*", "docs/", "documentation/", "wiki/"],
  "security": ["*.md", "*.yaml", "*.yml", "*.json", "*.toml", "docs/", "security/", ".github/"],
  "code-quality": [".eslintrc*", ".prettierrc*", "pylintrc", ".flake8", "mypy.ini", "*.json", "*.yaml", "*.yml", "*.toml", ".github/", "config/", "configs/"],
  "consolidator": ["*.md", "*.jsonl", "*.json", ".claude/ainous-roles/"],
  "researcher": ["*.md", ".claude/ainous-roles/researcher/", ".claude/ainous-roles/team-sync/artifacts/"],
  "signal": ["*.md", "*.json", ".claude/ainous-roles/signal/"],
  "authority": ["*.md", ".claude/ainous-roles/authority/"],
  "retriever": [],
  "coordinator": ["*.md", "*.json", "*.jsonl", "*.yaml", "*.yml", ".claude/", ".claude/ainous-roles/"],
  "designer": ["assets/", "design/", "styles/", ".claude/ainous-roles/team-sync/artifacts/", ".claude/ainous-roles/designer/"]
}
BASEEOF
    echo "  Generated baselines.json (Layer 1 authority enforcement)"
}
generate_baselines

# Ensure .claude/.gitignore exists and ignores scheduled_tasks.json.
# Durable crons write to <project>/.claude/scheduled_tasks.json — it contains
# per-session pid/runtime metadata that must never be committed to a shared repo.
# We use a SCOPED .claude/.gitignore (git honours gitignore files in subdirs) so
# we never need to touch the repo's root .gitignore.
_claude_dir="${PROJECT_ROOT}/.claude"
_scoped_gitignore="${_claude_dir}/.gitignore"
_gitignore_entry="scheduled_tasks.json"

if [ -d "$_claude_dir" ]; then
    if [ ! -f "$_scoped_gitignore" ]; then
        printf '%s\n' "$_gitignore_entry" > "$_scoped_gitignore"
        echo "  Created .claude/.gitignore (ignores scheduled_tasks.json)"
    elif ! grep -qF "$_gitignore_entry" "$_scoped_gitignore" 2>/dev/null; then
        printf '\n%s\n' "$_gitignore_entry" >> "$_scoped_gitignore"
        echo "  Appended scheduled_tasks.json to existing .claude/.gitignore"
    else
        echo "  .claude/.gitignore already lists scheduled_tasks.json — skipping"
    fi
fi


# Initialize git repo for universal knowledge tracking
if [ ! -d "$ROLES_DIR/.git" ]; then
    cd "$ROLES_DIR" && git init -q && git add */playbook.md */growth.json authority/authority-book.md authority/decisions.md authority/incident-response.md team-knowledge.md && git commit -q -m "Initial Ainous Team setup"
    echo "  Initialized git repo for knowledge tracking"
fi

# Set up global CLAUDE.md with coordinator-as-default identity (unless --agentmode)
GLOBAL_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
COORDINATOR_BLOCK="## You ARE the Coordinator"
if [ "$COORDINATOR_MODE" = false ]; then
    echo "  Skipping coordinator identity (--agentmode)"
elif [ ! -f "$GLOBAL_CLAUDE_MD" ]; then
    cat > "$GLOBAL_CLAUDE_MD" << 'MDEOF'
# Global Instructions

## You ARE the Coordinator

You operate as the coordinator of the ainous-team. This is your default identity — not a tool you invoke, but how you behave. On every session start, load:

1. `~/.claude/ainous-roles/coordinator/playbook.md` — your evolved strategies
2. `.claude/ainous-roles/coordinator/journal.md` — this project's history (if exists)
3. `~/.claude/ainous-roles/team-knowledge.md` — shared team knowledge

When the user gives you a task:
- **Plan** — break it into subtasks, assess which roles are needed
- **Delegate** — spawn role agents (@developer, @architect, @tester, etc.) via the Agent tool. Inject each role's playbook and project context.
- **Synthesize** — collect results, resolve conflicts, present unified output
- **Never implement directly** — delegate code/docs/tests to the appropriate role agent

You can skip the team for trivial tasks (quick questions, git operations, file reads). Use your judgment — but default to delegation over doing it yourself.
MDEOF
    echo "  Created global CLAUDE.md with coordinator identity"
elif ! grep -q "$COORDINATOR_BLOCK" "$GLOBAL_CLAUDE_MD" 2>/dev/null; then
    echo ""
    echo "  NOTE: Appending coordinator identity to existing ~/.claude/CLAUDE.md"
    echo "  To skip this, re-run with --agentmode"
    echo ""
    cat >> "$GLOBAL_CLAUDE_MD" << 'MDEOF'

## You ARE the Coordinator

You operate as the coordinator of the ainous-team. This is your default identity — not a tool you invoke, but how you behave. On every session start, load:

1. `~/.claude/ainous-roles/coordinator/playbook.md` — your evolved strategies
2. `.claude/ainous-roles/coordinator/journal.md` — this project's history (if exists)
3. `~/.claude/ainous-roles/team-knowledge.md` — shared team knowledge

When the user gives you a task:
- **Plan** — break it into subtasks, assess which roles are needed
- **Delegate** — spawn role agents (@developer, @architect, @tester, etc.) via the Agent tool. Inject each role's playbook and project context.
- **Synthesize** — collect results, resolve conflicts, present unified output
- **Never implement directly** — delegate code/docs/tests to the appropriate role agent

You can skip the team for trivial tasks (quick questions, git operations, file reads). Use your judgment — but default to delegation over doing it yourself.
MDEOF
    echo "  Appended coordinator identity to existing CLAUDE.md"
fi

echo ""
echo "Ainous Team initialized at $ROLES_DIR"
if [ "$COORDINATOR_MODE" = true ]; then
    echo "Claude Code will operate as the team coordinator by default."
    echo "  To disable: re-run with --agentmode, or remove the coordinator section from ~/.claude/CLAUDE.md"
else
    echo "Coordinator-as-default NOT installed. Invoke roles manually: @coordinator, @developer, etc."
fi
echo ""
echo "Commands: /team-status, /team-history, /team-alerts"
