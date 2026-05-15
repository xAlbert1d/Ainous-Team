#!/usr/bin/env bash
# migrate-legacy-provenance.sh — One-shot legacy provenance migration
#
# Walks the 6 persistent-memory surfaces and tags any entry that lacks a
# provenance block with:
#   source: legacy-unverified
#   session: pre-provenance
#   role: unknown
#   discovered: <file mtime ISO-8601 date>
#   verified: null
#
# Idempotent: entries already carrying a provenance block are left unchanged.
#
# Usage:
#   bash scripts/migrate-legacy-provenance.sh --dry-run    # show what would change
#   bash scripts/migrate-legacy-provenance.sh --execute    # apply changes
#
# Exit 0 on success; exit 1 on fatal error; exit 2 if no mode flag given.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOBAL_ROLES_DIR="$HOME/.claude/ainous-roles"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
DRY_RUN=false
EXECUTE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --execute) EXECUTE=true ;;
    esac
done

if ! $DRY_RUN && ! $EXECUTE; then
    echo "Usage: $0 [--dry-run | --execute]" >&2
    echo "  --dry-run   Show what would change without modifying files" >&2
    echo "  --execute   Apply legacy-unverified provenance tags to unsigned entries" >&2
    exit 2
fi

if $DRY_RUN && $EXECUTE; then
    echo "Error: specify either --dry-run or --execute, not both." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
MODE="DRY-RUN"
$EXECUTE && MODE="EXECUTE"

_log() { echo "[$MODE] $*"; }
_warn() { echo "[$MODE] WARN: $*" >&2; }

# Get file mtime as ISO-8601 date (YYYY-MM-DD)
_file_mtime_date() {
    local f="$1"
    if stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null; then
        return
    fi
    # GNU stat fallback
    if stat --format="%y" "$f" 2>/dev/null | cut -d' ' -f1; then
        return
    fi
    # Final fallback: today's date
    date +%Y-%m-%d
}

# Check if an .md file already has provenance frontmatter.
# Looks for all 5 required fields in the frontmatter block.
_md_has_provenance() {
    local f="$1"
    local content
    content=$(head -20 "$f" 2>/dev/null || true)
    # Must start with --- and contain all 5 fields
    if ! echo "$content" | grep -q '^---'; then
        return 1  # No frontmatter at all
    fi
    # Check presence of all 5 fields
    for field in role session source discovered verified; do
        if ! echo "$content" | grep -qE "^${field}:"; then
            return 1
        fi
    done
    return 0
}

# Check if a JSONL line already has provenance fields.
_jsonl_line_has_provenance() {
    local line="$1"
    if ! command -v python3 &>/dev/null; then
        # Naive grep fallback
        echo "$line" | grep -qE '"role"\s*:' && \
        echo "$line" | grep -qE '"session"\s*:' && \
        echo "$line" | grep -qE '"source"\s*:' && \
        echo "$line" | grep -qE '"discovered"\s*:' && \
        echo "$line" | grep -qE '"verified"\s*:'
        return
    fi
    python3 -c "
import sys, json
try:
    obj = json.loads(sys.stdin.readline())
    required = {'role','session','source','discovered','verified'}
    present = set(k for k in required if k in obj)
    sys.exit(0 if required.issubset(present) else 1)
except Exception:
    sys.exit(1)
" <<< "$line"
}

# Build the legacy provenance YAML frontmatter block for an .md file
_build_md_frontmatter() {
    local mtime_date="$1"
    printf -- '---\nrole: unknown\nsession: pre-provenance\nsource: legacy-unverified\ndiscovered: %s\nverified: null\n---\n' "$mtime_date"
}

# Build legacy provenance fields JSON fragment (merged into existing JSONL object)
_build_jsonl_provenance_fragment() {
    local mtime_date="$1"
    # Returns a partial JSON object string to be merged
    printf '{"role":"unknown","session":"pre-provenance","source":"legacy-unverified","discovered":"%s","verified":null}' "$mtime_date"
}

# ---------------------------------------------------------------------------
# Migration for .md files
# Prepend YAML frontmatter if the file doesn't already have valid provenance
# ---------------------------------------------------------------------------
_migrate_md_file() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return
    fi

    if _md_has_provenance "$f"; then
        _log "SKIP (already has provenance): $f"
        return
    fi

    local mtime_date
    mtime_date=$(_file_mtime_date "$f")
    local frontmatter
    frontmatter=$(_build_md_frontmatter "$mtime_date")

    _log "TAG  (legacy-unverified): $f"
    if $EXECUTE; then
        local tmpfile
        tmpfile=$(mktemp) || { _warn "mktemp failed for $f — skipping"; return; }
        {
            printf '%s' "$frontmatter"
            cat "$f"
        } > "$tmpfile"
        mv "$tmpfile" "$f"
    fi
}

# ---------------------------------------------------------------------------
# Migration for .jsonl files
# Each line is a JSON object. Lines already having all 5 provenance fields
# are left untouched. Lines without provenance get the 5 fields merged in.
# ---------------------------------------------------------------------------
_migrate_jsonl_file() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return
    fi

    local mtime_date
    mtime_date=$(_file_mtime_date "$f")
    local provenance_fragment
    provenance_fragment=$(_build_jsonl_provenance_fragment "$mtime_date")

    local any_changed=false
    local tmpfile
    tmpfile=$(mktemp) || { _warn "mktemp failed for $f — skipping"; return; }

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines
        if [ -z "${line// /}" ]; then
            printf '\n' >> "$tmpfile"
            continue
        fi

        if _jsonl_line_has_provenance "$line"; then
            # Already has provenance — keep as-is
            printf '%s\n' "$line" >> "$tmpfile"
        else
            any_changed=true
            _log "TAG  (legacy-unverified line in): $f"
            if $EXECUTE; then
                # Merge provenance fields into existing JSON object via Python
                # F10: pass $mtime_date as sys.argv[1] (not interpolated into the -c code string)
                # so that shell metacharacters in mtime_date are never evaluated as code.
                if command -v python3 &>/dev/null; then
                    local merged
                    merged=$(python3 -c '
import sys, json
mtime_date = sys.argv[1]
line = sys.stdin.readline()
try:
    obj = json.loads(line)
    frag = {
        "role": "unknown",
        "session": "pre-provenance",
        "source": "legacy-unverified",
        "discovered": mtime_date,
        "verified": None,
    }
    # Only add fields not already present (never overwrite existing fields)
    for k, v in frag.items():
        if k not in obj or obj[k] is None or str(obj[k]) == "":
            obj[k] = v
    print(json.dumps(obj, separators=(",",":")))
except Exception:
    # Can'"'"'t parse — emit original line unchanged
    sys.stdout.write(line)
' "$mtime_date" <<< "$line" 2>/dev/null || echo "$line")
                    printf '%s\n' "$merged" >> "$tmpfile"
                else
                    # Fallback: no python3, can't safely merge JSON — emit original
                    _warn "python3 not available; cannot merge provenance into $f — line left unchanged"
                    printf '%s\n' "$line" >> "$tmpfile"
                fi
            else
                # Dry-run: show what would be added
                printf '%s\n' "$line" >> "$tmpfile"
            fi
        fi
    done < "$f"

    if $EXECUTE && $any_changed; then
        mv "$tmpfile" "$f"
    else
        rm -f "$tmpfile"
    fi
}

# ---------------------------------------------------------------------------
# Discover and migrate all 6 surfaces
# ---------------------------------------------------------------------------
_log "Starting legacy provenance migration..."
_log "Global roles dir: $GLOBAL_ROLES_DIR"
_log "Project root: $PROJECT_ROOT"
echo ""

MIGRATED=0

# Surface 1 & 2: global playbooks and journals (per role)
if [ -d "$GLOBAL_ROLES_DIR" ]; then
    for role_dir in "$GLOBAL_ROLES_DIR"/*/; do
        role_name=$(basename "$role_dir")
        # Skip non-role directories
        case "$role_name" in
            authority|team-knowledge*|user-corrections*) ;;  # handled separately
        esac

        for surface_file in \
            "$role_dir/playbook.md" \
            "$role_dir/journal.md" \
            "$role_dir/learnings.jsonl"
        do
            if [ -f "$surface_file" ]; then
                case "$surface_file" in
                    *.md)    _migrate_md_file "$surface_file"; ((MIGRATED++)) || true ;;
                    *.jsonl) _migrate_jsonl_file "$surface_file"; ((MIGRATED++)) || true ;;
                esac
            fi
        done
    done
fi

# Surface 3: global team-knowledge.md
GLOBAL_TK="$GLOBAL_ROLES_DIR/team-knowledge.md"
if [ -f "$GLOBAL_TK" ]; then
    _migrate_md_file "$GLOBAL_TK"
    ((MIGRATED++)) || true
fi

# Surface 4: global user-corrections.md
GLOBAL_UC="$GLOBAL_ROLES_DIR/user-corrections.md"
if [ -f "$GLOBAL_UC" ]; then
    _migrate_md_file "$GLOBAL_UC"
    ((MIGRATED++)) || true
fi

# Surface 5: project team-knowledge.md
PROJECT_TK="$PROJECT_ROOT/.claude/ainous-roles/team-knowledge.md"
if [ -f "$PROJECT_TK" ]; then
    _migrate_md_file "$PROJECT_TK"
    ((MIGRATED++)) || true
fi

# Surface 6: project-level role journals (if they exist)
PROJECT_ROLES_DIR="$PROJECT_ROOT/.claude/ainous-roles"
if [ -d "$PROJECT_ROLES_DIR" ]; then
    for role_dir in "$PROJECT_ROLES_DIR"/*/; do
        for surface_file in \
            "$role_dir/journal.md" \
            "$role_dir/learnings.jsonl"
        do
            if [ -f "$surface_file" ]; then
                case "$surface_file" in
                    *.md)    _migrate_md_file "$surface_file"; ((MIGRATED++)) || true ;;
                    *.jsonl) _migrate_jsonl_file "$surface_file"; ((MIGRATED++)) || true ;;
                esac
            fi
        done
    done
fi

echo ""
if $DRY_RUN; then
    _log "Dry-run complete. $MIGRATED file(s) inspected. Run with --execute to apply changes."
else
    _log "Migration complete. $MIGRATED file(s) processed."
fi
