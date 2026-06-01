#!/usr/bin/env python3
"""memory-maintain.py — Mechanical memory cap enforcement for ainous-team plugin.

Lifted from the inline prose blocks in agents-instructions/consolidator-instructions.md
(~lines 795-855).  The WAL-safe (.new → verify → mv) and advisory-lock patterns from
that document are preserved exactly.

NOTE: The logic described here is now enforced mechanically by this script.
See agents-instructions/consolidator-instructions.md for the canonical prose description.

Usage:
    python3 scripts/memory-maintain.py [--check | --dry-run] [--role ROLE] [--verbose]
                                        [--growth-dir PATH]

Modes:
    (default)   Run all maintenance operations, writing changes to disk.
    --check     Audit only — report what would change without writing. Exits 0 if
                nothing needs attention; exits 1 if any cap violation or integrity
                issue is detected.
    --dry-run   Alias for --check (same semantics).

Options:
    --role ROLE         Operate on a single role only (default: all roles in growth_dir).
    --verbose           Emit detailed per-operation output.
    --growth-dir PATH   Override the default ~/.claude/ainous-roles base directory.
                        Intended for testing; all functions read and write under this root.
                        Default behaviour is unchanged when the flag is absent.

Exit codes:
    0  All operations succeeded (or nothing needed doing in --check mode).
    1  At least one issue found in --check mode, or at least one operation failed.
"""

import argparse
import fcntl
import json
import os
import pathlib
import re
import sys
import time
from datetime import datetime, timezone, date as _date
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SESSION_CAP = 50          # Maximum entries in growth.json sessions[]
PLAYBOOK_CAP = 30         # Maximum strategies in playbook.md
LEARNING_MIN_CONFIDENCE = 0.3  # Prune entries below this if not corroborated
DECISION_EXPIRY_DAYS = 90      # Rotate decisions older than this
STALE_FACT_DAYS = 180          # Flag facts older than this

# GROWTH_DIR is the canonical base for all role directories.
# main() may override this via --growth-dir for testing; every function that
# reads from this path does so at call time (not at import time), so overriding
# before calling any function is sufficient to redirect all I/O.
GROWTH_DIR = pathlib.Path.home() / ".claude" / "ainous-roles"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(msg: str, verbose: bool = False, always: bool = False) -> None:
    if always or verbose:
        print(f"[{_ts()}] memory-maintain: {msg}")


def _acquire_advisory_lock(lock_path: pathlib.Path, max_age_seconds: int = 60) -> bool:
    """Acquire a file-based advisory lock.  Removes stale locks older than
    max_age_seconds.  Returns True if the lock was acquired, False otherwise.
    Uses fcntl.flock for atomic acquisition on POSIX systems.
    """
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        # Remove stale lock if older than max_age_seconds
        if lock_path.exists():
            try:
                age = time.time() - lock_path.stat().st_mtime
                if age > max_age_seconds:
                    lock_path.unlink(missing_ok=True)
            except OSError:
                pass
        fd = os.open(str(lock_path), os.O_CREAT | os.O_WRONLY, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.write(fd, f"{_ts()} memory-maintain-{os.getpid()}\n".encode())
            # Do not close fd here — keep it open for the duration of the lock.
            # Caller is responsible for calling _release_advisory_lock(lock_path, fd).
            return True, fd
        except BlockingIOError:
            os.close(fd)
            return False, -1
    except OSError:
        return False, -1


def _release_advisory_lock(lock_path: pathlib.Path, fd: int) -> None:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        lock_path.unlink(missing_ok=True)
    except OSError:
        pass


def _wal_write(target: pathlib.Path, content: str) -> bool:
    """Write content to target using the WAL-safe .new → verify → mv pattern.
    Returns True on success, False on failure (leaves target untouched).
    """
    tmp = target.with_suffix(target.suffix + ".new")
    try:
        tmp.write_text(content, encoding="utf-8")
        # Verify: the .new file must be non-empty and parseable if JSON
        written = tmp.read_text(encoding="utf-8")
        if not written:
            raise ValueError("WAL temp file is empty after write")
        if target.suffix == ".json":
            json.loads(written)  # parse check
        # Promote
        tmp.rename(target)
        return True
    except Exception as exc:
        print(f"[{_ts()}] memory-maintain: WAL write failed for {target}: {exc}", file=sys.stderr)
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return False


# ---------------------------------------------------------------------------
# 1. enforce_session_cap(role)
# ---------------------------------------------------------------------------


def enforce_session_cap(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Enforce the SESSION_CAP (50) on growth.json sessions[].

    WAL-safe sequence (lifted from consolidator-instructions.md §4b):
      1. Acquire advisory lock.
      2. Archive oldest (len - 50) entries to sessions-archive.jsonl.
      3. Write updated growth.json to .new.
      4. Verify .new is valid JSON with sessions[] len <= 50.
      5. mv .new → growth.json.
      6. Release lock.
    """
    growth_path = GROWTH_DIR / role / "growth.json"
    if not growth_path.exists():
        _log(f"enforce_session_cap({role}): growth.json not found — skipping", verbose)
        return True

    try:
        growth = json.loads(growth_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        _log(f"enforce_session_cap({role}): cannot read growth.json: {exc}", always=True)
        return False

    sessions = growth.get("sessions", [])
    if len(sessions) <= SESSION_CAP:
        _log(f"enforce_session_cap({role}): {len(sessions)} sessions — within cap, nothing to do", verbose)
        return True

    excess = len(sessions) - SESSION_CAP
    to_archive = sessions[:excess]
    trimmed = sessions[excess:]

    _log(f"enforce_session_cap({role}): {len(sessions)} sessions exceeds cap {SESSION_CAP} — "
         f"archiving {excess} oldest entries", verbose, always=True)

    if dry_run:
        _log(f"[dry-run] would archive {excess} sessions and trim growth.json for role={role}", always=True)
        return False  # Signal: action needed

    lock_path = GROWTH_DIR / role / "sessions-archive.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log(f"enforce_session_cap({role}): could not acquire advisory lock — skipping", always=True)
        return False

    try:
        # Step 2: Archive first (WAL step)
        archive_path = GROWTH_DIR / role / "sessions-archive.jsonl"
        try:
            with archive_path.open("a", encoding="utf-8") as af:
                for s in to_archive:
                    af.write(json.dumps(s) + "\n")
        except OSError as exc:
            _log(f"enforce_session_cap({role}): archive append failed: {exc} — aborting", always=True)
            return False

        # Step 3-5: Write updated growth.json via WAL
        growth["sessions"] = trimmed
        content = json.dumps(growth, indent=2) + "\n"
        if not _wal_write(growth_path, content):
            return False

        # Verify
        check = json.loads(growth_path.read_text(encoding="utf-8"))
        assert len(check.get("sessions", [])) <= SESSION_CAP, "sessions[] still exceeds cap after promotion"
        _log(f"enforce_session_cap({role}): OK — trimmed to {len(trimmed)} sessions", verbose)
        return True
    except Exception as exc:
        _log(f"enforce_session_cap({role}): unexpected error: {exc}", always=True)
        return False
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 2. enforce_playbook_cap(role)
# ---------------------------------------------------------------------------


def enforce_playbook_cap(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Enforce the PLAYBOOK_CAP (30 strategies) on playbook.md.

    Strategy detection: count H3 headings (### ) as strategy entries.
    If >30, the lowest-scoring strategies should be retired.  Since score
    data lives in the playbook itself (not machine-readable in a consistent
    format), this function REPORTS the violation and logs it, but does not
    auto-retire (that requires consolidator judgment).  Returns False if cap
    exceeded so --check mode reports it.
    """
    playbook_path = GROWTH_DIR / role / "playbook.md"
    if not playbook_path.exists():
        _log(f"enforce_playbook_cap({role}): playbook.md not found — skipping", verbose)
        return True

    try:
        text = playbook_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"enforce_playbook_cap({role}): cannot read playbook.md: {exc}", always=True)
        return False

    strategies = [line for line in text.splitlines() if line.startswith("### ")]
    count = len(strategies)

    if count <= PLAYBOOK_CAP:
        _log(f"enforce_playbook_cap({role}): {count} strategies — within cap", verbose)
        return True

    excess = count - PLAYBOOK_CAP
    _log(f"enforce_playbook_cap({role}): {count} strategies exceeds cap {PLAYBOOK_CAP} "
         f"({excess} over limit) — consolidator must retire lowest-scoring entries",
         always=True)
    if dry_run:
        _log(f"[dry-run] would flag playbook cap violation for role={role}", always=True)
    return False  # Signal: action needed (manual consolidator retirement required)


# ---------------------------------------------------------------------------
# 3. dedup_learnings(role)
# ---------------------------------------------------------------------------


def dedup_learnings(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Deduplicate learnings.jsonl by (key, type) — keep only the latest entry.

    Lifted from consolidator-instructions.md §Learnings Pruning.
    Uses WAL-safe write.
    """
    learnings_path = GROWTH_DIR / role / "learnings.jsonl"
    if not learnings_path.exists():
        _log(f"dedup_learnings({role}): learnings.jsonl not found — skipping", verbose)
        return True

    try:
        raw = learnings_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"dedup_learnings({role}): cannot read learnings.jsonl: {exc}", always=True)
        return False

    entries = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            _log(f"dedup_learnings({role}): skipping malformed line", verbose)

    # Keep last entry for each (key, type) pair
    seen: dict[tuple, dict] = {}
    for entry in entries:
        k = (entry.get("key", ""), entry.get("type", ""))
        seen[k] = entry  # Last write wins

    deduped = list(seen.values())
    removed = len(entries) - len(deduped)

    if removed == 0:
        _log(f"dedup_learnings({role}): no duplicates found", verbose)
        return True

    _log(f"dedup_learnings({role}): removing {removed} duplicate(s)", always=True)
    if dry_run:
        _log(f"[dry-run] would dedup {removed} learnings entries for role={role}", always=True)
        return False

    content = "\n".join(json.dumps(e) for e in deduped) + "\n"
    return _wal_write(learnings_path, content)


# ---------------------------------------------------------------------------
# 4. prune_orphan_learnings(role)
# ---------------------------------------------------------------------------


def prune_orphan_learnings(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Prune learnings.jsonl entries whose referenced files no longer exist.

    An entry is orphaned if all paths in its 'files' array are non-empty and
    none of them exist on disk.  Entries with an empty 'files' array are kept.

    Lifted from consolidator-instructions.md §Learnings Pruning.
    Uses WAL-safe write.
    """
    learnings_path = GROWTH_DIR / role / "learnings.jsonl"
    if not learnings_path.exists():
        _log(f"prune_orphan_learnings({role}): learnings.jsonl not found — skipping", verbose)
        return True

    try:
        raw = learnings_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"prune_orphan_learnings({role}): cannot read learnings.jsonl: {exc}", always=True)
        return False

    entries = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            entries_raw = getattr(entries, '_raw', [])
            _log(f"prune_orphan_learnings({role}): skipping malformed line", verbose)
            continue

    def _is_orphan(entry: dict) -> bool:
        files = entry.get("files", [])
        if not files:
            return False  # No file refs — keep
        # Orphan iff ALL referenced files are non-empty paths and ALL are missing
        non_empty = [f for f in files if f and isinstance(f, str)]
        if not non_empty:
            return False
        return all(not pathlib.Path(f).exists() and not pathlib.Path(os.path.expanduser(f)).exists()
                   for f in non_empty)

    kept = [e for e in entries if not _is_orphan(e)]
    pruned = len(entries) - len(kept)

    if pruned == 0:
        _log(f"prune_orphan_learnings({role}): no orphaned entries", verbose)
        return True

    _log(f"prune_orphan_learnings({role}): pruning {pruned} orphaned entry(ies)", always=True)
    if dry_run:
        _log(f"[dry-run] would prune {pruned} orphaned learnings for role={role}", always=True)
        return False

    content = "\n".join(json.dumps(e) for e in kept) + "\n"
    return _wal_write(learnings_path, content)


# ---------------------------------------------------------------------------
# 5. rotate_expired_decisions()
# ---------------------------------------------------------------------------


def rotate_expired_decisions(dry_run: bool = False, verbose: bool = False) -> bool:
    """Move expired decisions from decisions.md to decisions-archive.md.

    A decision is expired if its 'expires:' field is a date in the past.
    Lifted from consolidator-instructions.md §4c.

    Format matched (authority/decisions.md v2 schema):
        - **expires:** YYYY-MM-DD
    """
    decisions_path = GROWTH_DIR / "authority" / "decisions.md"
    if not decisions_path.exists():
        _log("rotate_expired_decisions: decisions.md not found — skipping", verbose)
        return True

    try:
        text = decisions_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"rotate_expired_decisions: cannot read decisions.md: {exc}", always=True)
        return False

    today = _date.today()
    # Split on decision blocks — each starts with "- **role:**"
    # Use a simple line-by-line parser to group decision blocks.
    blocks: list[list[str]] = []
    current: list[str] = []
    preamble: list[str] = []
    in_decisions = False

    for line in text.splitlines(keepends=True):
        if not in_decisions and line.strip().startswith("- **role:**"):
            in_decisions = True
        if not in_decisions:
            preamble.append(line)
        elif line.strip().startswith("- **role:**") and current:
            blocks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        blocks.append(current)

    active_blocks: list[list[str]] = []
    expired_blocks: list[list[str]] = []
    expires_re = re.compile(r'-\s+\*\*expires:\*\*\s+(\d{4}-\d{2}-\d{2})')

    for block in blocks:
        block_text = "".join(block)
        m = expires_re.search(block_text)
        if m:
            try:
                exp_date = _date.fromisoformat(m.group(1))
                if exp_date < today:
                    expired_blocks.append(block)
                    continue
            except ValueError:
                pass
        active_blocks.append(block)

    if not expired_blocks:
        _log("rotate_expired_decisions: no expired decisions found", verbose)
        return True

    _log(f"rotate_expired_decisions: rotating {len(expired_blocks)} expired decision(s)", always=True)
    if dry_run:
        _log(f"[dry-run] would rotate {len(expired_blocks)} expired decisions", always=True)
        return False

    # Append expired blocks to archive
    archive_path = GROWTH_DIR / "authority" / "decisions-archive.md"
    try:
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        with archive_path.open("a", encoding="utf-8") as af:
            af.write(f"\n<!-- rotated by memory-maintain.py at {_ts()} -->\n")
            for block in expired_blocks:
                af.write("".join(block))
    except OSError as exc:
        _log(f"rotate_expired_decisions: archive append failed: {exc}", always=True)
        return False

    # Write updated decisions.md via WAL
    new_content = "".join(preamble) + "".join("".join(b) for b in active_blocks)
    return _wal_write(decisions_path, new_content)


# ---------------------------------------------------------------------------
# 6. flag_stale_facts()
# ---------------------------------------------------------------------------


def flag_stale_facts(dry_run: bool = False, verbose: bool = False) -> bool:
    """Flag facts in team-knowledge.md that have not been updated in STALE_FACT_DAYS.

    A fact is considered stale if it carries an inline date comment
    `<!-- discovered: YYYY-MM-DD -->` older than STALE_FACT_DAYS days.
    Stale facts are annotated with `<!-- STALE: last-seen YYYY-MM-DD -->` so
    humans and the consolidator can review them.

    This is a non-destructive annotation — no facts are removed.
    """
    tk_path = GROWTH_DIR / "team-knowledge.md"
    if not tk_path.exists():
        _log("flag_stale_facts: team-knowledge.md not found — skipping", verbose)
        return True

    try:
        text = tk_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"flag_stale_facts: cannot read team-knowledge.md: {exc}", always=True)
        return False

    today = _date.today()
    disc_re = re.compile(r'<!--\s*discovered:\s*(\d{4}-\d{2}-\d{2})\s*-->')
    stale_marker_re = re.compile(r'<!--\s*STALE:[^>]*-->')

    lines = text.splitlines(keepends=True)
    new_lines: list[str] = []
    flagged = 0

    for line in lines:
        m = disc_re.search(line)
        if m:
            try:
                disc_date = _date.fromisoformat(m.group(1))
                age_days = (today - disc_date).days
                already_flagged = bool(stale_marker_re.search(line))
                if age_days >= STALE_FACT_DAYS and not already_flagged:
                    line = line.rstrip("\n") + f"  <!-- STALE: last-seen {m.group(1)} -->\n"
                    flagged += 1
            except ValueError:
                pass
        new_lines.append(line)

    if flagged == 0:
        _log("flag_stale_facts: no stale facts detected", verbose)
        return True

    _log(f"flag_stale_facts: flagging {flagged} stale fact(s)", always=True)
    if dry_run:
        _log(f"[dry-run] would flag {flagged} stale facts", always=True)
        return False

    return _wal_write(tk_path, "".join(new_lines))


# ---------------------------------------------------------------------------
# 7. verify_index_integrity()
# ---------------------------------------------------------------------------


def verify_index_integrity(project_root: Optional[str] = None,
                           dry_run: bool = False,
                           verbose: bool = False) -> bool:
    """Verify that all entries in team-sync/index.md point to existing files.

    Broken entries are reported.  If not in dry_run mode, broken entries are
    removed from the index and the index is rewritten via WAL.

    Lifted from consolidator-instructions.md §4e.
    """
    if project_root:
        index_path = pathlib.Path(project_root) / ".claude" / "ainous-roles" / "team-sync" / "index.md"
    else:
        # Fallback: use cwd
        index_path = pathlib.Path.cwd() / ".claude" / "ainous-roles" / "team-sync" / "index.md"

    if not index_path.exists():
        _log("verify_index_integrity: index.md not found — skipping", verbose)
        return True

    try:
        text = index_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"verify_index_integrity: cannot read index.md: {exc}", always=True)
        return False

    # Match markdown links: [label](path) — extract path
    link_re = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')
    broken: list[tuple[str, str]] = []  # (label, path)
    all_links: list[tuple[str, str]] = link_re.findall(text)

    for label, path in all_links:
        # Paths may be relative (to project root) or absolute
        if path.startswith("/") or path.startswith("~"):
            check = pathlib.Path(os.path.expanduser(path))
        elif project_root:
            check = pathlib.Path(project_root) / path
        else:
            check = pathlib.Path.cwd() / path
        if not check.exists():
            broken.append((label, path))
            _log(f"verify_index_integrity: broken link [{label}]({path})", verbose, always=True)

    if not broken:
        _log(f"verify_index_integrity: all {len(all_links)} index entries are valid", verbose)
        return True

    _log(f"verify_index_integrity: {len(broken)} broken index entry(ies) detected", always=True)
    if dry_run:
        _log(f"[dry-run] would remove {len(broken)} broken index entries", always=True)
        return False

    # Remove broken-link lines from index
    broken_paths = {path for _, path in broken}
    new_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        # Check if this line contains any broken link
        line_links = link_re.findall(line)
        if any(p in broken_paths for _, p in line_links):
            continue  # Drop the line
        new_lines.append(line)

    return _wal_write(index_path, "".join(new_lines))


# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------


def _discover_roles() -> list[str]:
    """Return all role directories found in GROWTH_DIR."""
    if not GROWTH_DIR.exists():
        return []
    return [
        d.name for d in sorted(GROWTH_DIR.iterdir())
        if d.is_dir() and not d.name.startswith(".")
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mechanical memory cap enforcement for ainous-team plugin.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--check", "--dry-run", action="store_true",
        help="Audit only — report violations without writing. Exits 1 if any found.",
    )
    parser.add_argument(
        "--role", default=None,
        help="Operate on a single role only (default: all roles).",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Emit detailed per-operation output.",
    )
    parser.add_argument(
        "--project-root", default=None,
        help="Project root for index integrity check (default: cwd).",
    )
    parser.add_argument(
        "--growth-dir", default=None,
        help="Override ~/.claude/ainous-roles base directory (for testing). "
             "All functions read/write under this root when supplied.",
    )
    args = parser.parse_args()

    # Override GROWTH_DIR before any function is called so all operations
    # (enforce_session_cap, dedup_learnings, etc.) honour the test fixture path.
    global GROWTH_DIR
    if args.growth_dir:
        GROWTH_DIR = pathlib.Path(args.growth_dir)

    dry_run: bool = args.check
    verbose: bool = args.verbose
    target_role: Optional[str] = args.role
    project_root: Optional[str] = args.project_root or os.environ.get("CLAUDE_PROJECT_DIR")

    if target_role:
        roles = [target_role]
    else:
        roles = _discover_roles()

    mode_label = "DRY-RUN/CHECK" if dry_run else "LIVE"
    _log(f"memory-maintain starting ({mode_label}) — roles: {roles or '(none)'}", always=True)

    all_ok = True

    if not roles:
        _log("no role directories found — skipping per-role operations", always=True)
    else:
        # Per-role operations
        for role in roles:
            ok = enforce_session_cap(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = enforce_playbook_cap(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = dedup_learnings(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = prune_orphan_learnings(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

    # Global operations — always run regardless of whether any role dirs exist.
    # These operate on global files (team-knowledge.md, decisions.md, index.md)
    # that are independent of per-role structure.
    ok = rotate_expired_decisions(dry_run=dry_run, verbose=verbose)
    all_ok = all_ok and ok

    ok = flag_stale_facts(dry_run=dry_run, verbose=verbose)
    all_ok = all_ok and ok

    ok = verify_index_integrity(project_root=project_root, dry_run=dry_run, verbose=verbose)
    all_ok = all_ok and ok

    if all_ok:
        _log("memory-maintain: all checks passed", always=True)
        return 0
    else:
        if dry_run:
            _log("memory-maintain: violations detected (--check mode — no changes written)", always=True)
        else:
            _log("memory-maintain: one or more operations failed", always=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
