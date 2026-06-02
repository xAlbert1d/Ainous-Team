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
import hashlib
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
ARCHIVE_SESSION_CAP = 500      # Maximum entries in sessions-archive.jsonl (cold storage)
PLAYBOOK_CAP = 30         # Maximum strategies in playbook.md
LEARNING_MIN_CONFIDENCE = 0.3  # Prune entries below this if not corroborated
DECISION_EXPIRY_DAYS = 90      # Rotate decisions older than this
ARCHIVE_DECISION_CAP = 200     # Maximum decision blocks in decisions-archive.md (cold storage)
STALE_FACT_DAYS = 180          # Flag facts older than this

# INDEX_SHRINK_MAX_FRACTION: refuse to write an index that would shrink by more than
# this fraction of original line count (fail-safe guard against wiping valid data).
INDEX_SHRINK_MAX_FRACTION = 0.30

# Trust level thresholds — derived from templates/authority-book.md.
# Level names match growth.json trust.level values (lowercase).
# Promotion gates require BOTH a minimum trust.score AND minimum sessions_completed
# AND zero violations in last 5 sessions (violations_detected checked globally here).
TRUST_LEVEL_ORDER = ["intern", "junior", "senior", "principal"]
TRUST_SCORE_FLOORS = {
    "intern":    0,
    "junior":   50,
    "senior":   75,
    "principal": 90,
}
# Minimum sessions_completed required to hold each level
TRUST_SESSION_FLOORS = {
    "intern":    0,
    "junior":    3,
    "senior":    8,
    "principal": 15,
}

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


def _acquire_advisory_lock(lock_path: pathlib.Path, max_age_seconds: int = 60) -> "tuple[bool, int]":
    """Acquire a file-based advisory lock.  Removes stale locks older than
    max_age_seconds.  Returns (acquired: bool, fd: int).  fd is -1 when not
    acquired.  Uses fcntl.flock for atomic acquisition on POSIX systems.
    Caller must pass fd to _release_advisory_lock when done.
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
# External-mutation detection
# ---------------------------------------------------------------------------

#: Files maintained per-role (relative names within GROWTH_DIR/<role>/).
#: team-knowledge.md lives at the root of GROWTH_DIR — handled separately.
_ROLE_MANAGED_FILES = ("playbook.md", "journal.md", "learnings.jsonl")

#: Heuristic: AutoDream's documented index line-limit.
_AUTODREAM_LINE_LIMIT = 200

#: Header comment we embed in plaintext managed files as a low-cost intent signal.
MANAGED_HEADER = "<!-- ainous-team managed memory — do not auto-prune; see docs/REFERENCES.md -->"


def _sha256_file(path: pathlib.Path) -> Optional[str]:
    """Return the hex SHA-256 digest of *path*, or None on I/O error."""
    try:
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def _line_count_file(path: pathlib.Path) -> int:
    """Return the number of lines in *path*, or -1 on I/O error."""
    try:
        return len(path.read_bytes().splitlines())
    except OSError:
        return -1


def detect_external_mutation(
    role: str,
    dry_run: bool = False,
    verbose: bool = False,
) -> bool:
    """Detect whether managed memory files were modified outside ainous-team.

    DETECTION ONLY — this function surfaces evidence of external mutation; it
    cannot prevent a background platform agent (such as Claude Code's AutoDream
    consolidator, whose scan scope is unverified) from editing files.  The
    intent is to make external changes visible so the operator/consolidator can
    review them before the next ainous-team write cycle overwrites the baseline.

    Algorithm
    ---------
    For each per-role managed file (playbook.md, journal.md, learnings.jsonl)
    and for team-knowledge.md at the GROWTH_DIR root:

    1. Read the stored baseline from ``GROWTH_DIR/<role>/.memory-baseline.json``.
    2. Compare the file's current sha256 / line_count against the baseline.
    3. If the content has changed AND the baseline recorded
       ``last_written_by_us: true`` (meaning ainous-team wrote it last and any
       change since must be external), emit a WARNING via _log(always=True).
       The warning names the file, the line-count delta, and the heuristic
       AutoDream signal when applicable.
    4. In --dry-run/--check mode: compare and report but do NOT update the
       baseline (caller must call update_external_mutation_baseline after the
       role's mutating operations complete).
    5. Fail-safe: any exception inside this function is caught; detection
       failure must NOT abort memory-maintain.

    The caller (main per-role loop) must call
    ``update_external_mutation_baseline(role)`` AFTER all mutating functions
    complete, so that our own writes do not trigger a false positive next run.

    Returns True always (detection is advisory; failures are logged).
    """
    try:
        baseline_path = GROWTH_DIR / role / ".memory-baseline.json"
        baseline: dict = {}
        if baseline_path.exists():
            try:
                baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as exc:
                _log(
                    f"detect_external_mutation({role}): cannot read baseline: {exc} — skipping check",
                    verbose,
                )
                return True

        # Build the list of (label, path) pairs to inspect.
        candidates: list[tuple[str, pathlib.Path]] = []
        for fname in _ROLE_MANAGED_FILES:
            p = GROWTH_DIR / role / fname
            if p.exists():
                candidates.append((fname, p))
        # team-knowledge.md lives at GROWTH_DIR root (not role-scoped)
        tk_path = GROWTH_DIR / "team-knowledge.md"
        if tk_path.exists():
            candidates.append(("team-knowledge.md", tk_path))

        for label, path in candidates:
            stored = baseline.get(label, {})
            if not stored:
                # First run — no baseline yet; skip warning, will be written after.
                _log(
                    f"detect_external_mutation({role}): no baseline for {label} — first run, will record",
                    verbose,
                )
                continue

            last_written_by_us = stored.get("last_written_by_us", False)
            if not last_written_by_us:
                # We did not write this file last — any change may be expected.
                _log(
                    f"detect_external_mutation({role}): {label} not marked last_written_by_us — skipping mutation check",
                    verbose,
                )
                continue

            stored_sha = stored.get("sha256", "")
            stored_lines = stored.get("line_count", -1)
            current_sha = _sha256_file(path)
            current_lines = _line_count_file(path)

            if current_sha is None:
                _log(
                    f"detect_external_mutation({role}): cannot read {label} for sha256 check",
                    verbose,
                )
                continue

            if current_sha == stored_sha:
                _log(
                    f"detect_external_mutation({role}): {label} unchanged since last ainous-team write",
                    verbose,
                )
                continue

            # Content changed since we wrote it — external modification detected.
            delta = (
                f"+{current_lines - stored_lines}"
                if stored_lines >= 0 and current_lines >= 0
                else "unknown"
            )
            autodream_note = ""
            if (
                stored_lines > _AUTODREAM_LINE_LIMIT
                and 0 <= current_lines <= _AUTODREAM_LINE_LIMIT + 5
            ):
                autodream_note = (
                    f"  [heuristic: file now at {current_lines} lines "
                    f"which matches AutoDream {_AUTODREAM_LINE_LIMIT}-line index limit]"
                )

            _log(
                f"WARNING: external modification detected for {path} "
                f"(role={role}, file={label}): "
                f"line_count {stored_lines} -> {current_lines} (delta {delta}).  "
                f"Modification occurred since last ainous-team write — "
                f"possible AutoDream/other background consolidation; "
                f"review before trusting.{autodream_note}",
                always=True,
            )

    except Exception as exc:  # pylint: disable=broad-except
        # Fail-safe: detection must never abort memory-maintain.
        _log(
            f"detect_external_mutation({role}): unexpected error (non-fatal): {exc}",
            always=True,
        )

    return True


def update_external_mutation_baseline(
    role: str,
    dry_run: bool = False,
    verbose: bool = False,
) -> None:
    """Write (or update) the per-role mutation-detection baseline.

    Records current sha256, line_count, and mtime for each managed file,
    and sets ``last_written_by_us: true`` so the next run knows ainous-team
    wrote these files last.

    Honors --dry-run/--check: in that mode the baseline is NOT written (we
    only reported, not mutated).

    Uses advisory lock + WAL pattern for the baseline write.
    Fail-safe: any exception is caught and logged; failures must not abort
    memory-maintain.
    """
    if dry_run:
        _log(
            f"update_external_mutation_baseline({role}): --dry-run — skipping baseline write",
            verbose,
        )
        return

    try:
        baseline_path = GROWTH_DIR / role / ".memory-baseline.json"
        lock_path = GROWTH_DIR / role / ".memory-baseline.lock"

        acquired, lock_fd = _acquire_advisory_lock(lock_path)
        if not acquired:
            _log(
                f"update_external_mutation_baseline({role}): could not acquire lock — skipping baseline write",
                always=True,
            )
            return

        try:
            # Re-read existing baseline so we don't lose entries for files that
            # may have disappeared between detect and update.
            existing: dict = {}
            if baseline_path.exists():
                try:
                    existing = json.loads(baseline_path.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError):
                    existing = {}

            candidates: list[tuple[str, pathlib.Path]] = []
            for fname in _ROLE_MANAGED_FILES:
                p = GROWTH_DIR / role / fname
                if p.exists():
                    candidates.append((fname, p))
            tk_path = GROWTH_DIR / "team-knowledge.md"
            if tk_path.exists():
                candidates.append(("team-knowledge.md", tk_path))

            updated = dict(existing)
            for label, path in candidates:
                sha = _sha256_file(path)
                lc = _line_count_file(path)
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    mtime = None
                updated[label] = {
                    "sha256": sha or "",
                    "line_count": lc,
                    "mtime": mtime,
                    "last_written_by_us": True,
                    "recorded_at": _ts(),
                }

            content = json.dumps(updated, indent=2) + "\n"
            baseline_path.parent.mkdir(parents=True, exist_ok=True)
            ok = _wal_write(baseline_path, content)
            if ok:
                _log(
                    f"update_external_mutation_baseline({role}): baseline updated for "
                    f"{[lbl for lbl, _ in candidates]}",
                    verbose,
                )
            else:
                _log(
                    f"update_external_mutation_baseline({role}): WAL write failed",
                    always=True,
                )
        finally:
            _release_advisory_lock(lock_path, lock_fd)

    except Exception as exc:  # pylint: disable=broad-except
        _log(
            f"update_external_mutation_baseline({role}): unexpected error (non-fatal): {exc}",
            always=True,
        )


# ---------------------------------------------------------------------------
# Protective header
# ---------------------------------------------------------------------------


def ensure_protective_header(
    path: pathlib.Path,
    dry_run: bool = False,
    verbose: bool = False,
) -> bool:
    """Prepend MANAGED_HEADER to *path* if it is absent.

    This is a low-cost intent signal for background agents such as AutoDream.
    Whether AutoDream honors it is unverified — the header documents intent and
    is harmless.  Only adds the header once; never duplicates.

    Uses WAL-safe write.  Honors --dry-run.
    Returns True on success or when no change was needed; False on I/O failure.
    """
    if not path.exists():
        return True
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"ensure_protective_header: cannot read {path}: {exc}", verbose)
        return False

    if MANAGED_HEADER in text:
        _log(f"ensure_protective_header: header already present in {path}", verbose)
        return True

    _log(f"ensure_protective_header: adding header to {path}", verbose, always=False)
    if dry_run:
        _log(f"[dry-run] would add protective header to {path}", always=True)
        return True  # Not a violation — this is additive and safe; don't penalize --check

    new_text = MANAGED_HEADER + "\n" + text
    return _wal_write(path, new_text)


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
    """Check (report only) whether playbook.md exceeds PLAYBOOK_CAP (30 strategies).

    Strategy detection: count H3 headings (### ) as strategy entries.
    This function REPORTS violations and logs them but does NOT auto-retire any
    strategy — retirement requires consolidator judgment about which entries have
    the lowest utility scores.  Returns False if cap exceeded so --check mode
    reports it.

    The consolidator must retire lowest-scoring strategies manually when this
    check fires.
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
    # Report only — do NOT auto-retire (retirement is consolidator judgment).
    _log(f"enforce_playbook_cap({role}): {count} strategies exceeds cap {PLAYBOOK_CAP} "
         f"({excess} over limit) — playbook over cap; consolidator must retire lowest-scoring entries",
         always=True)
    if dry_run:
        _log(f"[dry-run] would flag playbook cap violation for role={role}", always=True)
    return False  # Signal: action needed (manual consolidator retirement required)


# ---------------------------------------------------------------------------
# 3. dedup_learnings(role)
# ---------------------------------------------------------------------------


def dedup_learnings(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Deduplicate learnings.jsonl by (key, type) — keep highest-confidence entry.

    When two entries share the same (key, type), the one with the higher
    'confidence' value is kept.  If confidence values are equal (or absent),
    recency (last-written) wins.  This preference for confidence is a deliberate
    choice: a corroborated high-confidence entry is more valuable than a recent
    low-confidence one.

    Lifted from consolidator-instructions.md §Learnings Pruning.
    Uses WAL-safe write under advisory lock.
    """
    learnings_path = GROWTH_DIR / role / "learnings.jsonl"
    if not learnings_path.exists():
        _log(f"dedup_learnings({role}): learnings.jsonl not found — skipping", verbose)
        return True

    lock_path = GROWTH_DIR / role / "learnings-dedup.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log(f"dedup_learnings({role}): could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
        try:
            raw = learnings_path.read_text(encoding="utf-8")
        except OSError as exc:
            _log(f"dedup_learnings({role}): cannot read learnings.jsonl: {exc}", always=True)
            return False

        entries = []
        non_empty_lines = 0
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            non_empty_lines += 1
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                _log(f"dedup_learnings({role}): skipping malformed line", verbose)

        # N-3: if there were non-empty lines but none parsed, signal corruption
        if non_empty_lines > 0 and len(entries) == 0:
            _log(f"dedup_learnings({role}): all {non_empty_lines} non-empty line(s) failed to parse "
                 f"— file may be corrupt; skipping to avoid data loss", always=True)
            return False

        # Keep highest-confidence entry for each (key, type) pair.
        # Prefer confidence over recency; when confidence is equal, last-write wins
        # (last seen in the file wins because we iterate in order).
        seen: dict[tuple, dict] = {}
        for entry in entries:
            k = (entry.get("key", ""), entry.get("type", ""))
            if k not in seen:
                seen[k] = entry
            else:
                existing_conf = seen[k].get("confidence", 0.0) or 0.0
                new_conf = entry.get("confidence", 0.0) or 0.0
                if new_conf >= existing_conf:
                    # Equal confidence → last-write wins; higher → always replace
                    seen[k] = entry

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
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 4. prune_orphan_learnings(role)
# ---------------------------------------------------------------------------


def prune_orphan_learnings(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Prune learnings.jsonl entries whose referenced files no longer exist.

    An entry is orphaned if all paths in its 'files' array are non-empty and
    none of them exist on disk.  Entries with an empty 'files' array are kept.

    Lifted from consolidator-instructions.md §Learnings Pruning.
    Uses WAL-safe write under advisory lock.
    """
    learnings_path = GROWTH_DIR / role / "learnings.jsonl"
    if not learnings_path.exists():
        _log(f"prune_orphan_learnings({role}): learnings.jsonl not found — skipping", verbose)
        return True

    lock_path = GROWTH_DIR / role / "learnings-prune.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log(f"prune_orphan_learnings({role}): could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
        try:
            raw = learnings_path.read_text(encoding="utf-8")
        except OSError as exc:
            _log(f"prune_orphan_learnings({role}): cannot read learnings.jsonl: {exc}", always=True)
            return False

        entries = []
        non_empty_lines = 0
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            non_empty_lines += 1
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                _log(f"prune_orphan_learnings({role}): skipping malformed line", verbose)
                continue

        # N-3: if there were non-empty lines but none parsed, signal corruption
        if non_empty_lines > 0 and len(entries) == 0:
            _log(f"prune_orphan_learnings({role}): all {non_empty_lines} non-empty line(s) failed to parse "
                 f"— file may be corrupt; skipping to avoid data loss", always=True)
            return False

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
    finally:
        _release_advisory_lock(lock_path, lock_fd)


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

    lock_path = GROWTH_DIR / "authority" / "decisions-rotate.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log("rotate_expired_decisions: could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
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
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 5b. cap_sessions_archive(role)
# ---------------------------------------------------------------------------


def cap_sessions_archive(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Cap sessions-archive.jsonl to ARCHIVE_SESSION_CAP (500) entries.

    sessions-archive.jsonl is APPEND-only cold storage written by
    enforce_session_cap.  Without a cap it grows unbounded over hundreds of
    sessions.  This function keeps the NEWEST N entries and drops the oldest,
    mirroring the existing cap style:
      - WAL-safe (.new → verify → mv)
      - Advisory lock (sessions-archive-cap.lock)
      - --dry-run/--check honored (report but do not mutate)
      - Fail-safe skip on lock contention
    Returns True if within cap or successfully trimmed; False on error/dry-run violation.
    """
    archive_path = GROWTH_DIR / role / "sessions-archive.jsonl"
    if not archive_path.exists():
        _log(f"cap_sessions_archive({role}): sessions-archive.jsonl not found — skipping", verbose)
        return True

    try:
        raw = archive_path.read_text(encoding="utf-8")
    except OSError as exc:
        _log(f"cap_sessions_archive({role}): cannot read sessions-archive.jsonl: {exc}", always=True)
        return False

    lines = [l for l in raw.splitlines() if l.strip()]
    if len(lines) <= ARCHIVE_SESSION_CAP:
        _log(f"cap_sessions_archive({role}): {len(lines)} entries — within cap, nothing to do", verbose)
        return True

    excess = len(lines) - ARCHIVE_SESSION_CAP
    _log(
        f"cap_sessions_archive({role}): {len(lines)} archive entries exceeds cap "
        f"{ARCHIVE_SESSION_CAP} — dropping {excess} oldest",
        always=True,
    )

    if dry_run:
        _log(f"[dry-run] would drop {excess} oldest sessions-archive entries for role={role}", always=True)
        return False  # Signal: action needed

    lock_path = GROWTH_DIR / role / "sessions-archive-cap.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log(f"cap_sessions_archive({role}): could not acquire advisory lock — skipping", always=True)
        return False

    try:
        # Re-read under lock to avoid TOCTOU
        try:
            raw = archive_path.read_text(encoding="utf-8")
        except OSError as exc:
            _log(f"cap_sessions_archive({role}): re-read under lock failed: {exc}", always=True)
            return False

        lines = [l for l in raw.splitlines() if l.strip()]
        if len(lines) <= ARCHIVE_SESSION_CAP:
            _log(f"cap_sessions_archive({role}): after lock re-read — within cap, nothing to do", verbose)
            return True

        # Keep the newest ARCHIVE_SESSION_CAP entries (drop oldest from the front)
        kept = lines[-ARCHIVE_SESSION_CAP:]
        content = "\n".join(kept) + "\n"
        ok = _wal_write(archive_path, content)
        if ok:
            _log(
                f"cap_sessions_archive({role}): trimmed to {len(kept)} entries "
                f"(dropped {len(lines) - len(kept)} oldest)",
                verbose,
            )
        return ok
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 5c. cap_decisions_archive()
# ---------------------------------------------------------------------------


def cap_decisions_archive(dry_run: bool = False, verbose: bool = False) -> bool:
    """Cap decisions-archive.md to ARCHIVE_DECISION_CAP (200) decision blocks.

    decisions-archive.md is APPEND-only cold storage written by
    rotate_expired_decisions.  Without a cap it grows unbounded.  This function
    keeps the NEWEST N decision blocks and drops the oldest.

    A decision block starts with a line matching `- **role:**` (same delimiter
    used by rotate_expired_decisions and the live decisions parser).  Preamble
    lines (comments, headers) that appear before the first block are preserved.

    WAL-safe (.new → verify → mv), advisory lock, --dry-run/--check honored,
    fail-safe skip on lock contention.
    """
    archive_path = GROWTH_DIR / "authority" / "decisions-archive.md"
    if not archive_path.exists():
        _log("cap_decisions_archive: decisions-archive.md not found — skipping", verbose)
        return True

    lock_path = GROWTH_DIR / "authority" / "decisions-archive-cap.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log("cap_decisions_archive: could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
        try:
            text = archive_path.read_text(encoding="utf-8")
        except OSError as exc:
            _log(f"cap_decisions_archive: cannot read decisions-archive.md: {exc}", always=True)
            return False

        # Parse into preamble (pre-first-block) + blocks (same logic as rotate_expired_decisions)
        blocks: list[list[str]] = []
        current: list[str] = []
        preamble: list[str] = []
        in_blocks = False

        for line in text.splitlines(keepends=True):
            if not in_blocks and line.strip().startswith("- **role:**"):
                in_blocks = True
            if not in_blocks:
                preamble.append(line)
            elif line.strip().startswith("- **role:**") and current:
                blocks.append(current)
                current = [line]
            else:
                current.append(line)
        if current:
            blocks.append(current)

        if len(blocks) <= ARCHIVE_DECISION_CAP:
            _log(
                f"cap_decisions_archive: {len(blocks)} blocks — within cap, nothing to do",
                verbose,
            )
            return True

        excess = len(blocks) - ARCHIVE_DECISION_CAP
        _log(
            f"cap_decisions_archive: {len(blocks)} decision blocks exceeds cap "
            f"{ARCHIVE_DECISION_CAP} — dropping {excess} oldest",
            always=True,
        )

        if dry_run:
            _log(
                f"[dry-run] would drop {excess} oldest decisions-archive blocks",
                always=True,
            )
            return False  # Signal: action needed

        # Keep newest ARCHIVE_DECISION_CAP blocks (drop oldest from the front)
        kept_blocks = blocks[-ARCHIVE_DECISION_CAP:]
        new_content = "".join(preamble) + "".join("".join(b) for b in kept_blocks)
        ok = _wal_write(archive_path, new_content)
        if ok:
            _log(
                f"cap_decisions_archive: trimmed to {len(kept_blocks)} blocks "
                f"(dropped {excess} oldest)",
                verbose,
            )
        return ok
    finally:
        _release_advisory_lock(lock_path, lock_fd)


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
    Uses advisory lock for the read→WAL-write cycle.
    """
    tk_path = GROWTH_DIR / "team-knowledge.md"
    if not tk_path.exists():
        _log("flag_stale_facts: team-knowledge.md not found — skipping", verbose)
        return True

    lock_path = GROWTH_DIR / "team-knowledge-stale.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log("flag_stale_facts: could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
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
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 7. verify_index_integrity()
# ---------------------------------------------------------------------------


def verify_index_integrity(project_root: Optional[str] = None,
                           dry_run: bool = False,
                           verbose: bool = False) -> bool:
    """Verify that all entries in team-sync/index.md point to existing files.

    Broken entries are reported.  If not in dry_run mode, broken link substrings
    are removed from their lines (preserving valid co-located links on the same
    line).  The index is rewritten via WAL under an advisory lock.

    Relative paths are resolved against the index file's own directory
    (index_path.parent), not project_root — this correctly handles links like
    .claude/ainous-roles/team-sync/artifacts/foo.md that are relative to the
    index file's directory.

    Fail-safe guard: refuses to write an index that would shrink by more than
    INDEX_SHRINK_MAX_FRACTION (30%) of the original line count, unless every
    surviving line was validated clean.  Logs and skips instead of over-deleting.

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

    # Resolve base directory for relative links: index file's own directory
    index_dir = index_path.parent

    lock_path = index_path.parent / "index-integrity.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log("verify_index_integrity: could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than abort

    try:
        try:
            text = index_path.read_text(encoding="utf-8")
        except OSError as exc:
            _log(f"verify_index_integrity: cannot read index.md: {exc}", always=True)
            return False

        # Match markdown links: [label](path) — extract path
        link_re = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')
        broken_paths: set[str] = set()
        all_links: list[tuple[str, str]] = link_re.findall(text)

        for label, path in all_links:
            # Paths may be absolute, ~-relative, or relative to the index file's dir
            if path.startswith("/") or path.startswith("~"):
                check = pathlib.Path(os.path.expanduser(path))
            else:
                # M-1(b): resolve relative paths against index_path.parent, not project_root
                check = index_dir / path
            if not check.exists():
                broken_paths.add(path)
                _log(f"verify_index_integrity: broken link [{label}]({path})", verbose, always=True)

        if not broken_paths:
            _log(f"verify_index_integrity: all {len(all_links)} index entries are valid", verbose)
            return True

        _log(f"verify_index_integrity: {len(broken_paths)} broken index path(s) detected", always=True)
        if dry_run:
            _log(f"[dry-run] would remove {len(broken_paths)} broken index link(s)", always=True)
            return False

        # M-1(a): Remove only the broken link substring from each line, preserving
        # valid co-located links on the same line.
        original_lines = text.splitlines(keepends=True)
        new_lines: list[str] = []
        for line in original_lines:
            new_line = line
            for path in broken_paths:
                # Remove the specific [label](path) substring for this broken path.
                # We must escape the path in case it contains regex metacharacters.
                broken_link_re = re.compile(
                    r'\[[^\]]*\]\(' + re.escape(path) + r'\)',
                )
                new_line = broken_link_re.sub("", new_line)
            # Drop lines that are now empty (only whitespace) after link removal,
            # unless they were already empty before (preserve intentional blank lines).
            stripped_original = line.strip()
            stripped_new = new_line.strip()
            if stripped_original and not stripped_new:
                # Line had content but is now empty — it was only the broken link; drop it
                continue
            new_lines.append(new_line)

        # Fail-safe: refuse to write if the result shrinks the index by >30%
        original_count = len(original_lines)
        new_count = len(new_lines)
        if original_count > 0:
            shrink_fraction = (original_count - new_count) / original_count
            if shrink_fraction > INDEX_SHRINK_MAX_FRACTION:
                _log(
                    f"verify_index_integrity: refusing to write — would shrink index by "
                    f"{shrink_fraction:.0%} ({original_count} → {new_count} lines), "
                    f"exceeds {INDEX_SHRINK_MAX_FRACTION:.0%} safety threshold. "
                    f"Re-run with --check to inspect, then fix manually.",
                    always=True,
                )
                return False

        return _wal_write(index_path, "".join(new_lines))
    finally:
        _release_advisory_lock(lock_path, lock_fd)


# ---------------------------------------------------------------------------
# 8. trust_audit(role)
# ---------------------------------------------------------------------------


def _compute_justified_trust_level(history: dict, sessions_completed: int) -> Optional[str]:
    """Compute the maximum trust level justified by growth.json history.

    Returns the justified level string ("intern"/"junior"/"senior"/"principal"),
    or None if data is insufficient to make a determination.

    Trust thresholds (from templates/authority-book.md):
      - "intern":    score < 50, sessions >= 0  (always achievable; the floor)
      - "junior":    score >= 50, sessions >= 3
      - "senior":    score >= 75, sessions >= 8
      - "principal": score >= 90, sessions >= 15 (requires explicit user approval;
                     we never clamp to principal — if stored level is principal,
                     we treat it as a manual grant and leave it alone)

    Score reconstruction from history fields:
      trust_score = (sessions_completed * 2)
                  + approvals_granted
                  - (denials_received * 5)
                  - (violations_detected * 15)
                  - (user_overrides * 3)
      Capped 0-100.

    Insufficient-data conditions (return None):
      - history dict is None or not a dict
      - sessions_completed is negative or implausibly large (>10000)
    """
    if not isinstance(history, dict):
        return None
    if sessions_completed < 0 or sessions_completed > 10000:
        return None

    approvals = history.get("approvals_granted", 0) or 0
    denials = history.get("denials_received", 0) or 0
    violations = history.get("violations_detected", 0) or 0
    overrides = history.get("user_overrides", 0) or 0

    # Reconstruct score from history
    raw_score = (sessions_completed * 2) + approvals - (denials * 5) - (violations * 15) - (overrides * 3)
    reconstructed_score = max(0, min(100, raw_score))

    # Walk levels from highest to lowest, returning the first one that fits
    # Skip "principal" in the automated audit — principal requires explicit user
    # approval per authority-book.md and should never be auto-granted or auto-clamped
    # down by this tool (that would break a legitimately-granted principal).
    # If stored level is "principal", we leave it alone (see trust_audit logic).
    for level in reversed(TRUST_LEVEL_ORDER[:-1]):  # intern, junior, senior
        score_floor = TRUST_SCORE_FLOORS[level]
        session_floor = TRUST_SESSION_FLOORS[level]
        if reconstructed_score >= score_floor and sessions_completed >= session_floor:
            return level

    return "intern"  # Lowest floor always reachable


def trust_audit(role: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Audit trust.level in growth.json against what the role's history justifies.

    Clamps trust.level DOWN if the stored value exceeds the justified maximum
    (fail-safe — only demotes, never promotes).  WAL-writes under advisory lock.

    Never raises trust — raising stays consolidator judgment.
    If history is insufficient to determine justified level, leaves as-is and flags.
    If stored level is "principal" (requires explicit user approval), leaves as-is
    because principal is a manual grant that automated audit should not revoke.

    Honors --dry-run/--check (reports, does not mutate).
    Honors --growth-dir.
    """
    growth_path = GROWTH_DIR / role / "growth.json"
    if not growth_path.exists():
        _log(f"trust_audit({role}): growth.json not found — skipping", verbose)
        return True

    try:
        growth = json.loads(growth_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        _log(f"trust_audit({role}): cannot read growth.json: {exc}", always=True)
        return False

    trust = growth.get("trust", {})
    if not isinstance(trust, dict):
        _log(f"trust_audit({role}): trust field missing or malformed — skipping", always=True)
        return True

    stored_level = trust.get("level", "intern")
    if stored_level not in TRUST_LEVEL_ORDER:
        _log(f"trust_audit({role}): unknown stored trust level {stored_level!r} — skipping", always=True)
        return True

    # "principal" is a manually-granted level; do not auto-clamp it
    if stored_level == "principal":
        _log(f"trust_audit({role}): stored level is 'principal' (manual grant) — skipping auto-audit", verbose)
        return True

    history = trust.get("history", {})
    sessions_completed = history.get("sessions_completed", 0) or 0

    justified = _compute_justified_trust_level(history, sessions_completed)

    if justified is None:
        _log(
            f"trust_audit({role}): insufficient history data to determine justified level "
            f"(sessions_completed={sessions_completed}) — leaving as-is and flagging",
            always=True,
        )
        return True  # Leave as-is on uncertainty (fail-safe: don't clamp without evidence)

    stored_idx = TRUST_LEVEL_ORDER.index(stored_level)
    justified_idx = TRUST_LEVEL_ORDER.index(justified)

    if stored_idx <= justified_idx:
        # Stored level is at or below justified — no clamping needed
        _log(
            f"trust_audit({role}): stored level '{stored_level}' is within justified max "
            f"'{justified}' — OK",
            verbose,
        )
        return True

    # Stored level EXCEEDS justified maximum — clamp down (fail-safe)
    _log(
        f"trust_audit({role}): CLAMPING trust level '{stored_level}' → '{justified}' "
        f"(history justifies max '{justified}': sessions={sessions_completed}, "
        f"reconstructed score justifies '{justified}')",
        always=True,
    )

    if dry_run:
        _log(
            f"[dry-run] would clamp trust.level from '{stored_level}' to '{justified}' for role={role}",
            always=True,
        )
        return False  # Signal: action needed

    lock_path = GROWTH_DIR / role / "trust-audit.lock"
    acquired, lock_fd = _acquire_advisory_lock(lock_path)
    if not acquired:
        _log(f"trust_audit({role}): could not acquire advisory lock — skipping this run", always=True)
        return True  # Fail-safe: skip rather than silently leave wrong value

    try:
        # Re-read under lock to avoid TOCTOU
        try:
            growth = json.loads(growth_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            _log(f"trust_audit({role}): re-read under lock failed: {exc}", always=True)
            return False

        trust = growth.get("trust", {})
        if not isinstance(trust, dict):
            return True
        trust["level"] = justified
        growth["trust"] = trust

        content = json.dumps(growth, indent=2) + "\n"
        ok = _wal_write(growth_path, content)
        if ok:
            _log(f"trust_audit({role}): trust.level clamped to '{justified}' and written", always=True)
        return ok
    finally:
        _release_advisory_lock(lock_path, lock_fd)


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
            # --- External-mutation detection (MUST run first, before any mutating ops) ---
            detect_external_mutation(role, dry_run=dry_run, verbose=verbose)

            # --- Protective headers (additive intent signal; non-mutating in terms of caps) ---
            for _hdr_name in ("playbook.md",):
                _hdr_path = GROWTH_DIR / role / _hdr_name
                ensure_protective_header(_hdr_path, dry_run=dry_run, verbose=verbose)
            # team-knowledge.md lives at GROWTH_DIR root
            ensure_protective_header(GROWTH_DIR / "team-knowledge.md", dry_run=dry_run, verbose=verbose)

            ok = enforce_session_cap(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = enforce_playbook_cap(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = dedup_learnings(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = prune_orphan_learnings(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = trust_audit(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            ok = cap_sessions_archive(role, dry_run=dry_run, verbose=verbose)
            all_ok = all_ok and ok

            # --- Update baseline AFTER all mutating ops so our writes are recorded ---
            update_external_mutation_baseline(role, dry_run=dry_run, verbose=verbose)

    # Global operations — always run regardless of whether any role dirs exist.
    # These operate on global files (team-knowledge.md, decisions.md, index.md)
    # that are independent of per-role structure.
    ok = rotate_expired_decisions(dry_run=dry_run, verbose=verbose)
    all_ok = all_ok and ok

    ok = cap_decisions_archive(dry_run=dry_run, verbose=verbose)
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
