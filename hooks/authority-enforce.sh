#!/usr/bin/env bash
# authority-enforce.sh — Script-based PreToolUse enforcement (v3)
# Handles Write, Edit, AND Bash tools
# Exit 0 = allow, Exit 2 = block (message on stderr)
# Default: FAIL CLOSED — unknown states block rather than allow
set -uo pipefail
# NOTE: no -e flag — we handle errors explicitly to avoid false blocks

# Support per-pane role markers for tmux parallel mode
# Falls back to shared marker if no pane-specific one exists
if [ -n "${TMUX_PANE:-}" ] && [ -f "$HOME/.claude/.session-role-${TMUX_PANE}" ]; then
    ROLE_MARKER="$HOME/.claude/.session-role-${TMUX_PANE}"
else
    ROLE_MARKER="$HOME/.claude/.session-role"
fi
GROWTH_DIR="$HOME/.claude/ainous-roles"
DECISIONS_LOG="$GROWTH_DIR/authority/decisions.md"

# Read tool input from stdin — fail closed if no input
INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$INPUT" ]; then
    echo "BLOCKED: No tool input received. Cannot enforce." >&2
    exit 2
fi
TOOL_NAME="${TOOL_USE_NAME:-unknown}"

# Only enforce on Write, Edit, Bash, Read, WebFetch, WebSearch — allow everything else immediately
case "$TOOL_NAME" in
    Write|Edit|Bash|Read|WebFetch|WebSearch) ;;
    *) exit 0 ;;
esac

# Determine role — if no marker, treat as operator (main session — C1 fix)
if [ ! -f "$ROLE_MARKER" ]; then
    # C1: Main session has no role marker → operator role.
    # Operator flows through the full authorization path with a broad but
    # deny-list-guarded baseline (see OPERATOR_DENY_PATTERNS and JUNIOR_BASELINES).
    # Soft advisory is preserved as a NOTE for coordinator-as-default sessions.
    if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
        if [ -f "$HOME/.claude/CLAUDE.md" ] && grep -q "You ARE the Coordinator" "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
            echo "NOTE: You are operating as coordinator. Consider delegating this write to @developer instead of implementing directly." >&2
        fi
    fi
    ROLE="operator"
else
    ROLE=$(cat "$ROLE_MARKER" 2>/dev/null || echo "")
    if [ -z "$ROLE" ] || [ "$ROLE" = "unknown" ]; then
        ROLE="operator"
    fi
fi

# C4 fix: write large JSON payload to a temp file to avoid argv truncation
# R4: check mktemp exit status; register trap immediately after success
# F12: umask 077 so the tempfile is readable only by owner (mode 0600)
_SAVED_UMASK=$(umask)
umask 077
_INPUT_TMPFILE=$(mktemp /tmp/ae-input.XXXXXX) || { umask "$_SAVED_UMASK"; echo "BLOCKED: mktemp failed. Failing closed for safety." >&2; exit 2; }
umask "$_SAVED_UMASK"
trap 'rm -f "$_INPUT_TMPFILE"' EXIT INT TERM HUP
printf '%s' "$INPUT" > "$_INPUT_TMPFILE"

python3 - "$ROLE" "$TOOL_NAME" "$DECISIONS_LOG" "$GROWTH_DIR" "$_INPUT_TMPFILE" "${TMUX_PANE:-}" << 'PYEOF'
import sys, os, json, re, fnmatch, time
from datetime import datetime, date, timezone

role = sys.argv[1]
tool = sys.argv[2]
decisions_path = sys.argv[3]
growth_dir = sys.argv[4]
input_file = sys.argv[5] if len(sys.argv) > 5 else ""
tmux_pane = sys.argv[6] if len(sys.argv) > 6 else ""

# Read tool input from temp file (C4: avoids argv size ceiling)
try:
    with open(input_file, encoding='utf-8') as _f:
        raw_input = _f.read()
    tool_input = json.loads(raw_input) if raw_input.strip() else {}
except (FileNotFoundError, OSError):
    print(f"BLOCKED: {role} — cannot read tool input file for enforcement.", file=sys.stderr)
    sys.exit(2)
except UnicodeDecodeError as _ude:
    # R3: BOM-prefixed or malformed UTF-8 — explicit block with diagnostic
    print(f"BLOCKED: {role} — tool input file contains invalid UTF-8 (UnicodeDecodeError: {_ude}). Cannot enforce.", file=sys.stderr)
    sys.exit(2)
except (json.JSONDecodeError, ValueError):
    # Can't parse input — fail closed
    print(f"BLOCKED: {role} — cannot parse tool input for enforcement.", file=sys.stderr)
    sys.exit(2)

# Defensive dual-source session_id extraction (v5.6.2):
# Claude Code passes the full hook payload on stdin — try to extract session_id
# from payload.get("session_id") first, fall back to CLAUDE_SESSION_ID env var.
# If stdin is just the raw tool input (flat JSON), payload.get() returns "" safely.
try:
    _hook_payload = json.loads(raw_input) if raw_input.strip() else {}
except (json.JSONDecodeError, ValueError):
    _hook_payload = {}
_stdin_session_id = _hook_payload.get("session_id", "") if isinstance(_hook_payload, dict) else ""

# ---------------------------------------------------------------------------
# v5.9.0 (§15 mechanical enforcement): Team-mode teammate Write/Edit/NotebookEdit block
# Problem: v5.4.1 §15 policy says teammates must not call Write/Edit/NotebookEdit due
# to the upstream getAppState crash. Policy was normative-only; v5.8.0 audit crashed
# mid-flight when a teammate attempted a Write. This block provides mechanical enforcement.
#
# Detection (EMPIRICALLY VERIFIED 2026-04-19 via `strings claude-binary | grep -oE 'CLAUDE_[A-Z_]+'`):
#   CLAUDE_CODE_TEAMMATE_COMMAND — present in binary; set ONLY for actual team-mode teammates.
#     Coordinators (team-leads) do NOT get this var even when they are part of a team.
#     Agent subagents spawned without team_name do NOT get it. This is the positive signal.
#   CLAUDE_CODE_TEAM_NAME — present in binary; set for teammate AND coordinator in a team context.
#     Used as defense-in-depth alongside CLAUDE_CODE_TEAMMATE_COMMAND.
#   FABRICATED (not in binary, NEVER set by Claude Code):
#     CLAUDE_TEAM_NAME — was our invented name; causes silent dead-code in production (C1 bug)
#     CLAUDE_TEAM_ROLE — was our invented exemption marker; also never set
#
# Detection strategy: block if CLAUDE_CODE_TEAMMATE_COMMAND is set (non-empty).
# Defense-in-depth: also accept CLAUDE_CODE_TEAM_NAME as corroborating signal.
# Coordinators: do NOT have CLAUDE_CODE_TEAMMATE_COMMAND → pass through.
# Subagents (Agent without team_name): do NOT have CLAUDE_CODE_TEAMMATE_COMMAND → pass through.
#
# Blocked tools: Write, Edit, NotebookEdit. Bash filesystem-mutations blocked separately (v5.9.1 M-new-1).
# Read is NOT blocked (taint is output-side; reading is fine).
# ---------------------------------------------------------------------------
if tool in ("Write", "Edit", "NotebookEdit"):
    _teammate_command = os.environ.get("CLAUDE_CODE_TEAMMATE_COMMAND", "")
    _team_name_real = os.environ.get("CLAUDE_CODE_TEAM_NAME", "")
    # Primary signal: CLAUDE_CODE_TEAMMATE_COMMAND is set only for real team-mode teammates.
    # Defense-in-depth: block if both CLAUDE_CODE_TEAM_NAME is set AND CLAUDE_CODE_TEAMMATE_COMMAND.
    _is_teammate = bool(_teammate_command)
    if _is_teammate:
        print(
            f"[authority-enforce] TEAM_MATE_WRITE_DENY: Team-mode teammates must not call "
            f"{tool} directly (v5.4.1 §15 + upstream getAppState crash). "
            f"Return content via SendMessage envelope per runtime-charter §15.1 — "
            f"coordinator will recovery-write. "
            f"(CLAUDE_CODE_TEAMMATE_COMMAND={_teammate_command!r}; "
            f"CLAUDE_CODE_TEAM_NAME={_team_name_real!r}; role_marker={role!r})",
            file=sys.stderr
        )
        sys.exit(2)

# ---------------------------------------------------------------------------
# v5.9.3 (M-new-2): Team-mode teammate WebFetch/WebSearch block.
# Problem: WebFetch and WebSearch require human approval in default Claude Code
# permission configs. When a team-mode teammate calls either tool, Claude Code's
# approval-prompt machinery fires — specifically the permission explainer path
# (Tl7/Uf8 → w_().permissionExplainerEnabled → getAppState crash). The crash
# terminates the coordinator (team-lead) process, which may destroy the tmux
# session if the coordinator was the only pane.
#
# The PreToolUse hook exits 2 BEFORE Claude Code reaches the approval-prompt
# machinery, preventing the crash. Non-teammate contexts (coordinator, subagents)
# are unaffected — they do not have CLAUDE_CODE_TEAMMATE_COMMAND set.
#
# Protocol substitute: teammates that need web content must request the
# coordinator to perform WebFetch/WebSearch and relay results via mailbox.
#
# Detection: same CLAUDE_CODE_TEAMMATE_COMMAND signal used by Write/Edit block
# (empirically verified 2026-04-19 via `strings claude-binary | grep -oE 'CLAUDE_[A-Z_]+'`).
# ---------------------------------------------------------------------------
if tool in ("WebFetch", "WebSearch"):
    _wf_teammate_command = os.environ.get("CLAUDE_CODE_TEAMMATE_COMMAND", "")
    _wf_team_name_real = os.environ.get("CLAUDE_CODE_TEAM_NAME", "")
    _wf_is_teammate = bool(_wf_teammate_command)
    if _wf_is_teammate:
        print(
            f"[authority-enforce] TEAM_MATE_TOOL_DENY: Team-mode teammates must not call "
            f"{tool} directly (v5.4.1 §15 + upstream getAppState crash via permission-explainer path). "
            f"Request the coordinator to perform {tool} and relay results via mailbox. "
            f"(CLAUDE_CODE_TEAMMATE_COMMAND={_wf_teammate_command!r}; "
            f"CLAUDE_CODE_TEAM_NAME={_wf_team_name_real!r}; role_marker={role!r})",
            file=sys.stderr
        )
        sys.exit(2)
    # Non-teammate: exit immediately — WebFetch/WebSearch have no further
    # path-authority or provenance checks in this hook.
    sys.exit(0)

# ---------------------------------------------------------------------------
# Provenance validator (signed-provenance layer — v1)
# Fires ONLY on writes to the 6 scoped persistent-memory surfaces.
# Called after path-authority passes; orthogonal to authority layers.
# Exit 2 with clear message on any violation. Return None on pass.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Import shared provenance helpers — single source of truth (v5.7.2 B-1 fix).
# Fallback to inline definitions if CLAUDE_PLUGIN_ROOT is missing (defensive).
# Same import-with-fallback pattern as _hmac_common.py (v5.6.4).
# ---------------------------------------------------------------------------
_provenance_common_loaded = False
_plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
if _plugin_root:
    sys.path.insert(0, os.path.join(_plugin_root, "hooks"))
    try:
        from _provenance_common import (
            _PROVENANCE_PATTERNS,
            _REQUIRED_FIELDS,
            _VALID_SOURCE_TYPES,
            _is_provenance_surface,
            _extract_md_provenance,
            _validate_provenance_block,
        )
        _provenance_common_loaded = True
    except ImportError:
        pass

if not _provenance_common_loaded:
    # Fallback inline definitions — kept in sync with _provenance_common.py verbatim.
    # Deduplicated surface patterns (regex on resolved path, case-sensitive)
    _PROVENANCE_PATTERNS = [
        (r'\.claude/ainous-roles/[^/]+/playbook\.md$',    'md'),
        (r'\.claude/ainous-roles/team-knowledge\.md$',    'md'),
        (r'\.claude/ainous-roles/[^/]+/learnings\.jsonl$','jsonl'),
        (r'\.claude/ainous-roles/[^/]+/journal\.md$',     'md'),
        (r'\.claude/ainous-roles/user-corrections\.md$',  'md'),
        # M-3 (v5.2.0): declared named artifacts in team-sync/artifacts/ — schema-presence enforce
        # Covers exactly the 7 artifacts registered in agents/capabilities/artifacts/index.yaml.
        # Non-declared ad-hoc files in the same directory are intentionally not gated.
        (r'\.claude/ainous-roles/team-sync/artifacts/'
         r'(?:architect-design|researcher-findings|security-findings|code-quality-findings'
         r'|tester-plan|tester-results|signal-findings)[^/]*\.md$', 'md'),
        # Phase 2 (v5.3.0): taint-flags surface — defense-in-depth behind TAINT_FLAG_WRITE_DENY.
        # If the primary deny-list is ever relaxed, provenance validation still applies.
        (r'\.claude/ainous-roles/team-sync/state/taint-flags/[^/]+\.jsonl$', 'jsonl'),
    ]

    # Required provenance fields
    _REQUIRED_FIELDS = frozenset({'role', 'session', 'source', 'discovered', 'verified'})

    # Valid source_type enum (security §7 role-bound enum — v1 set)
    # Note: 'user-confirmed' retired (2026-04-17) — source was never emitted; user-level
    # signal flows via the user-corrections.md carrier (consolidator weights 3x).
    _VALID_SOURCE_TYPES = {
        'observed', 'self-described', 'inferred',
        'legacy-unverified', 'coordinator-spawn', 'role-self-report',
    }

    def _is_provenance_surface(resolved_path):
        """Return surface_type ('md'|'jsonl') if path is a provenance surface, else None."""
        for pattern, surface_type in _PROVENANCE_PATTERNS:
            if re.search(pattern, resolved_path):
                return surface_type
        return None

    def _extract_md_provenance(content):
        """Extract provenance dict from YAML frontmatter of an .md write.
        Returns dict or None if no frontmatter found."""
        m = re.match(r'^---\n(.*?)\n---(?:\n|$)', content, re.DOTALL)
        if not m:
            return None
        fm_text = m.group(1)
        result = {}
        for line in fm_text.splitlines():
            kv = re.match(r'^([\w_-]+):\s*(.*)', line)
            if kv:
                result[kv.group(1).strip()] = kv.group(2).strip()
        return result if result else None

    def _validate_provenance_block(prov):
        """Check all 5 required fields are present and source is valid. Returns (ok, reason)."""
        if not isinstance(prov, dict):
            return False, "provenance block is not a dict"
        missing = _REQUIRED_FIELDS - set(prov.keys())
        if missing:
            return False, f"missing provenance fields: {sorted(missing)}"
        source = prov.get('source', '')
        if source not in _VALID_SOURCE_TYPES:
            return False, f"invalid source type: {source!r}"
        return True, ""

# ---------------------------------------------------------------------------
# Phase 2 (v5.3.0): Taint flag file write deny-list (D-4)
# Hardcoded structural invariant — checked BEFORE baseline resolution.
# Role-initiated writes (Write/Edit/Bash) to this path are always rejected.
# The PostToolUse taint-flag hook writes via direct Python file I/O — not
# through the tool surface — so no escape hatch is needed or permitted here.
# @authority cannot grant exceptions to this constant.
# ---------------------------------------------------------------------------
_TAINT_FLAG_WRITE_DENY_RE = re.compile(
    r'\.claude/ainous-roles/team-sync/state/taint-flags/.*\.jsonl$'
)

# ---------------------------------------------------------------------------
# v5.3.1 (S-10): Nonce directory write deny-list
# Only the session-start hook writes nonces via direct file I/O — not through
# the tool surface. No role write to this directory is ever legitimate.
# @authority cannot grant exceptions to this constant.
# ---------------------------------------------------------------------------
_NONCE_DIR_WRITE_DENY_RE = re.compile(
    r'(^|/)\.claude/\.taint-nonces/'
)

# ---------------------------------------------------------------------------
# v5.8.1 (Item 2): task-history.jsonl write deny-list (TASK_HISTORY_WRITE_DENY)
# task-history.jsonl is an append-only audit log written exclusively by PostToolUse
# hooks (spawn-telemetry, skill-telemetry, write-proxy, taint-flag) and
# scripts/log-event.sh via direct shell '>>' or Python file I/O — not through
# the tool surface. Operator has .claude/ in its baseline → could forge spawn events
# → reaper reads forgery → cross-team DoS. Block all tool-surface writes.
# Legitimate writers (PostToolUse hooks, log-event.sh) bypass the tool surface entirely.
# @authority cannot grant exceptions to this constant.
# ---------------------------------------------------------------------------
_TASK_HISTORY_WRITE_DENY_RE = re.compile(
    r'\.claude/ainous-roles/team-sync/state/task-history\.jsonl$'
)

# WAL temp file suffix — provenance validation is skipped on temp files
_WAL_TEMP_RE = re.compile(r'\.(tmp|wal|partial|temp)\b', re.IGNORECASE)

# Role-bound source_type allow-lists (security §7)
_ROLE_SOURCE_ALLOWLIST = {
    'signal':      frozenset({'observed', 'inferred', 'legacy-unverified'}),
    'consolidator':frozenset({'inferred', 'coordinator-spawn', 'legacy-unverified',
                              'observed', 'self-described'}),
}
_DEFAULT_ALLOWED_SOURCES = frozenset(_VALID_SOURCE_TYPES)

# ISO-8601 date/datetime pattern (loose structural check)
_ISO8601_RE = re.compile(
    r'^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)?$'
)

def _extract_jsonl_provenance(content):
    """Extract provenance from first non-empty JSONL line. Returns dict or None."""
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                return obj
        except (json.JSONDecodeError, ValueError):
            return None
    return None

def _classify_existing_frontmatter(resolved_path):
    """Read the first 1 KB of the file at resolved_path and classify its frontmatter state.
    Returns:
      'valid'    — file exists and has parseable frontmatter with at least one key:value pair
      'malformed'— file exists, starts with '---', but frontmatter is not closed / has no key:value
      'none'     — file exists but has no frontmatter (does not start with '---\\n')
      'absent'   — file does not exist
    Fail-closed: any OS/IO error returns 'absent' (triggers Write-path validation).
    """
    try:
        with open(resolved_path, encoding='utf-8', errors='replace') as _f:
            head = _f.read(1024)
    except (FileNotFoundError, OSError):
        return 'absent'

    # For JSONL: check if first non-empty line is valid JSON with provenance fields
    if resolved_path.endswith('.jsonl'):
        for line in head.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if isinstance(obj, dict) and any(k in obj for k in _REQUIRED_FIELDS):
                    return 'valid'
                return 'malformed'
            except (json.JSONDecodeError, ValueError):
                return 'malformed'
        return 'none'

    # For MD: must start with '---\n'
    if not head.startswith('---\n'):
        return 'none'

    # Find closing '---'
    second_marker = head.find('\n---', 4)
    if second_marker == -1:
        return 'malformed'

    fm_text = head[4:second_marker]
    has_kv = any(re.match(r'^[\w_-]+:\s*', line) for line in fm_text.splitlines())
    return 'valid' if has_kv else 'malformed'

def _validate_provenance(resolved_path, tool_input_data, writing_role, tmux_pane_id):
    """Validate provenance on a write to a scoped surface.
    Exits 2 with a clear stderr message on any violation. Returns on success."""

    # WAL temp files: skip (validation fires on promoted final file)
    if _WAL_TEMP_RE.search(os.path.basename(resolved_path)):
        return

    surface_type = _is_provenance_surface(resolved_path)
    if surface_type is None:
        return  # Not a provenance surface

    # Extract content being written
    content = tool_input_data.get('content')
    if content is None:
        new_string = tool_input_data.get('new_string')
        if new_string is not None:
            # ---------------------------------------------------------------------------
            # Edit tool — v2 provenance gap fix (2026-04-17)
            # v1 let interior-content Edits pass through unconditionally (lines 229-231).
            # v2 inspects the target file's existing frontmatter state first:
            #   (a) File has valid frontmatter   → allow (v1 behavior preserved)
            #   (b) File has no frontmatter      → delegate to Write-path: validate new_string
            #   (c) File has malformed frontmatter → REJECT (don't propagate corruption)
            #   (d) File does not exist          → delegate to Write-path: validate new_string
            # Performance: read first 1 KB only — enough to locate both '---' boundaries.
            # ---------------------------------------------------------------------------
            if surface_type == 'md':
                existing_fm_state = _classify_existing_frontmatter(resolved_path)
                if existing_fm_state == 'valid':
                    # S-2 fix: fallback — reject Edit on provenance MD surfaces with valid
                    # frontmatter. upstream_chain injection requires full content (Write path);
                    # body-only Edits cannot carry the hook-authored chain in new_string alone.
                    # Role must use Write with full content including provenance frontmatter.
                    # Security accepted this as the correct fail-safe for the Edit bypass.
                    print(
                        f"[authority-enforce] taint validation failed: Edit tool is not permitted "
                        f"on provenance surface {resolved_path} when valid frontmatter already "
                        f"exists. Use Write with full content so the taint hook can inject "
                        f"upstream_chain into the frontmatter. (D-3 S-2 fail-safe)",
                        file=sys.stderr
                    )
                    sys.exit(2)
                elif existing_fm_state == 'malformed':
                    # (c) Existing frontmatter is corrupt — reject to prevent propagation
                    print(
                        f"[authority-enforce] provenance validation failed: {resolved_path} has malformed "
                        f"frontmatter. Edit rejected to prevent corruption propagation. "
                        f"Fix the frontmatter in a Write operation with valid provenance.",
                        file=sys.stderr
                    )
                    sys.exit(2)
                else:
                    # (b) No frontmatter, or (d) file does not exist — validate new_string
                    # new_string is treated as the canonical content for provenance purposes.
                    # Only the FIRST '---' block at the start of new_string counts as frontmatter
                    # (a '---' appearing later in the body is a markdown horizontal rule).
                    content = new_string
            elif surface_type == 'jsonl':
                # JSONL Edit: S-2 fix applies here too — Edit on valid existing JSONL bypassed D-3.
                # Reject Edit tool on provenance JSONL surfaces with valid existing records.
                # Role must use Write with full content so per-record upstream_chain can be injected.
                existing_fm_state = _classify_existing_frontmatter(resolved_path)
                if existing_fm_state == 'valid':
                    print(
                        f"[authority-enforce] taint validation failed: Edit tool is not permitted "
                        f"on provenance JSONL surface {resolved_path} when valid records already "
                        f"exist. Use Write with full JSONL content so the taint hook can inject "
                        f"upstream_chain into each record. (D-3 S-2 fail-safe)",
                        file=sys.stderr
                    )
                    sys.exit(2)
                elif existing_fm_state == 'malformed':
                    print(
                        f"[authority-enforce] provenance validation failed: {resolved_path} JSONL has "
                        f"malformed provenance in the existing record. Edit rejected.",
                        file=sys.stderr
                    )
                    sys.exit(2)
                else:
                    content = new_string
            else:
                # Unknown surface type — fail closed
                content = new_string
        else:
            print(
                f"[authority-enforce] provenance validation failed: cannot extract write content for {resolved_path}",
                file=sys.stderr
            )
            sys.exit(2)

    # ---------------------------------------------------------------------------
    # Phase 2 (v5.3.0) / v5.3.1 (S-6): taint-flags write deny (D-4 §2.3)
    # Unconditional: taint-flag hook writes via direct Python I/O, not the tool
    # surface. No escape hatch. Any tool-surface write here is always rejected.
    # ---------------------------------------------------------------------------
    if _TAINT_FLAG_WRITE_DENY_RE.search(resolved_path):
        # v5.3.1 (S-6): env-marker escape hatch removed. The taint-flag PostToolUse
        # hook writes via direct Python file I/O — not through the tool surface —
        # so TAINT_FLAG_HOOK=1 cannot legitimately reach this branch. Any tool-surface
        # write to taint-flags/ is always rejected, unconditionally.
        print(
            f"[authority-enforce] TAINT_FLAG_WRITE_DENY: writes to taint-flags/ are reserved "
            f"for the PostToolUse taint-flag hook (direct I/O). Tool-surface writes to "
            f"{resolved_path} are not permitted. (D-4 §2.3 — hardcoded invariant, no authority override)",
            file=sys.stderr
        )
        sys.exit(2)

    # Extract provenance block
    prov = None
    if surface_type == 'md':
        prov = _extract_md_provenance(content)
    elif surface_type == 'jsonl':
        prov = _extract_jsonl_provenance(content)

    if prov is None:
        print(
            f"[authority-enforce] provenance validation failed: no provenance block found in write to "
            f"{resolved_path}. All writes to persistent memory surfaces require a provenance block "
            f"with fields: {sorted(_REQUIRED_FIELDS)}",
            file=sys.stderr
        )
        sys.exit(2)

    # All 5 required fields must be present.
    # 'verified' may be None/null (meaning "not yet corroborated") — that is valid.
    # All other fields must be non-empty strings.
    _NULLABLE_FIELDS = frozenset({'verified'})
    def _field_present(field, val):
        if field in _NULLABLE_FIELDS:
            return field in prov  # present key, any value including None is ok
        return val is not None and str(val).strip() != ''
    missing = [f for f in _REQUIRED_FIELDS if not _field_present(f, prov.get(f))]
    if missing:
        print(
            f"[authority-enforce] provenance validation failed: missing required field(s) {sorted(missing)} "
            f"in write to {resolved_path}",
            file=sys.stderr
        )
        sys.exit(2)

    source_val   = str(prov.get('source',    '')).strip()
    prov_role    = str(prov.get('role',      '')).strip()
    prov_session = str(prov.get('session',   '')).strip()
    prov_disc    = str(prov.get('discovered','')).strip()
    # verified may be None (JSON null) — canonicalize to the string 'null' for validation
    _verified_raw = prov.get('verified')
    prov_ver = 'null' if _verified_raw is None else str(_verified_raw).strip()

    # Validate source_type is in the global enum
    if source_val not in _VALID_SOURCE_TYPES:
        print(
            f"[authority-enforce] provenance validation failed: invalid source type '{source_val}' in write to "
            f"{resolved_path}. Valid values: {sorted(_VALID_SOURCE_TYPES)}",
            file=sys.stderr
        )
        sys.exit(2)

    # Role-bound source_type check
    allowed_sources = _ROLE_SOURCE_ALLOWLIST.get(writing_role, _DEFAULT_ALLOWED_SOURCES)
    if source_val not in allowed_sources:
        print(
            f"[authority-enforce] provenance validation failed: role '{writing_role}' may not emit source "
            f"type '{source_val}'. Allowed: {sorted(allowed_sources)}",
            file=sys.stderr
        )
        sys.exit(2)

    # Provenance role field must match the session role marker
    if prov_role != writing_role:
        print(
            f"[authority-enforce] provenance validation failed: provenance role '{prov_role}' does not match "
            f"session role marker '{writing_role}' in write to {resolved_path}",
            file=sys.stderr
        )
        sys.exit(2)

    # discovered must be ISO-8601
    if not _ISO8601_RE.match(prov_disc):
        print(
            f"[authority-enforce] provenance validation failed: 'discovered' field '{prov_disc}' is not a valid "
            f"ISO-8601 date/datetime in write to {resolved_path}",
            file=sys.stderr
        )
        sys.exit(2)

    # verified must be ISO-8601 or literal 'null'
    if prov_ver.lower() != 'null' and not _ISO8601_RE.match(prov_ver):
        print(
            f"[authority-enforce] provenance validation failed: 'verified' field '{prov_ver}' must be an "
            f"ISO-8601 date/datetime or 'null' in write to {resolved_path}",
            file=sys.stderr
        )
        sys.exit(2)

    # ---------------------------------------------------------------------------
    # Phase 2 (v5.3.0): _validate_taint_field — invoke after _REQUIRED_FIELDS check
    # on the 12 provenance-gated surfaces (taint-flags surface handled above by
    # early-return in append-only block).
    # Auto-injects upstream_chain; rejects role-supplied upstream_chain.
    # Mutates the write payload via hookSpecificOutput.updatedInput (D-3).
    # For Edit tool: updatedInput uses new_string key (not content).
    # ---------------------------------------------------------------------------
    injected_content, chain = _validate_taint_field(resolved_path, tool_input_data, content)
    if injected_content != content:
        # Emit updated payload so the injected upstream_chain reaches disk.
        # Edit tool: the runtime expects new_string in updatedInput, not content.
        is_edit_tool = tool_input_data.get('new_string') is not None and tool_input_data.get('content') is None
        if is_edit_tool:
            updated_input = dict(tool_input_data, new_string=injected_content)
        else:
            updated_input = dict(tool_input_data, content=injected_content)
        output = {
            "hookSpecificOutput": {
                "permissionDecision": "allow",
                "updatedInput": updated_input,
            }
        }
        print(json.dumps(output))

    # All checks passed — provenance is valid
    return

def _authority_allow(resolved_path, tool_input_data, writing_role, tmux_pane_id):
    """Gate after path-authority passes: run provenance validation, then exit 0."""
    _validate_provenance(resolved_path, tool_input_data, writing_role, tmux_pane_id)
    sys.exit(0)

# ---------------------------------------------------------------------------
# v5.8.0 (C-2): _session_is_tainted — Scope-reduction-on-taint predicate
# Returns True if the taint-flag file for the current session exists AND has
# at least one record (i.e., a WebFetch/WebSearch was performed this session).
# Reuses the same path construction as _validate_taint_field (sha256(sid||nonce)).
# Fail-open: if session_id or nonce cannot be resolved, returns False so that
# normal enforcement applies (taint restriction is an additional constraint, not
# the primary gate — fail-closed is already enforced by the credential deny-list).
# ---------------------------------------------------------------------------
def _session_is_tainted(session_id):
    """Return True if the current session has a non-empty taint-flag file."""
    import hashlib as _hashlib
    if not session_id:
        return False
    nonce_dir = os.path.expanduser('~/.claude/.taint-nonces')
    hashed_sid_for_nonce = _hashlib.sha256(session_id.encode()).hexdigest()
    nonce_file = os.path.join(nonce_dir, f"{hashed_sid_for_nonce}.nonce")
    try:
        with open(nonce_file, 'rb') as _nf:
            nonce_bytes = _nf.read()
        if not nonce_bytes:
            return False
    except (FileNotFoundError, PermissionError, OSError):
        return False  # Nonce unavailable — treat as untainted (fail-open for taint gate)
    combined = session_id.encode() + nonce_bytes
    hashed_filename = _hashlib.sha256(combined).hexdigest()
    project_root = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    flags_dir = os.path.join(project_root, '.claude', 'ainous-roles', 'team-sync', 'state', 'taint-flags')
    flag_path = os.path.join(flags_dir, f"{hashed_filename}.jsonl")
    if not os.path.isfile(flag_path):
        return False
    try:
        with open(flag_path, encoding='utf-8') as _fp:
            for line in _fp:
                if line.strip():
                    return True  # At least one non-empty record
        return False  # File exists but is empty
    except (OSError, PermissionError):
        return False  # Unreadable — treat as untainted (fail-open for taint gate)

# ---------------------------------------------------------------------------
# Phase 2 (v5.3.0): _validate_taint_field — D-3 auto-injection predicate
# Called by _validate_provenance after _REQUIRED_FIELDS check on provenance
# surfaces. Auto-injects upstream_chain into the write payload via
# hookSpecificOutput.updatedInput. Role-supplied upstream_chain is rejected.
# Fail-closed on missing session_id, unreadable nonce, or malformed flag records.
# ---------------------------------------------------------------------------
def _validate_taint_field(resolved_path, tool_input_data, content):
    """Validate and auto-inject upstream_chain into a provenance surface write.

    Branches on surface type:
      - MD:    parse YAML frontmatter, reject role-supplied upstream_chain, inject into frontmatter.
      - JSONL: parse each line as JSON, reject per-record upstream_chain, inject into each record.

    Returns (injected_content, upstream_chain_list).
    On hard failure (missing session_id, unreadable nonce, IO error), calls sys.exit(2) — fail-closed.
    On empty/missing flag file, injects upstream_chain=[] into every record (write is clean).
    """
    import hashlib as _hashlib

    # Detect surface type from path
    surface_type_for_taint = None
    for pat, st in _PROVENANCE_PATTERNS:
        if re.search(pat, resolved_path):
            surface_type_for_taint = st
            break
    # Default to md for unknown surfaces (pre-existing behavior)
    if surface_type_for_taint is None:
        surface_type_for_taint = 'md'

    # ---------------------------------------------------------------------------
    # MD surface: YAML-frontmatter branch (existing logic preserved)
    # ---------------------------------------------------------------------------
    if surface_type_for_taint == 'md':
        # Parse frontmatter to detect role-supplied upstream_chain (D-3 reject)
        fm = re.match(r'^---\n(.*?)\n---(?:\n|$)', content, re.DOTALL)
        if fm:
            fm_text = fm.group(1)
            fm_fields = {}
            for line in fm_text.splitlines():
                kv = re.match(r'^([\w_-]+):\s*(.*)', line)
                if kv:
                    fm_fields[kv.group(1).strip()] = kv.group(2).strip()
            if 'upstream_chain' in fm_fields:
                print(
                    f"[authority-enforce] taint validation failed: 'upstream_chain' is hook-injected; "
                    f"role must not supply it in write to {resolved_path}. (D-3)",
                    file=sys.stderr
                )
                sys.exit(2)

    # ---------------------------------------------------------------------------
    # JSONL surface: per-record branch (S-1 fix)
    # Parse each non-empty line as JSON. Fail-closed on malformed lines.
    # Reject any record that contains upstream_chain (D-3 role-supplied chain rule).
    # ---------------------------------------------------------------------------
    elif surface_type_for_taint == 'jsonl':
        for raw_line in content.splitlines():
            raw_line_stripped = raw_line.strip()
            if not raw_line_stripped:
                continue
            try:
                rec = json.loads(raw_line_stripped)
            except (json.JSONDecodeError, ValueError):
                print(
                    f"[authority-enforce] taint validation failed: JSONL surface {resolved_path} "
                    f"contains a line that is not valid JSON. Cannot enforce taint integrity. (fail-closed)",
                    file=sys.stderr
                )
                sys.exit(2)
            if not isinstance(rec, dict):
                print(
                    f"[authority-enforce] taint validation failed: JSONL surface {resolved_path} "
                    f"contains a non-object JSON line. Expected dict per line. (fail-closed)",
                    file=sys.stderr
                )
                sys.exit(2)
            if 'upstream_chain' in rec:
                print(
                    f"[authority-enforce] taint validation failed: 'upstream_chain' is hook-injected; "
                    f"role must not supply it in JSONL record in {resolved_path}. (D-3)",
                    file=sys.stderr
                )
                sys.exit(2)

    # Resolve session_id — stdin payload first (v5.6.2), env fallback
    sid = _stdin_session_id or os.environ.get('CLAUDE_SESSION_ID', '')
    if not sid:
        print(
            f"[authority-enforce] taint validation failed: CLAUDE_SESSION_ID not set; "
            f"taint state unknown for write to {resolved_path}. (fail-closed)",
            file=sys.stderr
        )
        sys.exit(2)

    # Locate nonce file (sha256(sid) used as nonce filename for path resolution)
    nonce_dir = os.path.expanduser('~/.claude/.taint-nonces')
    hashed_sid_for_nonce = _hashlib.sha256(sid.encode()).hexdigest()
    nonce_file = os.path.join(nonce_dir, f"{hashed_sid_for_nonce}.nonce")
    try:
        with open(nonce_file, 'rb') as _nf:
            nonce_bytes = _nf.read()
        if not nonce_bytes:
            raise OSError("nonce file is empty")
    except (FileNotFoundError, PermissionError, OSError) as exc:
        print(
            f"[authority-enforce] taint validation failed: cannot read nonce file "
            f"{nonce_file}: {exc}. Taint state unknown for write to {resolved_path}. (fail-closed)",
            file=sys.stderr
        )
        sys.exit(2)

    # Compute hashed flag filename: sha256(session_id || nonce_bytes)
    combined = sid.encode() + nonce_bytes
    hashed_filename = _hashlib.sha256(combined).hexdigest()

    # Locate flag file — prefer CLAUDE_PROJECT_DIR to handle subdirectory invocations (v5.7.0)
    project_root = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    flags_dir = os.path.join(project_root, '.claude', 'ainous-roles', 'team-sync', 'state', 'taint-flags')
    flag_path = os.path.join(flags_dir, f"{hashed_filename}.jsonl")

    # Read flag records (empty/missing → upstream_chain: [])
    chain = []
    if os.path.isfile(flag_path):
        try:
            with open(flag_path, encoding='utf-8') as _fp:
                for line in _fp:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                        if isinstance(rec, dict) and 'url' in rec:
                            chain.append({
                                "url":          rec["url"],
                                "content_hash": rec.get("content_hash", ""),
                                "fetched_at":   rec.get("ts", ""),
                            })
                    except (json.JSONDecodeError, ValueError):
                        # Malformed record — fail-closed
                        print(
                            f"[authority-enforce] taint validation failed: malformed record in "
                            f"{flag_path}. Cannot synthesize chain for write to {resolved_path}. (fail-closed)",
                            file=sys.stderr
                        )
                        sys.exit(2)
        except (PermissionError, OSError) as exc:
            print(
                f"[authority-enforce] taint validation failed: cannot read flag file "
                f"{flag_path}: {exc}. (fail-closed)",
                file=sys.stderr
            )
            sys.exit(2)

    # ---------------------------------------------------------------------------
    # Injection: surface-type-specific re-serialization
    # ---------------------------------------------------------------------------

    # MD surface: inject upstream_chain into YAML frontmatter
    if surface_type_for_taint == 'md':
        chain_yaml = json.dumps(chain, separators=(',', ':'))
        injected_content = re.sub(
            r'^(---\n)',
            f'---\nupstream_chain: {chain_yaml}\n',
            content,
            count=1
        )
        if injected_content == content:
            # No frontmatter opening found — leave unchanged; provenance check will catch missing fm
            injected_content = content
        return injected_content, chain

    # JSONL surface (S-1 fix): inject upstream_chain field into each record, re-serialize
    # Records are re-emitted one per line preserving order; blank lines are dropped.
    elif surface_type_for_taint == 'jsonl':
        output_lines = []
        for raw_line in content.splitlines():
            raw_line_stripped = raw_line.strip()
            if not raw_line_stripped:
                continue
            try:
                rec = json.loads(raw_line_stripped)
            except (json.JSONDecodeError, ValueError):
                # Already validated above — this path should not be reached
                print(
                    f"[authority-enforce] taint validation failed: unexpected JSON parse error "
                    f"during injection in {resolved_path}. (fail-closed)",
                    file=sys.stderr
                )
                sys.exit(2)
            rec['upstream_chain'] = chain
            output_lines.append(json.dumps(rec, separators=(',', ':')))
        injected_content = '\n'.join(output_lines)
        if output_lines:
            injected_content += '\n'
        return injected_content, chain

    # v5.3.1 (S-8): reaching here is a code-path bug — surface_type_for_taint should
    # always be 'md' or 'jsonl' by this point. Fail-closed rather than silently passing
    # unvalidated content.
    print(
        f"[authority-enforce] _validate_taint_field: unexpected code path reached for "
        f"{resolved_path} (surface_type={surface_type_for_taint!r}). (fail-closed)",
        file=sys.stderr
    )
    sys.exit(2)

# --- Helper: detect overly broad glob patterns ---
# Rule: reject if pattern has leading **, is a single-component glob (src/*),
# lacks any meaningful path component (*/*), or is a bare extension glob (*.ts).
# Accept patterns with at least 2 meaningful components (src/auth/*, hooks/*.sh).
# "Meaningful" = not purely "*" or "**" (so "*.sh" counts — it carries extension specificity).
#
# C3 additions: also reject —
#   - Patterns with no '/' separator (bare basenames like 'passwd', '*.env')
#   - Patterns shorter than 4 chars (too permissive as bare names)
#   - Single-component wildcards ('**', '*', '*.*')
def _is_overly_broad(pattern):
    if not pattern:
        return True
    # Exact broad sentinels (also covers single-component wildcards)
    if pattern in ("*", "**", "**/*", "**/**", "*.*"):
        return True
    # C3: patterns shorter than 4 chars are too permissive as basenames
    if len(pattern) < 4:
        return True
    # C3: patterns with no '/' separator are bare basenames (e.g. 'passwd', '*.env')
    if '/' not in pattern:
        return True
    # Bare extension globs: *.ext (no slash, starts with *)
    if re.match(r'^\*\.\w+$', pattern):
        return True
    # Leading **: **/anything
    if pattern.startswith("**/"):
        return True
    # Require at least 2 meaningful path components — parts that are not purely
    # "*" or "**" (bare glob-all wildcards). "*.sh" is meaningful; "*" is not.
    parts = pattern.split("/")
    meaningful = [p for p in parts if p and p not in ("*", "**")]
    if len(meaningful) < 2:
        return True
    return False

# ---------------------------------------------------------------------------
# JUNIOR_BASELINES + SENIOR_EXPANSIONS — defined here and referenced at Layer-3.
# ---------------------------------------------------------------------------
# Junior: strict baselines matching authority-book.md
JUNIOR_BASELINES = {
    "coordinator": [],  # Coordinator is read-only + Agent; enforce like other roles
    "developer": ["src/", "lib/", "app/", "pkg/", "scripts/"],
    "architect": ["design", "spec", "artifacts"],  # v5.9.2 B-1: team-sync/artifacts/*.md
    "code-quality": [],
    "tester": ["test", "spec"],
    "researcher": ["research", "journal", "notes", "artifacts"],  # v5.9.2 B-1
    "writer": ["docs/", "readme", "artifacts"],  # v5.9.2 B-1
    "security": ["security", "journal", "report", "artifacts"],  # v5.9.2 B-1
    "authority": ["authority-book", "decisions", "journal", "incident"],
    "consolidator": ["playbook", "growth.json", "journal", "memory", "cross-role"],
    "signal": ["signal", "journal", "team-knowledge", "artifacts"],  # v5.9.2 B-1
    "retriever": [],
    # C1: operator = human CLI operator. Broad project access; credential/system deny-list
    # applied earlier (OPERATOR_DENY_PATTERNS). NOT granted write to persistent-memory
    # surfaces directly — provenance validator gates those independently.
    # Developer TODO #3: operator has no journal/memory directories — skip own_paths
    # generation for operator to prevent phantom allow (see own_paths block below).
    "operator": [
        ".claude/", "src/", "lib/", "scripts/", "hooks/", "agents/",
        "agents-instructions/", "skills/", "tests/", "docs/", "templates/",
        "README", "readme",
    ],  # v5.9.4 M-new-3: "app/" entry removed — pm-client moved to ainous-team/pm-client/ outside plugin package
}

# Senior: expanded baselines (adjacent areas)
SENIOR_EXPANSIONS = {
    "developer": ["config", "scripts/", "docs/"],  # Can touch config and docs too
    "architect": ["src/", "lib/"],       # Can write implementation stubs
    "tester": ["fixtures/", "mocks/"],    # Can modify test infrastructure
    "writer": ["comment", "changelog"],    # Can modify code comments
    "security": ["config", ".gitignore"],  # Can modify security configs
    "signal": ["subscriptions", "memory"],  # Can manage own subscriptions
}

# --- C3/F5: Self-scope-check helper for Layer-2 ---
# Log-writer roles: roles whose baselines include *.jsonl, .claude/, or ainous-roles.
# Returns True if the given scope pattern would match something these roles can
# legitimately write — preventing self-bootstrap escalation via forged spawn events.
#
# --- Protected paths: always deny, no exceptions ---
PROTECTED_PATHS = [
    os.path.expanduser("~/.claude/.session-role"),
    os.path.expanduser("~/.claude/.session-anchor"),
]
# Also protect per-pane role markers and per-session anchor variants
import glob as _glob
for _p in _glob.glob(os.path.expanduser("~/.claude/.session-role-*")):
    PROTECTED_PATHS.append(_p)
for _p in _glob.glob(os.path.expanduser("~/.claude/.session-anchor-*")):
    PROTECTED_PATHS.append(_p)

# ---------------------------------------------------------------------------
# H1: Structural session-marker protection
# The PROTECTED_PATHS glob snapshot above only catches markers that exist at
# startup.  A role with .claude/ in its baseline can CREATE a new marker file
# (e.g. ~/.claude/.session-role-ATTACKER) that was never in the snapshot, and
# the hook would allow the write.
#
# Fix: reject ANY path whose basename starts with ".session-role" or
# ".session-anchor" AND whose parent directory is ~/.claude — checked on BOTH
# the raw input path AND the realpath-resolved form, so symlink tricks don't
# bypass.  Applies to ALL roles including operator.
# ---------------------------------------------------------------------------
_CLAUDE_DIR_REAL = os.path.realpath(os.path.expanduser("~/.claude"))
_SESSION_MARKER_PREFIXES = (".session-role", ".session-anchor")

def _is_structural_session_marker(raw_path):
    """Return True if raw_path (or its realpath target) is structurally a
    session-role/anchor marker — i.e. lives in ~/.claude and its basename
    starts with .session-role or .session-anchor.

    Checked on BOTH the raw (pre-resolution) path AND the realpath form so
    that a symlink whose target is a marker is also blocked, and so that a
    path whose BASENAME matches the prefix is blocked even when the symlink
    target has a different name.
    """
    for check_path in (raw_path, os.path.realpath(os.path.expanduser(raw_path))):
        try:
            parent = os.path.realpath(os.path.dirname(os.path.expanduser(check_path)))
            basename = os.path.basename(check_path)
        except (OSError, ValueError):
            continue
        if parent == _CLAUDE_DIR_REAL and any(basename.lower().startswith(pfx) for pfx in _SESSION_MARKER_PREFIXES):
            return True
    return False

# ---------------------------------------------------------------------------
# H-new-2: Credential deny-list for SRC path checks in cp/mv
# Applied to ALL roles — a compromised role must not exfiltrate secrets.
# Subset of OPERATOR_DENY_PATTERNS: credential paths only (not system paths,
# not project-specific entries that only make sense for operator writes).
# ---------------------------------------------------------------------------
_CREDENTIAL_DENY_PATTERNS = [
    r'(^|/)\.env($|[^/])',
    r'\.key$',
    r'\.pem$',
    r'\.p12$',
    r'\.pfx$',
    r'\.jks$',
    r'\.keystore$',
    r'(^|/)id_rsa($|[\._])',
    r'(^|/)id_ed25519($|[\._])',
    r'(^|/)\.htpasswd$',
    r'(^|/)credentials(\.|$)',
    r'(^|/)secrets(\.|$)',
    r'token\.json$',
    r'(^|/)\.ssh(/|$)',
    r'(^|/)\.aws(/|$)',
    r'(^|/)\.gnupg(/|$)',
    r'(^|/)\.kube(/|$)',
    r'(^|/)\.docker(/|$)',
    r'(^|/)\.netrc$',
    r'(^|/)\.npmrc$',
    r'(^|/)\.pypirc$',
    r'(^|/)\.gitconfig$',
    r'(^|/)\.git/config$',
    r'(^|/)authorized_keys$',
    r'(^|/)known_hosts$',
    # Phase 2 (v5.3.0): taint nonce files — unreadable by role tool surfaces (D-5)
    # CRITICAL-1 fix (v5.7.1): second pattern anchor changed from $ to (/|$|\s) so it
    # matches when the nonce path appears mid-command, not only at end-of-string.
    # Round-3 fix (v5.7.2): widened anchor to lookahead (?=[/\s;)"'&|<>]|$) to cover
    # shell metacharacters (;, ), quotes, &, |, <, >) that the previous (/|$|\s) missed.
    r'(^|/)\.taint-nonces(/|$)',
    r'(^|/)\.taint-nonces/.*\.nonce(?=[/\s;)"\'&|<>]|$)',
    # v5.5.1: write-proxy nonce files — not exfiltrable via Bash egress (mirrors taint-nonce entry above)
    # CRITICAL-1 fix (v5.7.1): changed anchor from $ to (/|$|\s) so the pattern matches when
    # the nonce path appears mid-command (e.g., "cat ~/.claude/teams/t/nonces/m.nonce | base64")
    # Round-3 fix (v5.7.2): widened to lookahead covering shell metacharacters (;, ), &, |, <, >).
    r'\.claude/teams/[^/]+/nonces/[^/]+\.nonce(?=[/\s;)"\'&|<>]|$)',
    # v5.8.1 (Item 3): tainted-decisions audit log — blocks Read and Bash egress.
    # The log records adversary-controlled command data (sha256 now, but path may still
    # leak session context). Block Read to prevent cross-session smuggling channel.
    r'(^|[\s/])\.authority-tainted-decisions\.log(?=[/\s;)"\'&|<>]|$)',
]

def _src_deny_check(path):
    """H-new-2: Return True if source path matches the credential deny-list.
    Applies to ALL roles to prevent exfiltration of secrets via cp/mv SRC."""
    try:
        resolved_src = os.path.realpath(os.path.expanduser(path))
    except (OSError, ValueError):
        resolved_src = path
    for _dp in _CREDENTIAL_DENY_PATTERNS:
        if re.search(_dp, resolved_src, re.IGNORECASE):
            return True
    return False

def _scan_command_for_credential_egress(command_str, is_tainted=False):
    """H-new-3: Block if command mentions a credential deny-path AND produces output.
    Covers cat/dd/tee/gpg/base64/head/tail/xxd/od/strings/openssl/... any tool
    that can read a secret and any channel that emits bytes (>, >>, |, of=, -out).

    CRITICAL-1 fix (v5.7.1): For high-sensitivity secret paths (nonce files and
    taint-nonce files), ANY mention in a Bash command is treated as inherently egress —
    even a bare `cat` without redirect. For LLM roles, stdout IS egress: the value
    lands in the model context window and is accessible to the role.

    v5.8.1 (Item 1): When is_tainted=True, the has_egress fast-exit is skipped.
    Any credential path mention in a tainted-session command is blocked regardless
    of redirect — because the taint-safe allowlist (cat, grep, etc.) would otherwise
    allow reading credential files whose output goes to the LLM context window.

    Placement: BEFORE the allowlist check — cat is in the allowlist; the check
    must fire here or cat ~/.ssh/id_rsa > src/x would be allowed.

    False-positive: pipe-based inspection of credential files, e.g.
        cat ~/.ssh/authorized_keys | grep ed25519
    is BLOCKED because it has both a credential path and a pipe.
    Workaround: grep ed25519 ~/.ssh/authorized_keys  (no pipe → no egress → allowed).
    The block message documents this workaround.

    Security tax: | inside a quoted string ("a|b") is matched as a pipe.
    Same regex-can't-parse-quoting tax accepted for & (background detection).
    Do not add quote-aware parsing here; use a real shell parser if needed.

    Returns (blocked: bool, reason: str).
    """
    # CRITICAL-1 fix (v5.7.1): nonce files and taint-nonce files are unconditionally
    # blocked in any Bash command — no redirect/pipe required. stdout to LLM = exfil.
    # Round-3 fix (v5.7.2): widened trailing anchor from (/|$|\s) to lookahead
    # (?=[/\s;)"'&|<>]|$) to block shell metacharacter separators (;, ), &, |, <, >)
    # that the previous anchor missed (e.g., "cat nonce.nonce; echo done" was exit 0).
    # v5.8.1 (Item 1): Extended unconditional secret patterns.
    # All credential paths here are blocked in ANY Bash command — no redirect/pipe required.
    # For LLM roles, stdout IS egress: the value lands in the model context window.
    # Includes: nonce files (pre-existing), SSH keys, AWS creds, .env, system credential
    # files, and other secrets that must never appear in command output.
    _UNCONDITIONAL_SECRET_PATTERNS = [
        # Nonce files and directories (pre-existing — CRITICAL-1 fix v5.7.1/v5.7.2)
        r'(^|[\s/])\.taint-nonces(/|$|\s)',
        r'\.taint-nonces/[^/]*\.nonce(?=[/\s;)"\'&|<>]|$)',
        r'\.claude/teams/[^/]+/nonces/[^/]+\.nonce(?=[/\s;)"\'&|<>]|$)',
        # v5.8.1: also block directory-level access to nonces/ (e.g. ls .claude/teams/X/nonces/)
        r'\.claude/teams/[^/]+/nonces(?:[/\s;)"\'&|<>]|$)',
        # SSH private keys
        r'(^|[\s/])\.ssh/id_rsa(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])\.ssh/id_ed25519(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])\.ssh/(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])id_rsa(?=[/\s;)"\'&|<>._]|$)',
        r'(^|[\s/])id_ed25519(?=[/\s;)"\'&|<>._]|$)',
        # AWS credentials
        r'(^|[\s/])\.aws/credentials(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])\.aws/(?=[/\s;)"\'&|<>]|$)',
        # Environment files — block .env only when it is the literal filename, not extensions
        # like .env.example, .env.sample, .env.template, .env.dist, .envrc (direnv config).
        # Negative lookahead (?![\w.-]) ensures we do NOT block .env.example etc.
        # (v5.8.2 Item 1: DX fix — .env.example and .envrc were falsely blocked before)
        r'(?:^|[/\s])\.env(?![\w.-])',
        # Key/cert material — gated behind credential-context directory signal (v5.8.2 Item 2)
        # .key, .pem, .cert, .crt are blocked ONLY when the path contains a known credential dir
        # (~/  /home/  .ssh/  .aws/  /keys/  /secrets/  /etc/  /private/).
        # .p12, .pfx, .jks, .keystore remain unconditional (always credential materials).
        r'(?:~/|/home/[^/\s]+/|\.ssh/|\.aws/|/keys/|/secrets/|/etc/|/private/)[^\s]*\.key(?=[/\s;)"\'&|<>]|$)',
        r'(?:~/|/home/[^/\s]+/|\.ssh/|\.aws/|/keys/|/secrets/|/etc/|/private/)[^\s]*\.pem(?=[/\s;)"\'&|<>]|$)',
        r'(?:~/|/home/[^/\s]+/|\.ssh/|\.aws/|/keys/|/secrets/|/etc/|/private/)[^\s]*\.cert(?=[/\s;)"\'&|<>]|$)',
        r'(?:~/|/home/[^/\s]+/|\.ssh/|\.aws/|/keys/|/secrets/|/etc/|/private/)[^\s]*\.crt(?=[/\s;)"\'&|<>]|$)',
        r'\.p12(?=[/\s;)"\'&|<>]|$)',
        r'\.pfx(?=[/\s;)"\'&|<>]|$)',
        r'\.jks(?=[/\s;)"\'&|<>]|$)',
        r'\.keystore(?=[/\s;)"\'&|<>]|$)',
        # Auth files
        r'(^|[\s/])\.htpasswd(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])authorized_keys(?=[/\s;)"\'&|<>]|$)',
        # System credential files
        r'(^|[\s/])etc/passwd(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])etc/shadow(?=[/\s;)"\'&|<>]|$)',
        r'(^|[\s/])etc/sudoers(?=[/\s;)"\'&|<>]|$)',
    ]
    for _pat in _UNCONDITIONAL_SECRET_PATTERNS:
        if re.search(_pat, command_str, re.IGNORECASE):
            return (True, f"{_pat} [unconditional — credential path in command, stdout=exfil for LLM roles]")

    # Round-3 fix (v5.7.2): variable indirection defense.
    # Regex cannot trace variable substitution at runtime, but we can detect the
    # assignment of a credential path to any variable name: VAR=<cred-path>.
    # If a role assigns a credential/nonce path to a variable, block immediately —
    # the assignment itself is the preparation for an exfil that follows.
    # v5.8.2 (Item 6): Extend to cover the full credential set mirroring
    # _UNCONDITIONAL_SECRET_PATTERNS. Covers export, declare, readonly, typeset,
    # and array-index assignment in addition to bare VAR= assignment.
    # Assignment forms matched: VAR=, export VAR=, declare [-x] VAR=, readonly VAR=,
    # typeset VAR=, arr=(<path>).
    _CRED_ASSIGN_PREFIX = r'(?:(?:export|declare|readonly|typeset)\s+(?:-\w+\s+)?)?(?:\w+)=\s*[\'"]?[^\s\'"]*'
    _CRED_ASSIGN_ARRAY  = r'(?:\w+)=\s*\([\'"]?[^\s\'"()*]*'
    _CREDENTIAL_ASSIGN_PATTERNS = [
        # Nonce files (pre-existing)
        rf'(?:{_CRED_ASSIGN_PREFIX}|{_CRED_ASSIGN_ARRAY})\.claude/teams/[^/]+/nonces/[^/]+\.nonce',
        rf'(?:{_CRED_ASSIGN_PREFIX}|{_CRED_ASSIGN_ARRAY})\.taint-nonces/[^/]+\.nonce',
        # SSH private key paths (credential-dir signal required — mirrors unconditional patterns)
        rf'(?:{_CRED_ASSIGN_PREFIX}|{_CRED_ASSIGN_ARRAY})(?:~/|/home/[^/\s]+/|\.ssh/)(?:[^\s\'"]*)',
        # AWS credential paths
        rf'(?:{_CRED_ASSIGN_PREFIX}|{_CRED_ASSIGN_ARRAY})(?:~/|/home/[^/\s]+/)?\.aws/credentials',
        # /etc/ credential files (shadow, sudoers, passwd)
        rf'(?:{_CRED_ASSIGN_PREFIX}|{_CRED_ASSIGN_ARRAY})/etc/(?:shadow|sudoers|passwd)',
    ]
    for _apat in _CREDENTIAL_ASSIGN_PATTERNS:
        if re.search(_apat, command_str, re.IGNORECASE):
            return (True, f"{_apat} [variable indirection — credential path assigned to variable]")

    # Fast-exit: no output indicator means no egress — BUT only for non-tainted sessions.
    # v5.8.1 (Item 1): When tainted, stdout IS egress (LLM context window).
    # The taint-safe allowlist includes cat/grep/find which can read credential files;
    # skipping the has_egress gate ensures those commands are caught here first.
    has_egress = bool(re.search(r'(?<!&)>(?!&\d)|>>|\|(?!\|)|\bof=|\s-out\b', command_str))
    if not has_egress and not is_tainted:
        return (False, "")

    # Does the command mention any credential deny-path?
    for _pat in _CREDENTIAL_DENY_PATTERNS:
        if re.search(_pat, command_str, re.IGNORECASE):
            return (True, _pat)

    return (False, "")

# --- v5.8.0 (C-2): Resolve session taint state once, before tool dispatch ---
# If the session is tainted, a reduced-capability profile applies to Bash and Write/Edit.
# Read tool is not restricted (taint is output-side; reading is fine).
_current_session_id = _stdin_session_id or os.environ.get("CLAUDE_SESSION_ID", "")
_session_tainted = _session_is_tainted(_current_session_id)

# --- Determine what's being accessed ---

file_path = ""
_extra_paths = []  # F4/H-new-1: additional write paths for multi-arg Bash commands
_src_paths = []    # H-new-2: source paths for cp/mv deny-list check
if tool in ("Write", "Edit"):
    file_path = tool_input.get("file_path", "")
elif tool == "Read":
    # CRITICAL-1 fix (v5.7.1): gate Read tool on credential deny-list.
    # The PreToolUse matcher previously excluded Read, allowing any role to
    # read nonce files and taint-nonce files by calling Read() directly.
    # Now we apply _src_deny_check to file_path and block on credential paths.
    _read_path = tool_input.get("file_path", "")
    if _read_path and _src_deny_check(_read_path):
        print(
            f"BLOCKED: {role} — Read tool file_path matches credential/secret deny-list "
            f"({_read_path!r}). Reading secret material via Read tool is not permitted. "
            f"(CRITICAL-1 fix)",
            file=sys.stderr
        )
        sys.exit(2)
    sys.exit(0)  # Read tool: if path is clean, allow immediately
elif tool == "Bash":
    command = tool_input.get("command", "")

    # Allowlist approach: only permit known-safe read-only commands
    # If a command doesn't match the allowlist, it requires path-based checking
    safe_readonly_patterns = [
        r'^\s*ls\b',
        r'^\s*cat\b',
        r'^\s*head\b',
        r'^\s*tail\b',
        r'^\s*wc\b',
        r'^\s*file\b',
        r'^\s*stat\b',
        r'^\s*du\b',
        r'^\s*df\b',
        r'^\s*which\b',
        r'^\s*whereis\b',
        r'^\s*type\b',
        r'^\s*echo\b[^>]*$',  # echo without redirect
        r'^\s*printf\b[^>]*$',  # printf without redirect
        r'^\s*pwd\b',
        r'^\s*date\b',
        r'^\s*whoami\b',
        r'^\s*uname\b',
        r'^\s*hostname\b',
        r'^\s*git\s+(status|log|diff|show|branch|tag|remote|describe|rev-parse|rev-list|shortlog|stash\s+list|config\s+--get|ls-files|ls-tree|blame|name-rev)\b',
        r'^\s*git\s+--no-pager\s+(status|log|diff|show|branch|tag|remote|describe|rev-parse|rev-list|shortlog|stash\s+list|config\s+--get|ls-files|ls-tree|blame|name-rev)\b',
        r'^\s*npm\s+(ls|list|outdated|audit|info|view|explain)\b',
        r'^\s*yarn\s+(list|info|why)\b',
        r'^\s*pnpm\s+(ls|list|outdated|audit)\b',
        r'^\s*pip\s+(list|show|freeze|check)\b',
        r'^\s*cargo\s+(tree|check|clippy|doc|metadata|verify-project)\b',
        r'^\s*go\s+(list|vet|doc|version|env)\b',
        # node -e and python3 -c REMOVED: both allow arbitrary code execution
        # node -e: require('fs').writeFileSync bypasses all enforcement
        # python3 -c: including 'print' anywhere passes the check with arbitrary code
        r'^\s*jq\b',
        r'^\s*yq\b',
        r'^\s*tree\b',
        r'^\s*find\b(?!.*(-exec|-execdir|-delete|-ok|-fprint|-fls|-fprintf))',  # find without dangerous flags
        r'^\s*grep\b',
        r'^\s*rg\b',
        r'^\s*ag\b',
        r'^\s*awk\b(?!.*\bsystem\b)[^>]*$',  # awk without redirect or system() calls
        r'^\s*sort\b[^>]*$',
        r'^\s*uniq\b[^>]*$',
        r'^\s*diff\b',
        r'^\s*comm\b',
        r'^\s*test\b',
        r'^\s*\[\s',
        r'^\s*true\s*$',
        r'^\s*false\s*$',
        # F6-orig: mkdir -p .claude/ainous-roles/ REMOVED from allowlist.
        # mkdir is now routed through the write-path extractor + baseline check
        # to prevent ../ traversal (e.g. mkdir -p .claude/ainous-roles/../../etc/evil).
    ]

    # C1: Reject commands containing raw control characters — these bypass allowlist splitting
    # BUG-4: also include Unicode line/paragraph separators (U+2028, U+2029)
    # C1 NEL: also reject U+0085 (NEL — Next Line, used as newline in some encodings)
    # F8: also reject additional Unicode homoglyph/invisible chars:
    #   U+00A0 NBSP, U+200B ZWSP, U+202A-U+202E bidi overrides, U+2060 WJ, U+FEFF BOM
    if re.search(r'[\n\r\x0b\x0c\x00\x85\u2028\u2029\u00a0\u200b\u202a-\u202e\u2060\ufeff]', command):
        print(f"BLOCKED: {role} — command contains control characters (newline/null). Rejected for safety.", file=sys.stderr)
        sys.exit(2)

    # Reject command substitution / subshells / process substitution / background execution
    # F7: also reject >(...) (output process substitution) and standalone & (background)
    # CRITICAL-A fix (2026-04-17): background & must BLOCK immediately, not fall through.
    # The old approach set all_safe=False and fell through to write-pattern detection —
    # which allowed `ls / & rm -rf src/evil` because `rm src/evil` matched the developer
    # baseline for `src/`. Subshells ($(), backticks, <(), >()) still fall through because
    # they may wrap legitimate write commands; background & never has a legitimate use here.
    # SECURITY TAX: this rejects `&` inside quoted string literals (e.g., `echo "a & b"`)
    # because regex can't parse shell quoting. If this false-positive becomes a workflow
    # issue, the fix is a real shell parser — NOT a regex relaxation. See
    # authority-enforce critic round 4 (2026-04-17) for regression analysis.
    # The pattern `(?<!&)&(?![&\d])` excludes `&&` (logical AND) and `>&N` fd-to-fd
    # redirects (e.g. `2>&1`) where & is followed by a digit. This avoids false-positives
    # on `cmd 2>&1` while still catching `cmd & rm -rf evil` and `sleep 10 &`.
    if re.search(r'(?<!&)&(?![&\d])', command):
        print(f"BLOCKED: {role} — command contains background operator '&'. Background execution is not permitted via the hook.", file=sys.stderr)
        sys.exit(2)

    # H-new-3: credential path + output-indicator cross-check (redirect-exfil defense).
    # Runs AFTER control-char and background-& rejections, BEFORE allowlist evaluation.
    # cat is in the allowlist; this check must fire first or cat+redirect bypasses it.
    # Applies to ALL roles — a compromised role must not exfiltrate secrets.
    _egress_blocked, _egress_reason = _scan_command_for_credential_egress(command, is_tainted=_session_tainted)
    if _egress_blocked:
        print(
            f"BLOCKED: {role} — command mentions credential path matching {_egress_reason!r} "
            f"and contains an output indicator (>, >>, |, of=, or -out). "
            f"This pattern can exfiltrate credentials to project tree or external destination. "
            f"If you need to read this file, use the command without redirect or pipe "
            f"(e.g. grep pattern ~/.ssh/authorized_keys instead of cat ... | grep). (H-new-3)",
            file=sys.stderr
        )
        sys.exit(2)

    # ---------------------------------------------------------------------------
    # v5.9.1 (M-new-1): Team-mode teammate Bash write block.
    # §15 enforcement blocks Write/Edit for teammates (above). This extends the
    # block to Bash commands that mutate the filesystem — teammates should return
    # content via SendMessage envelope, not write via Bash.
    #
    # Placement: AFTER credential-deny gates (H-new-3 above). Credential exfil
    # attempts get the credential-deny reason, which is clearer for debugging.
    # BEFORE taint-scope-reduction: teammate Bash writes are unconditionally blocked
    # regardless of taint state.
    #
    # Write-operation detection: redirect operators, tee, dd of=, cp, mv, printf/echo
    # with redirect, ln -s (symlink creation), mkdir, rmdir, rm, touch.
    # ---------------------------------------------------------------------------
    _BASH_TEAMMATE_WRITE_PATTERNS = [
        r'\s>(?!>?\s*/dev/null|\s*&)',  # > redirect (excluding >/dev/null and >&N)
        r'\s>>',                         # >> append redirect
        r'\btee\b',                      # tee (writes to file)
        r'\bdd\b.*\bof=',               # dd with output file
        r'\bcp\b\s+\S+\s+\S',           # cp src dest
        r'\bmv\b\s+\S+\s+\S',           # mv src dest
        r'\bprintf\b.*>\s*\S',           # printf with redirect
        r'\becho\b.*>\s*\S',            # echo with redirect
        r'\bln\b\s+-s\b',               # ln -s symlink creation
        r'\bmkdir\b',                    # mkdir (directory creation)
        r'\brmdir\b',                    # rmdir (directory deletion)
        r'\brm\b',                       # rm (file deletion)
        r'\btouch\b',                    # touch (file creation/timestamp)
    ]
    _bash_teammate_command = os.environ.get("CLAUDE_CODE_TEAMMATE_COMMAND", "")
    _bash_is_teammate = bool(_bash_teammate_command)
    if _bash_is_teammate:
        _bash_write_matched = None
        for _bwp in _BASH_TEAMMATE_WRITE_PATTERNS:
            if re.search(_bwp, command):
                _bash_write_matched = _bwp
                break
        if _bash_write_matched is not None:
            print(
                f"[authority-enforce] TEAM_MATE_WRITE_DENY: Team-mode teammates must not "
                f"mutate the filesystem via Bash (v5.9.1 M-new-1). "
                f"Return content via SendMessage envelope per runtime-charter §15.1 — "
                f"coordinator will recovery-write. "
                f"Matched write-operation pattern: {_bash_write_matched!r}. "
                f"(CLAUDE_CODE_TEAMMATE_COMMAND={_bash_teammate_command!r}; role_marker={role!r})",
                file=sys.stderr
            )
            sys.exit(2)

    # ---------------------------------------------------------------------------
    # v5.8.0 (C-2): Taint-scope-reduction for Bash commands.
    # If the session is tainted (WebFetch/WebSearch was called), restrict Bash to
    # a read-only allowlist. Network-touching and modification commands are rejected.
    # Credential egress check above already fired; this adds an additional gate.
    # ---------------------------------------------------------------------------
    if _session_tainted:
        _TAINTED_BASH_ALLOWLIST = [
            r'^\s*ls\b',
            r'^\s*cat\b[^>]*$',           # cat without redirect (no > or >>)
            r'^\s*grep\b',
            r'^\s*head\b',
            r'^\s*tail\b',
            r'^\s*wc\b',
            r'^\s*find\b(?!.*(-exec|-execdir|-delete|-ok|-fprint|-fls|-fprintf))',
            r'^\s*pwd\b',
            r'^\s*echo\b[^>]*$',          # echo without redirect
            r'^\s*rg\b',
            r'^\s*git\s+(status|log|diff|show|branch|tag|remote|describe|rev-parse|rev-list|shortlog)\b',
        ]
        # Check each part of the command against the taint-safe allowlist
        _taint_parts = re.split(r'\s*(?:&&|\|\||;)\s*', command) if ('&&' in command or '||' in command or ';' in command) else [command]
        _taint_all_safe = True
        _failing_part = ""
        for _tp in _taint_parts:
            _tp = _tp.strip()
            if not _tp:
                continue
            # Strip leading pipe segment (first command in pipe chain)
            if '|' in _tp:
                _tp = _tp.split('|')[0].strip()
            if not any(re.search(_p, _tp) for _p in _TAINTED_BASH_ALLOWLIST):
                _taint_all_safe = False
                _failing_part = _tp
                break
        if not _taint_all_safe:
            _audit_log = os.path.expanduser("~/.claude/.authority-tainted-decisions.log")
            try:
                import datetime as _dt
                _ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                with open(_audit_log, "a", encoding="utf-8") as _alf:
                    import hashlib as _hl
                    _cmd_sha = _hl.sha256(command.encode()).hexdigest()[:12]
                    _part_sha = _hl.sha256(_failing_part.encode()).hexdigest()[:12]
                    _alf.write(f"[{_ts}] TAINTED-BASH-BLOCK role={role!r} command_sha256={_cmd_sha} failing_predicate=tainted-bash-allowlist failing_part_sha256={_part_sha}\n")
            except OSError:
                pass
            print(
                f"BLOCKED: {role} — session tainted: reduced-capability profile active. "
                f"Command {_failing_part!r} is not in the taint-safe read-only allowlist. "
                f"Allowed taint-safe commands: ls, cat, grep, head, tail, wc, find, pwd, echo, rg, git status/log/diff. "
                f"For broader access, coordinator must initiate a fresh session spawn. (v5.8.0 C-2)",
                file=sys.stderr
            )
            sys.exit(2)
        # Command is in taint-safe allowlist — check for dangerous pipe stages (same as normal flow)
        _taint_dangerous_pipe = [
            r'\|[^|]*\bcurl\b', r'\|[^|]*\bwget\b', r'\|[^|]*\bnc\b',
            r'\|[^|]*\btee\b', r'\|[^|]*\bdd\b', r'\|[^|]*\brm\b',
            r'\|[^|]*\bmv\b', r'\|[^|]*\bcp\b', r'\|[^|]*\bbash\b',
            r'\|[^|]*\bsh\b', r'\|[^|]*\bpython', r'\|[^|]*\bperl\b',
            r'>[^&]\S*', r'>>[^&]\S*',
        ]
        if not any(re.search(_p, command) for _p in _taint_dangerous_pipe):
            sys.exit(0)  # Taint-safe and no dangerous pipe — allow
        # Has dangerous pipe despite being in allowlist — block
        _audit_log = os.path.expanduser("~/.claude/.authority-tainted-decisions.log")
        try:
            import datetime as _dt
            _ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(_audit_log, "a", encoding="utf-8") as _alf:
                import hashlib as _hl
                _cmd_sha = _hl.sha256(command.encode()).hexdigest()[:12]
                _alf.write(f"[{_ts}] TAINTED-BASH-PIPE-BLOCK role={role!r} command_sha256={_cmd_sha} failing_predicate=tainted-bash-dangerous-pipe\n")
        except OSError:
            pass
        print(
            f"BLOCKED: {role} — session tainted: reduced-capability profile active. "
            f"Command uses a dangerous pipe or redirect. "
            f"Taint-safe reads without egress redirects are allowed. (v5.8.0 C-2)",
            file=sys.stderr
        )
        sys.exit(2)

    if re.search(r'\$\(|`|<\(|>\(', command):
        # Fall through to write pattern detection (don't trust allowlist with subshells)
        all_safe = False
        cmd_parts = []
    else:
        # Check if the command is safe (handle pipes: check first command)
        first_cmd = command.split('|')[0].strip() if '|' in command else command.strip()
        # Also handle && chains — check all parts; C1: also split on \n and \r (defense-in-depth)
        cmd_parts = re.split(r'\s*(?:&&|\|\||;|[\n\r])\s*', command) if ('&&' in command or '||' in command or ';' in command or '\n' in command or '\r' in command) else [command]

        all_safe = True
        for part in cmd_parts:
            part = part.strip()
            if not part:
                continue
            # Strip leading pipes
            if '|' in part:
                part = part.split('|')[0].strip()
            if not any(re.search(p, part) for p in safe_readonly_patterns):
                all_safe = False
                break

    if all_safe:
        # Even if all first-segments are safe, check for writes in later pipe stages
        # Catches: safe_cmd | tee /path, safe_cmd > /path, safe_cmd | dd of=/path
        dangerous_pipe_patterns = [
            r'\|[^|]*\btee\b',      # pipe to tee
            r'\|[^|]*\bdd\b',       # pipe to dd
            r'\|[^|]*\bsed\s+-i',   # pipe to sed -i
            r'\|[^|]*\bcurl\b',     # pipe to curl
            r'\|[^|]*\bwget\b',     # pipe to wget
            r'\|[^|]*\bnc\b',       # pipe to nc (netcat)
            r'\|[^|]*\bpython',     # pipe to python/python3
            r'\|[^|]*\bnode\b',     # pipe to node
            r'\|[^|]*\brm\b',       # pipe to rm
            r'\|[^|]*\bmv\b',       # pipe to mv
            r'\|[^|]*\bcp\b',       # pipe to cp
            r'\|[^|]*\bchmod\b',    # pipe to chmod
            r'\|[^|]*\bchown\b',    # pipe to chown
            r'\|[^|]*\bxargs\b',    # pipe to xargs
            r'\|[^|]*\bbash\b',     # pipe to bash
            r'\|[^|]*\bsh\b',       # pipe to sh
            r'\|[^|]*\bzsh\b',      # pipe to zsh
            r'\|[^|]*\bperl\b',     # pipe to perl
            r'\|[^|]*\bruby\b',     # pipe to ruby
            r'\|[^|]*\benv\b',      # pipe to env (can run anything)
            r'\|[^|]*\bwhile\b',    # pipe to while loop
            r'\|[^|]*\bfor\b',      # pipe to for loop
            r'\|[^|]*\beval\b',     # pipe to eval
            r'>[^&]\S*',             # redirect > (but not >&N fd-to-fd redirects)
            r'>>[^&]\S*',           # append redirect >> (but not >>&N)
        ]
        if not any(re.search(p, command) for p in dangerous_pipe_patterns):
            sys.exit(0)
        # Fall through to write pattern detection below

    # --- Dangerous git subcommands: full-string scan (not prefix-only) ---
    # These are blocked for ALL roles — they require explicit user approval.
    # Must run BEFORE the git write allowlist to prevent compound command bypass
    # (e.g., "git commit -m 'fix' && git push origin main" matching only "git commit").
    if re.search(r'\bgit\s+push\b', command):
        print(f"BLOCKED: git push requires explicit user approval. Detected in compound command.", file=sys.stderr)
        sys.exit(2)
    if re.search(r'\bgit\s+reset\s+--hard\b', command):
        print(f"BLOCKED: git reset --hard requires explicit user approval. Detected in compound command.", file=sys.stderr)
        sys.exit(2)
    if re.search(r'\bgit\s+clean\s+-[a-zA-Z]*f', command):
        print(f"BLOCKED: git clean -f requires explicit user approval. Detected in compound command.", file=sys.stderr)
        sys.exit(2)

    # Git write commands — allowed for specific roles only
    if re.match(r'^\s*git\s+(add|commit|stash\s+(push|save|pop|apply|drop))\b', command):
        git_write_roles = {"coordinator", "developer", "consolidator", "writer", "architect", "tester", "operator"}
        if role in git_write_roles:
            print(f"NOTE: {role} running git write command — allowed for this role.", file=sys.stderr)
            sys.exit(0)
        else:
            print(f"BLOCKED: {role} cannot run git write commands. Only coordinator, developer, consolidator, writer, architect, tester roles can.", file=sys.stderr)
            sys.exit(2)

    # Not in allowlist — try to extract target paths from write commands
    # Detect write operations and extract target paths
    write_patterns = [
        (r'>>\s*([^&]\S*)', 'append'),             # >> file (must be before > to match first; exclude >>&N fd redirects)
        (r'(?<!>)>\s*([^&]\S*)', 'redirect'),  # > file (but not >> and not >&N fd-to-fd redirects)
        (r'\btee\b', 'tee'),                   # tee — multi-arg extractor (H-new-1)
        (r'\bcp\b', 'cp'),                     # cp — multi-arg extractor (H-new-1/H-new-2)
        (r'\bmv\b', 'mv'),                     # mv — multi-arg extractor (H-new-1/H-new-2)
        (r'\brm\b', 'rm'),                     # rm — multi-arg extractor (F4)
        (r'\bsed\b', 'sed'),                   # sed — multi-arg extractor (H-new-1)
        (r'\bchmod\b', 'chmod'),               # chmod — multi-arg extractor (H-new-1)
        (r'\bchown\b', 'chown'),               # chown — multi-arg extractor (H-new-1)
        (r'\bln\b', 'ln'),                     # ln — multi-arg extractor (F4)
        (r'\btouch\b', 'touch'),               # touch — multi-arg extractor (H-new-1)
        # F6-orig: mkdir pattern routes through path extractor; ../ traversal is
        # caught downstream by realpath normalization + baseline check.
        (r'\bmkdir\b', 'mkdir'),               # mkdir — multi-arg extractor (H-new-1)
        (r'\bcurl\s+.*-o\s+(\S+)', 'curl'),    # curl -o file
        (r'\bwget\s+.*-O\s+(\S+)', 'wget'),    # wget -O file
        (r'\bdd\b.*\bof=(\S+)', 'dd'),         # dd of=file
        (r'\binstall\b', 'install'),            # install — multi-arg extractor (F4)
    ]

    # ---------------------------------------------------------------------------
    # H-new-1 + F4: generic multi-arg path extractor (generalized dispatcher)
    # Commands covered: rm, touch, mkdir, chmod, chown, sed, tee, ln, cp, mv, install
    # Each command has per-command rules for flag/positional boundary parsing.
    # Uses shlex.split; if shlex fails (unclosed quote) → BLOCK (fail-safe).
    # ---------------------------------------------------------------------------
    def _extract_multi_arg_paths(cmd_str, op):
        """Extract and return (primary_write_path, [extra_write_paths], [src_paths])
        for multi-arg write operations.

        primary_write_path: the first/authoritative write target (run through full auth).
        extra_write_paths:  additional write targets (each run through _authority_allow).
        src_paths:          source paths for cp/mv (run through _src_deny_check only).

        Returns (None, [], []) if no paths could be extracted → caller blocks.
        Raises SystemExit(2) on shlex parse failure (fail-closed).
        """
        import shlex as _shlex

        # Per-command flags-with-values sets (flag consumes the next token as its value)
        _FLAGS_WITH_VALUES = {
            'chmod':   {'-m'},                          # chmod -m MODE file (BSD only)
            'chown':   {'-f', '--reference'},
            'sed':     {'-e', '-f'},                    # -e SCRIPT, -f SCRIPTFILE
            # NOTE: -i for sed is tricky: GNU takes no arg, macOS optionally takes SUFFIX.
            # We do NOT put -i in flags-with-values; instead the suffix (if any) starts
            # with a non-alpha char or is empty. In practice callers use `sed -i ''` (BSD)
            # or `sed -i` (GNU); the next token (the file) is a positional. This works
            # because any -i suffix on macOS is typically '' (empty string passed as arg)
            # which shlex splits as a separate empty token — filtered as len 0 positional.
            'mkdir':   {'-m'},                          # -m MODE
            'install': {'-m', '-o', '-g', '-b', '-S'},
            'ln':      set(),
            'cp':      {'-t', '--target-directory'},
            'mv':      {'-t', '--target-directory'},
            'rm':      set(),
            'touch':   {'-t', '-d', '--date', '--reference', '-r'},  # -t STAMP, -d DATE
            'tee':     set(),
        }

        # Use shlex for robust quoted-arg handling; fail closed on parse error
        try:
            tokens = _shlex.split(cmd_str)
        except ValueError:
            print(f"BLOCKED: {role} — shlex parse error in '{op}' command (unclosed quote?). Failing closed.", file=sys.stderr)
            sys.exit(2)

        # Locate the op token (first occurrence)
        op_idx = None
        for i, tok in enumerate(tokens):
            if tok == op:
                op_idx = i
                break
        if op_idx is None:
            return None, [], []

        args_after = tokens[op_idx + 1:]
        fwv = _FLAGS_WITH_VALUES.get(op, set())

        # Parse positional args, respecting flags-with-values and -- sentinel
        positionals = []
        past_double_dash = False
        skip_next = False
        for tok in args_after:
            if skip_next:
                skip_next = False
                continue
            if tok == '--':
                past_double_dash = True
                continue
            if not past_double_dash and tok.startswith('-'):
                if tok in fwv:
                    skip_next = True  # next token is the flag's value, not a path
                continue
            positionals.append(tok)

        if not positionals:
            return None, [], []

        # Per-command dispatch: determine write targets and source paths
        if op == 'rm':
            # All positionals are write (delete) targets
            return positionals[0], positionals[1:], []

        elif op in ('touch', 'tee'):
            # All positionals are write targets
            return positionals[0], positionals[1:], []

        elif op == 'mkdir':
            # All positionals are write targets (directories to create)
            return positionals[0], positionals[1:], []

        elif op == 'chmod':
            # First positional is MODE (e.g. 755, u+x), rest are file targets
            if len(positionals) < 2:
                return None, [], []
            return positionals[1], positionals[2:], []

        elif op == 'chown':
            # First positional is USER[:GROUP], rest are file targets
            if len(positionals) < 2:
                return None, [], []
            return positionals[1], positionals[2:], []

        elif op == 'sed':
            # File targets: depends on whether -e/-f flags were present.
            # After flag processing, positionals remaining are:
            #   - If any -e/-f was consumed: ALL positionals are file paths.
            #   - If NO -e/-f: first positional is the inline SCRIPT, rest are file paths.
            # We detect -e/-f presence by re-scanning the token list.
            has_script_flag = any(tok in ('-e', '-f') for tok in args_after if not tok.startswith('-') is False)
            # Simpler: check raw token list before flag filtering
            raw_flags = [tok for tok in args_after if tok.startswith('-') and tok != '--']
            has_explicit_script = any(f in ('-e', '-f') for f in raw_flags)
            if has_explicit_script:
                # All positionals are file paths (script was consumed as -e value)
                file_positionals = positionals
            else:
                # First positional is inline script, rest are file paths
                if len(positionals) < 2:
                    return None, [], []  # No file paths — ambiguous, fail closed
                file_positionals = positionals[1:]  # skip the script
            return (file_positionals[0], file_positionals[1:], []) if file_positionals else (None, [], [])

        elif op in ('cp', 'mv'):
            # Last positional is DST (write target); preceding ones are SRC (read + deny-check)
            if len(positionals) < 2:
                # Single positional — DST, no SRC
                return positionals[0], [], []
            dst = positionals[-1]
            srcs = positionals[:-1]
            return dst, [], srcs

        elif op in ('ln', 'install'):
            # Last positional is DST; validate DST only (SRC is not a write for ln)
            if not positionals:
                return None, [], []
            dst = positionals[-1]
            return dst, [], []

        else:
            return None, [], []

    # ---------------------------------------------------------------------------
    # Detect write operation and extract target path(s)
    # ---------------------------------------------------------------------------
    file_path = ""
    _extra_paths = []   # H-new-1/F4: additional write targets for multi-arg commands
    _src_paths = []     # H-new-2: source paths for cp/mv (deny-list check only)
    _matched_op = None
    # Commands routed through the generic multi-arg extractor (H-new-1)
    _MULTI_ARG_OPS = frozenset({'rm', 'cp', 'mv', 'ln', 'install', 'tee', 'touch',
                                 'mkdir', 'chmod', 'chown', 'sed'})
    for pattern, op_type in write_patterns:
        m = re.search(pattern, command)
        if m:
            _matched_op = op_type
            if op_type in _MULTI_ARG_OPS:
                # H-new-1/F4: generic multi-arg extraction (3-tuple)
                _primary, _extras, _srcs = _extract_multi_arg_paths(command, op_type)
                if _primary:
                    file_path = _primary
                    _extra_paths = _extras
                    _src_paths = _srcs
                else:
                    # Can't parse args — fail closed
                    print(f"BLOCKED: {role} — cannot parse {op_type} arguments for path enforcement.", file=sys.stderr)
                    sys.exit(2)
            else:
                file_path = m.group(1)
            break

    if not file_path:
        # Write-like command but can't determine target — block
        print(f"BLOCKED: {role} running unrecognized command via Bash. Use Write/Edit tools for permission-checked file operations, or message @authority for Bash approval.", file=sys.stderr)
        sys.exit(2)

    # H-new-2: SRC deny-check for cp/mv — block credential exfiltration for ALL roles
    for _sp in _src_paths:
        if _src_deny_check(_sp):
            print(f"BLOCKED: {role} — source path '{_sp}' matches credential deny-list. cp/mv of credential files is not permitted.", file=sys.stderr)
            sys.exit(2)

if not file_path:
    # Empty file path — fail closed
    print(f"BLOCKED: {role} — cannot determine target file path.", file=sys.stderr)
    sys.exit(2)

# --- Normalize path ---
# Resolve symlinks and relative paths to prevent traversal attacks
try:
    resolved = os.path.realpath(os.path.expanduser(file_path))
except (OSError, ValueError):
    resolved = file_path
file_lower = resolved.lower()
path_parts = file_lower.split('/')  # Used by all three layers for component matching
path_for_display = file_path  # Keep original for error messages

# --- Check protected paths (always deny) ---
for protected in PROTECTED_PATHS:
    try:
        protected_resolved = os.path.realpath(os.path.expanduser(protected))
        if resolved == protected_resolved:
            print(f"BLOCKED: {role} cannot write to protected path {path_for_display}. This path is system-critical.", file=sys.stderr)
            sys.exit(2)
    except (OSError, ValueError):
        pass

# --- H1: Structural session-marker check (early-deny, before Layer-1) ---
# Catches newly-created markers not present in the PROTECTED_PATHS snapshot.
if _is_structural_session_marker(file_path):
    print(f"BLOCKED: {role} cannot write to session marker path {path_for_display}. Session markers are structurally protected.", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Phase 2 (v5.3.0) / v5.3.1 (S-6): Taint flag write deny — checked BEFORE baseline (D-4)
# Unconditional. The taint-flag hook writes via direct Python I/O, not the tool
# surface. TAINT_FLAG_HOOK=1 env-marker escape hatch removed (S-6).
# @authority cannot grant exceptions; this is a hardcoded structural invariant.
# ---------------------------------------------------------------------------
if _TAINT_FLAG_WRITE_DENY_RE.search(resolved):
    print(
        f"BLOCKED: {role} — TAINT_FLAG_WRITE_DENY: writes to taint-flags/ are reserved for "
        f"the PostToolUse taint-flag hook (direct I/O). Tool-surface writes to "
        f"{path_for_display} are not permitted. (D-4 §2.3 — hardcoded invariant, no authority override)",
        file=sys.stderr
    )
    sys.exit(2)

# ---------------------------------------------------------------------------
# v5.3.1 (S-10): Nonce directory write deny — checked BEFORE baseline resolution
# Only session-start hook writes nonces via direct file I/O. No role write is
# ever legitimate. @authority cannot grant exceptions to this constant.
# ---------------------------------------------------------------------------
if _NONCE_DIR_WRITE_DENY_RE.search(resolved):
    print(
        f"BLOCKED: {role} — NONCE_DIR_WRITE_DENY: writes to .taint-nonces/ are reserved for "
        f"the session-start hook (direct I/O). Tool-surface writes to "
        f"{path_for_display} are not permitted. (hardcoded invariant, no authority override)",
        file=sys.stderr
    )
    sys.exit(2)

# ---------------------------------------------------------------------------
# v5.8.1 (Item 2): task-history.jsonl write deny — TASK_HISTORY_WRITE_DENY
# task-history.jsonl is written exclusively by PostToolUse hooks and log-event.sh
# via direct shell >> or Python file I/O — never through the tool surface.
# Operator has .claude/ in its baseline → could append forged spawn events →
# reaper reads forgery → cross-team DoS. Deny all tool-surface writes.
# @authority cannot grant exceptions; this is a hardcoded structural invariant.
# ---------------------------------------------------------------------------
if _TASK_HISTORY_WRITE_DENY_RE.search(resolved):
    print(
        f"BLOCKED: {role} — TASK_HISTORY_WRITE_DENY: writes to task-history.jsonl are reserved for "
        f"PostToolUse hooks (spawn-telemetry, write-proxy, etc.) and scripts/log-event.sh via "
        f"direct file I/O. Tool-surface writes to {path_for_display} are not permitted. "
        f"(v5.8.1 Item 2 — hardcoded invariant, no authority override)",
        file=sys.stderr
    )
    sys.exit(2)

# --- Read trust level ---
trust_level = "intern"  # Default — fail to most restrictive if growth.json unreadable
VALID_TRUST_LEVELS = {"intern", "junior", "senior", "principal", "operator"}

# C1: operator role — human CLI operator. No growth.json; always 'operator' trust level.
if role == "operator":
    trust_level = "operator"
else:
    try:
        growth_path = os.path.join(growth_dir, role, "growth.json")
        with open(growth_path, encoding='utf-8') as f:
            growth = json.load(f)
        raw_level = growth.get("trust", {}).get("level", "intern")  # C3: default intern, not junior
        # Validate trust level — unknown values treated as intern (fail closed)
        trust_level = raw_level if raw_level in VALID_TRUST_LEVELS else "intern"
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        pass

# --- Intern: block all writes ---
if trust_level == "intern":
    print(f"BLOCKED: {role} is at Intern trust level (read-only). Cannot write files. Earn trust through clean sessions.", file=sys.stderr)
    sys.exit(2)

# --- C1: Operator deny-list — checked before baseline allows ---
# These paths are always blocked for the operator, regardless of the broad baseline.
# Applied after intern check and before any other layer.
if role == "operator":
    OPERATOR_DENY_PATTERNS = [
        # Credentials
        r'(^|/)\.env($|[^/])',       # .env and .env.* variants
        r'\.key$',
        r'\.pem$',
        r'\.p12$',
        r'\.pfx$',
        r'\.jks$',
        r'\.keystore$',
        r'(^|/)id_rsa($|[\._])',
        r'(^|/)id_ed25519($|[\._])',
        r'(^|/)\.htpasswd$',
        # F3: also match bare filename (no trailing dot required)
        r'(^|/)credentials(\.|$)',
        r'(^|/)secrets(\.|$)',
        r'token\.json$',
        # F2: credential/config directories and files
        # HIGH-B fix (2026-04-17): use (/|$) instead of / so the directory form
        # (no trailing slash after realpath) is also blocked. os.path.realpath("~/.ssh/")
        # returns /Users/user/.ssh (no trailing slash), bypassing the old pattern.
        r'(^|/)\.ssh(/|$)',
        r'(^|/)\.aws(/|$)',
        r'(^|/)\.gnupg(/|$)',
        r'(^|/)\.kube(/|$)',
        r'(^|/)\.docker(/|$)',
        r'(^|/)\.netrc$',
        r'(^|/)\.npmrc$',
        r'(^|/)\.pypirc$',
        r'(^|/)\.gitconfig$',
        r'(^|/)\.git/config$',
        r'(^|/)\.git/hooks/',
        r'(^|/)authorized_keys$',
        r'(^|/)known_hosts$',
        # F1: system paths (absolute) — also match macOS /private/... resolved forms
        r'^(/private)?/etc/',
        r'^(/private)?/usr/',
        r'^(/private)?/System/',
        # /var/ system dirs — exclude /var/folders (macOS user temp under TMPDIR)
        r'^(/private)?/var/(root|run|log|db|spool|mail|empty|at|audit|backups|cron|lib|lock|named|opt|preserve|tmp|vm|yp)(/|$)',
        r'^(/private)?/bin/',
        r'^(/private)?/sbin/',
        r'^(/private)?/opt/',
        # F1+F2: /tmp (macOS realpath resolves /tmp → /private/tmp)
        r'^(/private)?/tmp/',
        # Session markers
        r'\.claude/\.session-role',
        r'\.claude/\.session-anchor',
        # CLAUDE.md (user edits via IDE, not via hook-gated flow)
        r'(^|/)\.claude/CLAUDE\.md$',
    ]
    for deny_pat in OPERATOR_DENY_PATTERNS:
        if re.search(deny_pat, resolved, re.IGNORECASE):
            print(f"BLOCKED: operator — {path_for_display} matches operator deny-list pattern '{deny_pat}'. Direct edits to this path are not permitted via the hook.", file=sys.stderr)
            sys.exit(2)

# ---------------------------------------------------------------------------
# _baseline_matches — defined here (before F4 extra-path check and Layer-3)
# so it can be used in both the pre-validation loop (F4) and the main Layer-3 check.
# ---------------------------------------------------------------------------
def _baseline_matches(path_parts, p):
    """Return True if baseline pattern p matches any component of path_parts.
    R7: directory patterns (ending with '/') must NOT match the last component —
    they only match if at least one more component follows (i.e., it's a directory,
    not a file named the same as the directory prefix)."""
    pattern_is_dir = p.endswith('/')
    stripped = p.rstrip('/')
    last_idx = len(path_parts) - 1
    for i, part in enumerate(path_parts):
        if part == stripped:
            if pattern_is_dir and i == last_idx:
                continue  # Pattern is a dir prefix but part is basename — no match
            return True
    return False

# ---------------------------------------------------------------------------
# F4: Extra-path pre-validation for multi-arg Bash commands (rm a b c, etc.)
# All _extra_paths must pass the same checks as the primary file_path.
# We run here — after trust_level is read and OPERATOR_DENY_PATTERNS is defined —
# so all necessary variables are in scope.
# Any failure blocks the entire command.
# ---------------------------------------------------------------------------
if _extra_paths:
    # Derive baselines for extra-path check (mirrors the Layer-3 logic below)
    _ep_baselines = list(JUNIOR_BASELINES.get(role, []))
    if trust_level in ("senior", "principal"):
        _ep_baselines = _ep_baselines + list(SENIOR_EXPANSIONS.get(role, []))

    for _ep in _extra_paths:
        try:
            _ep_resolved = os.path.realpath(os.path.expanduser(_ep))
        except (OSError, ValueError):
            _ep_resolved = _ep
        _ep_lower = _ep_resolved.lower()
        _ep_parts = _ep_lower.split('/')

        # v5.3.1 (S-4): TAINT_FLAG_WRITE_DENY — mirroring main-path check (D-4 §2.3)
        if _TAINT_FLAG_WRITE_DENY_RE.search(_ep_resolved):
            print(
                f"BLOCKED: {role} (F4 extra-arg) — TAINT_FLAG_WRITE_DENY: {_ep} is a taint-flags "
                f"path. Tool-surface writes are not permitted. (D-4 §2.3)",
                file=sys.stderr
            )
            sys.exit(2)

        # v5.3.1 (S-10): NONCE_DIR_WRITE_DENY — mirroring main-path check
        if _NONCE_DIR_WRITE_DENY_RE.search(_ep_resolved):
            print(
                f"BLOCKED: {role} (F4 extra-arg) — NONCE_DIR_WRITE_DENY: {_ep} is a taint-nonce "
                f"path. Tool-surface writes are not permitted.",
                file=sys.stderr
            )
            sys.exit(2)

        # Protected path check
        for _prot in PROTECTED_PATHS:
            try:
                _prot_r = os.path.realpath(os.path.expanduser(_prot))
                if _ep_resolved == _prot_r:
                    print(f"BLOCKED: {role} (F4 extra-arg) — {_ep} is a protected path. Command rejected.", file=sys.stderr)
                    sys.exit(2)
            except (OSError, ValueError):
                pass

        # H1: Structural session-marker check (extra-arg path)
        if _is_structural_session_marker(_ep):
            print(f"BLOCKED: {role} (F4 extra-arg) — {_ep} is a structurally protected session marker path. Command rejected.", file=sys.stderr)
            sys.exit(2)

        # Operator deny-list
        if role == "operator":
            for _dp in OPERATOR_DENY_PATTERNS:
                if re.search(_dp, _ep_resolved, re.IGNORECASE):
                    print(f"BLOCKED: operator (F4 extra-arg) — {_ep} matches deny-list. Command rejected.", file=sys.stderr)
                    sys.exit(2)

        # Intern: block all writes
        if trust_level == "intern":
            print(f"BLOCKED: {role} (F4 extra-arg) — intern trust cannot write files.", file=sys.stderr)
            sys.exit(2)

        # Own ainous-roles paths
        if role != "operator":
            _ep_ok = any(
                (p + "/" in _ep_lower + "/" or _ep_lower.endswith(p))
                for p in [f"/ainous-roles/{role}/journal", f"/ainous-roles/{role}/memory"]
            )
            if _ep_ok:
                continue  # allowed

        # Baseline match required
        if not _ep_baselines:
            print(f"BLOCKED: {role} is read-only (F4 extra-arg). {_ep} not authorized.", file=sys.stderr)
            sys.exit(2)
        if not any(_baseline_matches(_ep_parts, _p) for _p in _ep_baselines):
            print(f"BLOCKED: {role} (F4 extra-arg) — {_ep} is outside baseline. Command rejected.", file=sys.stderr)
            sys.exit(2)

# ---------------------------------------------------------------------------
# v5.8.0 (C-2): Taint-scope-reduction for Write/Edit tools.
# SECURITY: This gate MUST run before Layer-1 and Layer-3 baseline checks.
# If it ran after Layer-1, a tainted session writing to a Layer-1-covered path
# (e.g., src/, scripts/, docs/) would exit 0 inside _authority_allow before the
# taint gate ever fired — the exact 8-hour Clinejection exploitation window.
# Ordering: credential-deny → taint-gate → Layer-1 → Layer-3.
# ---------------------------------------------------------------------------
if _session_tainted and tool in ("Write", "Edit"):
    _tainted_own_path = f"/ainous-roles/{role}/"
    _taint_write_own = (
        _tainted_own_path in (resolved + "/") or
        resolved.endswith(_tainted_own_path.rstrip("/")) or
        _tainted_own_path in resolved
    )
    _taint_write_artifacts = "/ainous-roles/team-sync/artifacts/" in resolved
    if _taint_write_own or _taint_write_artifacts:
        # Path is within the taint-safe zone — authorize directly (skip Layer-1/Layer-3 baseline check).
        # _authority_allow runs provenance validation before exiting 0.
        # Log the taint-allow decision for audit.
        _audit_log = os.path.expanduser("~/.claude/.authority-tainted-decisions.log")
        try:
            import datetime as _dt
            _ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(_audit_log, "a", encoding="utf-8") as _alf:
                _alf.write(f"[{_ts}] TAINTED-WRITE-ALLOW role={role!r} path={resolved!r} zone={'own' if _taint_write_own else 'artifacts'}\n")
        except OSError:
            pass
        _authority_allow(resolved, tool_input, role, tmux_pane)
    else:
        _audit_log = os.path.expanduser("~/.claude/.authority-tainted-decisions.log")
        try:
            import datetime as _dt
            _ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(_audit_log, "a", encoding="utf-8") as _alf:
                _alf.write(f"[{_ts}] TAINTED-WRITE-BLOCK role={role!r} path={resolved!r}\n")
        except OSError:
            pass
        print(
            f"BLOCKED: {role} — session tainted: reduced-capability profile active. "
            f"Write to {path_for_display!r} is not permitted in a tainted session. "
            f"Tainted sessions may only write to role-own paths (.claude/ainous-roles/{role}/) "
            f"or findings artifacts (.claude/ainous-roles/team-sync/artifacts/). "
            f"For broader write access, coordinator must initiate a fresh session spawn. (v5.8.0 C-2)",
            file=sys.stderr
        )
        sys.exit(2)

# --- Layer 1: Project-level baselines (auto-generated by coordinator) ---
project_baselines_path = os.path.join(os.getcwd(), ".claude", "ainous-roles", "baselines.json")
try:
    with open(project_baselines_path, encoding='utf-8') as f:
        project_baselines = json.load(f)
    role_baselines = project_baselines.get(role, [])
    if role_baselines:
        file_basename = os.path.basename(resolved)
        for pattern in role_baselines:
            # BUG-1 FIX (Layer 1): trailing-slash patterns must strip '/' before component match
            if fnmatch.fnmatch(file_basename, pattern) or \
               fnmatch.fnmatch(resolved, f"*/{pattern}") or \
               any((part == pattern.rstrip('/') if pattern.endswith('/') else part == pattern)
                   for part in path_parts):
                _authority_allow(resolved, tool_input, role, tmux_pane)  # Project baseline match
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    pass  # No project baselines — fall through

# --- Layer 3: Hardcoded baselines + decisions (existing behavior) ---
# Layer-2 contract-implied authorization was retired in v5.8.0 — scope field was
# hardcoded empty on every spawn event; Layer-2 never operated on real data over
# 8 weeks of shipping. Removed rather than patched (evidence-disproves-retire).
# All authorization now flows: Layer-1 (project baselines) → Layer-3 (hardcoded + decisions.md).
# JUNIOR_BASELINES and SENIOR_EXPANSIONS are defined earlier in this file
# for use in _scope_conflicts_with_log_writers dynamic derivation (F6).

# Principal: broadest — everything in domain scope
# (For now, same as senior + authority delegation — handled by authority agent)

# Select baseline based on trust level
baselines = JUNIOR_BASELINES.get(role, [])
if trust_level in ("senior", "principal"):
    baselines = baselines + SENIOR_EXPANSIONS.get(role, [])

# --- All roles (except operator) can write their own ainous-roles data ---
# Developer TODO #3: operator has no journal/memory directories — skip own_paths
# to prevent a phantom allow if those paths are ever created by another mechanism.
if role != "operator":
    own_paths = [
        f"/ainous-roles/{role}/journal",
        f"/ainous-roles/{role}/memory",
    ]
    for p in own_paths:
        # Path-component match: ensure pattern is a proper prefix, not substring
        if p + "/" in file_lower + "/" or file_lower.endswith(p):
            _authority_allow(resolved, tool_input, role, tmux_pane)

# --- Read-only roles (no baseline patterns) ---
if not baselines:
    print(f"BLOCKED: {role} is read-only and cannot write files. Message @authority for approval.", file=sys.stderr)
    sys.exit(2)

# --- Check baseline patterns ---
# Path-component match: check each baseline against directory components.
# BUG-1 FIX: Patterns ending with '/' (e.g., "src/") denote directory names.
#   split('/') never produces a component containing '/', so startswith("src/")
#   always returned False. Strip the trailing slash and use exact component equality.
#   This correctly matches /any/path/src/foo.ts (component "src" == "src")
#   while rejecting /any/path/srcs/foo.ts (component "srcs" != "src") and
#   top-level files like src.ts (component "src.ts" != "src").
# Patterns without '/' use exact component match (e.g., "test" matches "test/" but NOT "testimony/")
# _baseline_matches is defined above (before F4 extra-path check) so both use the same helper.
# path_parts defined above after file_lower.

if any(_baseline_matches(path_parts, p) for p in baselines):
    _authority_allow(resolved, tool_input, role, tmux_pane)

# --- Check decisions.md for structured prior approval (v3: with validation) ---
try:
    with open(decisions_path, encoding='utf-8') as f:
        content = f.read()

    # Quick pre-filter: skip if this role is never mentioned (avoids parsing large files)
    if role not in content:
        raise FileNotFoundError  # Jump to except — no decisions for this role

    # M6: Parse structured decision blocks block-wise (avoids cutting mid-block on "supersedes ## AUTH-N")
    raw_blocks = re.findall(r'## AUTH-\d+.*?(?=\n## AUTH-\d+|\Z)', content, re.DOTALL)
    for block in raw_blocks:
        # Extract structured fields (- **field:** value)
        fields = {}
        for m in re.finditer(r'-\s+\*\*(\w+):\*\*\s*(.+)', block):
            fields[m.group(1).lower()] = m.group(2).strip()

        # Exact role match (not substring)
        if fields.get("role") != role:
            continue

        # Decision must be exactly APPROVED
        if fields.get("decision", "").upper() != "APPROVED":
            continue

        # Check expiration
        expires = fields.get("expires", "")
        if expires:
            try:
                exp_parts = expires.split("-")
                exp_date = date(int(exp_parts[0]), int(exp_parts[1]), int(exp_parts[2]))
                if date.today() > exp_date:
                    continue  # Expired
            except (ValueError, IndexError):
                continue  # Malformed date — treat as expired

        # Match path_pattern as a glob against resolved file path
        path_pattern = fields.get("path_pattern", "")
        if not path_pattern:
            continue

        # Reject overly broad patterns (unified helper — same rule as Layer-2 scope check)
        if _is_overly_broad(path_pattern):
            continue
        # Reject bare filenames without path prefix (must contain /)
        if '/' not in path_pattern and '*' not in path_pattern:
            continue

        # Match against the resolved path
        if fnmatch.fnmatch(resolved, f"*/{path_pattern}") or \
           resolved.endswith(path_pattern):
            # M4: If a scope field is present, further constrain the approval
            scope = fields.get("scope", "")
            if scope:
                # R2: reject overly broad scope values (unified helper — same rule as path_pattern)
                if _is_overly_broad(scope):
                    continue  # Broad scope — never auto-authorize
                # scope must match the resolved path (fnmatch or suffix)
                if not (fnmatch.fnmatch(resolved, f"*/{scope}") or
                        resolved.endswith(scope)):
                    continue  # scope present but doesn't match — not authorized
            _authority_allow(resolved, tool_input, role, tmux_pane)
except FileNotFoundError:
    pass

print(f"BLOCKED: {role} ({trust_level}) writing to {path_for_display} is outside baseline. Message @authority for approval.", file=sys.stderr)
sys.exit(2)
PYEOF

EXIT_CODE=$?
# Clean up temp input file (C4); trap EXIT also handles this for abnormal exits (R4)
rm -f "${_INPUT_TMPFILE:-}"
if [ $EXIT_CODE -eq 0 ]; then
    exit 0
fi
if [ $EXIT_CODE -eq 2 ]; then
    exit 2
fi
# Fail closed: any non-zero exit (including python crashes) blocks the operation
echo "BLOCKED: Enforcement script error (exit $EXIT_CODE). Failing closed for safety." >&2
exit 2
