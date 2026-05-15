#!/usr/bin/env python3
"""
_provenance_common.py — Single source of truth for provenance validation.

Purpose
-------
This module centralises the six provenance symbols that were previously
duplicated verbatim across hooks/authority-enforce.sh and hooks/write-proxy.
The duplication was identified as code-quality finding B-1 in the v5.6.9
analysis: a silent divergence (e.g., adding a new surface pattern to one hook
but not the other) creates a security gap where writes meant to require
provenance go unvalidated in one code path.

Precedent: hooks/_hmac_common.py (v5.6.4, commit 5efc39f) applied the same
pattern for HMAC helpers. This module follows identical conventions.

Consumers
---------
- hooks/authority-enforce.sh  (inline Python block — imports via sys.path)
- hooks/write-proxy            (inline Python block — imports via sys.path)
- Any future provenance-gated hook

Import contract
---------------
Both consumers use the same import-with-fallback idiom (see write-proxy
lines 76-88 for the canonical pattern): if CLAUDE_PLUGIN_ROOT is set and
importable, the shared module wins; otherwise the consumer falls back to its
own inline copy. This keeps each hook operational during plugin reload or
development without a full plugin install.

Exported symbols
----------------
- _PROVENANCE_PATTERNS      list[(regex_str, surface_type)]
- _REQUIRED_FIELDS          frozenset of required provenance key names
- _VALID_SOURCE_TYPES       set of valid source type strings
- _is_provenance_surface    (resolved_path: str) -> str | None
- _extract_md_provenance    (content: str) -> dict | None
- _validate_provenance_block(prov: dict) -> tuple[bool, str]
"""

import re

# ---------------------------------------------------------------------------
# Surface patterns — regex on resolved path, case-sensitive.
# Each entry is (pattern, surface_type) where surface_type is 'md' or 'jsonl'.
# ---------------------------------------------------------------------------
_PROVENANCE_PATTERNS = [
    (r'\.claude/ainous-roles/[^/]+/playbook\.md$',    'md'),
    (r'\.claude/ainous-roles/team-knowledge\.md$',    'md'),
    (r'\.claude/ainous-roles/[^/]+/learnings\.jsonl$','jsonl'),
    (r'\.claude/ainous-roles/[^/]+/journal\.md$',     'md'),
    (r'\.claude/ainous-roles/user-corrections\.md$',  'md'),
    # M-3 (v5.2.0): declared named artifacts in team-sync/artifacts/ — schema-presence enforce.
    # Covers exactly the 7 artifacts registered in agents/capabilities/artifacts/index.yaml.
    # Non-declared ad-hoc files in the same directory are intentionally not gated.
    (r'\.claude/ainous-roles/team-sync/artifacts/'
     r'(?:architect-design|researcher-findings|security-findings|code-quality-findings'
     r'|tester-plan|tester-results|signal-findings)[^/]*\.md$', 'md'),
    # Phase 2 (v5.3.0): taint-flags surface — defense-in-depth behind TAINT_FLAG_WRITE_DENY.
    # If the primary deny-list is ever relaxed, provenance validation still applies.
    (r'\.claude/ainous-roles/team-sync/state/taint-flags/[^/]+\.jsonl$', 'jsonl'),
]

# Required provenance fields (security §7 field set — v1).
_REQUIRED_FIELDS = frozenset({'role', 'session', 'source', 'discovered', 'verified'})

# Valid source_type enum (security §7 role-bound enum — v1 set).
# Note: 'user-confirmed' retired (2026-04-17) — source was never emitted; user-level
# signal flows via the user-corrections.md carrier (consolidator weights 3x).
_VALID_SOURCE_TYPES = {
    'observed', 'self-described', 'inferred',
    'legacy-unverified', 'coordinator-spawn', 'role-self-report',
}


def _is_provenance_surface(resolved_path):
    """Return surface_type ('md' | 'jsonl') if path is a provenance surface, else None."""
    for pattern, surface_type in _PROVENANCE_PATTERNS:
        if re.search(pattern, resolved_path):
            return surface_type
    return None


def _extract_md_provenance(content):
    """Extract provenance dict from YAML frontmatter of an .md write.

    Returns dict or None if no frontmatter found.
    """
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


def _extract_jsonl_provenance(content):
    """Extract provenance from the first non-empty JSONL line.

    Returns the parsed dict if it contains all required provenance fields,
    or None if the first line is missing, non-JSON, or lacks provenance fields.
    """
    import json as _json
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = _json.loads(line)
            if isinstance(obj, dict):
                return obj
        except (ValueError, _json.JSONDecodeError):
            return None
    return None


def _validate_provenance_block(prov):
    """Check all 5 required fields are present and source is valid.

    Returns (ok: bool, reason: str). reason is empty string on success.
    """
    if not isinstance(prov, dict):
        return False, "provenance block is not a dict"
    missing = _REQUIRED_FIELDS - set(prov.keys())
    if missing:
        return False, f"missing provenance fields: {sorted(missing)}"
    source = prov.get('source', '')
    if source not in _VALID_SOURCE_TYPES:
        return False, f"invalid source type: {source!r}"
    return True, ""
