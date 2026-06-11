#!/usr/bin/env python3
"""
self-improve-check.py — single source of truth for "is self-improvement due?"

Public API (importable):
    check_consolidation(root, home) -> dict
    check_retro(root) -> dict
    check_journal(root) -> dict
    check_all(root, home) -> dict

CLI:
    python3 scripts/self-improve-check.py [--root DIR] [--home DIR] [--json]

Exit code: always 0 (fail-open).

THRESHOLDS (canonical — reconciles session-start + cron prose):
  consolidation_due:
      some role has unconsolidated >= 3 AND
      (hours_since_last_consolidated >= 24 OR never consolidated)
      NOTE: the consolidator's own gate also allows ">= 5 sessions since last
      consolidation", but session-count is NOT derivable from the date-granularity
      data this detector reads (playbook last_consolidated + dated journal entries).
      It is also unreachable here: >= 3 unconsolidated entries must be dated strictly
      after last_consolidated, which already forces hours_since >= 24. This detector
      therefore implements (hours >= 24 OR never) AND volume >= 3; the consolidator
      still applies its own session-aware self-gate + lock when actually invoked.
      "really_critical": days_stale > 2   (used by session-start for "CRITICAL" text)
      "stale_roles":     days_stale 1..2  (used by session-start for "Reminder" text)

  retro_due:
      days_since_last_retro >= 7 OR commits_since_last_retro >= 10
      Reviews file: .claude/ainous-roles/coordinator/reviews.md
      Git commit count: only if cwd is a git repo (else commits_since = null)

  journal_due:
      coordinator journal most-recent entry is >= 24h old
      (or journal absent but role/session activity exists)
      Journal file: .claude/ainous-roles/coordinator/journal.md
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Internal helpers — all fail-open (no exceptions propagate to callers)
# ---------------------------------------------------------------------------

_DATE_HEADING_RE = re.compile(r'^## (\d{4}-\d{2}-\d{2})(?:\s|$|—|-)')


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _parse_date(s) -> "datetime | None":
    """Parse a YYYY-MM-DD (or YYYY-MM-DD...) string to a date.
    Returns None on any failure — never raises."""
    if not s or not isinstance(s, str):
        return None
    try:
        m = re.match(r'(\d{4}-\d{2}-\d{2})', s.strip())
        if not m:
            return None
        return datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def _read_text(path) -> str:
    """Read a file's text content; return '' on any error."""
    try:
        with open(path, encoding='utf-8') as f:
            return f.read()
    except OSError:
        return ''


def _hours_since(dt: "datetime | None") -> "float | None":
    if dt is None:
        return None
    try:
        delta = _now_utc() - dt
        return delta.total_seconds() / 3600.0
    except (TypeError, OverflowError):
        return None


def _days_since(dt: "datetime | None") -> "int | None":
    if dt is None:
        return None
    try:
        delta = _now_utc() - dt
        return int(delta.total_seconds() / 86400)
    except (TypeError, OverflowError):
        return None


def _count_unconsolidated(journal_path, last_cons_str) -> int:
    """Count journal entries (## YYYY-MM-DD headings) newer than last_cons_str.
    If last_cons_str is None all date-headings are counted. Never raises."""
    count = 0
    try:
        with open(journal_path, encoding='utf-8') as f:
            for line in f:
                if not line.startswith("## "):
                    continue
                m = _DATE_HEADING_RE.match(line)
                if not m:
                    continue
                entry_date = m.group(1)
                if last_cons_str:
                    if entry_date > last_cons_str:
                        count += 1
                else:
                    count += 1
    except OSError:
        pass
    return count


def _git_commits_since(cwd, since_date_str) -> "int | None":
    """Count git commits since `since_date_str` (YYYY-MM-DD) in `cwd`.
    Returns None if cwd is not a git repo or git fails. Never raises."""
    if not since_date_str:
        return None
    try:
        result = subprocess.run(
            ["git", "log", "--oneline", f"--since={since_date_str}"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return None
        lines = [l for l in result.stdout.splitlines() if l.strip()]
        return len(lines)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError):
        return None


def _is_git_repo(cwd) -> bool:
    """Return True if cwd is inside a git repository. Never raises."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError, ValueError, TypeError):
        return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def check_consolidation(root: str, home: str) -> dict:
    """
    Check whether consolidation is due for any role.

    CANONICAL TRIPLE-GATE (matches consolidator-instructions.md):
      Time gate:   hours_since_last_consolidated >= 24  OR  never consolidated
                   (the consolidator's ">= 5 sessions" path is deferred to its own
                    self-gate; session-count is not derivable from date-granularity
                    data here, and is unreachable anyway — see module docstring)
      Volume gate: unconsolidated >= 3
      Lock gate:   NOT checked here (consolidator enforces it; we just detect need)

    Additionally categorises roles for session-start reminder wording:
      really_critical: days_stale > 2 (and unconsolidated >= 3)
      stale_roles:     days_stale 1..2 (and unconsolidated >= 3)

    root: project root (cwd for project journals)
    home: $HOME (for ~/.claude/ainous-roles/<role>/playbook.md)

    Returns a stable dict; never raises.
    """
    result = {
        "due": False,
        "really_critical": [],
        "stale_roles": [],
        "reason": "no roles checked",
    }

    try:
        roles_dir = os.path.join(home, ".claude", "ainous-roles")
        project_roles_dir = os.path.join(root, ".claude", "ainous-roles")

        playbooks = glob.glob(os.path.join(roles_dir, "*/playbook.md"))
        if not playbooks:
            result["reason"] = "no playbooks found"
            return result

        any_due = False

        for playbook in playbooks:
            try:
                role = os.path.basename(os.path.dirname(playbook))
                last_cons_str = None
                days_stale = None

                # Parse last_consolidated from playbook frontmatter
                try:
                    with open(playbook, encoding='utf-8') as f:
                        for line in f:
                            if line.startswith("last_consolidated:"):
                                val = line.split(":", 1)[1].strip()
                                if val and val not in ("never", "null"):
                                    dt = _parse_date(val)
                                    if dt is not None:
                                        last_cons_str = dt.strftime("%Y-%m-%d")
                                        days_stale = _days_since(dt)
                                break
                except OSError:
                    pass

                # Count unconsolidated project journal entries
                journal_path = os.path.join(project_roles_dir, role, "journal.md")
                unconsolidated = _count_unconsolidated(journal_path, last_cons_str)

                # Volume gate: must have >= 3 unconsolidated
                if unconsolidated < 3:
                    continue

                # Time gate: >= 24h since last consolidation OR last_cons_str is None
                hours_since = None
                if last_cons_str:
                    dt = _parse_date(last_cons_str)
                    hours_since = _hours_since(dt)

                time_gate_passes = (hours_since is None) or (hours_since >= 24)

                if not time_gate_passes:
                    continue

                # This role is due for consolidation
                any_due = True

                # Categorise for session-start reminder wording
                if days_stale is not None:
                    if days_stale > 2:
                        result["really_critical"].append(role)
                    elif days_stale > 1:
                        result["stale_roles"].append(role)
                    # days_stale <= 1 but unconsolidated >= 3 and hours >= 24:
                    # still due (time gate passes) but not in the named-role buckets

            except (ValueError, TypeError, OSError):
                continue

        result["due"] = any_due
        if any_due:
            parts = []
            if result["really_critical"]:
                parts.append(
                    f"CRITICAL roles (>2d stale): {', '.join(result['really_critical'][:5])}"
                )
            if result["stale_roles"]:
                parts.append(
                    f"stale roles (1-2d): {', '.join(result['stale_roles'][:5])}"
                )
            result["reason"] = "; ".join(parts) if parts else "consolidation due (time+volume gate passed)"
        else:
            result["reason"] = "consolidation not due (all gates cold)"

    except (ValueError, TypeError, OSError):
        result["reason"] = "error during consolidation check; treated as not due"

    return result


def check_retro(root: str) -> dict:
    """
    Check whether a team retro is due.

    Retro is due if:
      days_since_last_retro >= 7  OR  commits_since_last_retro >= 10

    Reviews file: .claude/ainous-roles/coordinator/reviews.md
    Commits: git log --oneline --since=<date> (only if root is a git repo)

    Returns a stable dict; never raises.
    """
    result = {
        "due": False,
        "days_since": None,
        "commits_since": None,
        "reason": "no review date found",
    }

    try:
        reviews_path = os.path.join(root, ".claude", "ainous-roles", "coordinator", "reviews.md")
        content = _read_text(reviews_path)

        # Find the most recent ## YYYY-MM-DD heading in reviews.md
        last_review_dt = None
        last_review_str = None
        for line in content.splitlines():
            if not line.startswith("## "):
                continue
            m = _DATE_HEADING_RE.match(line)
            if m:
                candidate = m.group(1)
                if last_review_str is None or candidate > last_review_str:
                    last_review_str = candidate
                    last_review_dt = _parse_date(candidate)

        days = _days_since(last_review_dt)
        result["days_since"] = days

        # Git commit count since last review
        commits = None
        try:
            if last_review_str and _is_git_repo(root):
                commits = _git_commits_since(root, last_review_str)
        except (OSError, ValueError, TypeError):
            commits = None
        result["commits_since"] = commits

        # Determine if due
        date_due = (days is None) or (days >= 7)
        commits_due = (commits is not None) and (commits >= 10)

        if content.strip() == "" or last_review_str is None:
            # No reviews file or empty — treat as no retro ever done; not auto-due
            result["due"] = False
            result["reason"] = "no reviews.md found; retro not yet tracked"
        elif date_due or commits_due:
            result["due"] = True
            parts = []
            if days is not None and days >= 7:
                parts.append(f"{days}d since last retro")
            elif days is None:
                parts.append("retro date unknown")
            if commits is not None and commits >= 10:
                parts.append(f"{commits} commits since last retro")
            result["reason"] = "; ".join(parts) if parts else "retro due"
        else:
            result["due"] = False
            parts = []
            if days is not None:
                parts.append(f"{days}d since last retro")
            if commits is not None:
                parts.append(f"{commits} commits since")
            result["reason"] = "retro not due (" + ("; ".join(parts) if parts else "within thresholds") + ")"

    except (ValueError, TypeError, OSError):
        result["reason"] = "error during retro check; treated as not due"

    return result


def check_journal(root: str) -> dict:
    """
    Check whether the coordinator should append a journal entry.

    Journal is due if the most recent ## YYYY-MM-DD entry is >= 24h old,
    or if there is no journal yet but role/session activity exists.

    Journal file: .claude/ainous-roles/coordinator/journal.md

    Returns a stable dict; never raises.
    """
    result = {
        "due": False,
        "hours_since": None,
        "reason": "no journal found",
    }

    try:
        journal_path = os.path.join(
            root, ".claude", "ainous-roles", "coordinator", "journal.md"
        )
        content = _read_text(journal_path)

        # Find the most recent date-headed entry
        last_entry_str = None
        for line in content.splitlines():
            if not line.startswith("## "):
                continue
            m = _DATE_HEADING_RE.match(line)
            if m:
                candidate = m.group(1)
                if last_entry_str is None or candidate > last_entry_str:
                    last_entry_str = candidate

        if not content.strip() or last_entry_str is None:
            # No journal or no date entries — check if there is any role activity
            project_roles_dir = os.path.join(root, ".claude", "ainous-roles")
            has_activity = False
            try:
                if os.path.isdir(project_roles_dir):
                    for role_dir in os.listdir(project_roles_dir):
                        role_journal = os.path.join(
                            project_roles_dir, role_dir, "journal.md"
                        )
                        if os.path.isfile(role_journal):
                            has_activity = True
                            break
            except OSError:
                pass

            if has_activity:
                result["due"] = True
                result["reason"] = "no coordinator journal but role activity exists"
            else:
                result["due"] = False
                result["reason"] = "no coordinator journal and no role activity"
            return result

        last_entry_dt = _parse_date(last_entry_str)
        hours = _hours_since(last_entry_dt)
        result["hours_since"] = hours

        if hours is None or hours >= 24:
            result["due"] = True
            result["reason"] = (
                f"most recent coordinator journal entry is "
                f"{round(hours, 1) if hours is not None else 'unknown'}h old (>= 24h threshold)"
            )
        else:
            result["due"] = False
            result["reason"] = (
                f"coordinator journal is current ({round(hours, 1)}h since last entry)"
            )

    except (ValueError, TypeError, OSError):
        result["reason"] = "error during journal check; treated as not due"

    return result


def check_all(root: str, home: str) -> dict:
    """
    Run all three checks and return a stable, JSON-able aggregate dict.

    Schema:
    {
      "consolidation_due": bool,
      "retro_due": bool,
      "journal_due": bool,
      "any_due": bool,
      "consolidation": { "due": bool, "really_critical": [...], "stale_roles": [...], "reason": str },
      "retro":         { "due": bool, "days_since": int|null, "commits_since": int|null, "reason": str },
      "journal":       { "due": bool, "hours_since": float|null, "reason": str }
    }

    Always returns a valid dict; never raises.
    """
    try:
        consolidation = check_consolidation(root, home)
    except Exception:
        consolidation = {"due": False, "really_critical": [], "stale_roles": [], "reason": "check failed"}

    try:
        retro = check_retro(root)
    except Exception:
        retro = {"due": False, "days_since": None, "commits_since": None, "reason": "check failed"}

    try:
        journal = check_journal(root)
    except Exception:
        journal = {"due": False, "hours_since": None, "reason": "check failed"}

    return {
        "consolidation_due": bool(consolidation.get("due", False)),
        "retro_due": bool(retro.get("due", False)),
        "journal_due": bool(journal.get("due", False)),
        "any_due": bool(
            consolidation.get("due", False)
            or retro.get("due", False)
            or journal.get("due", False)
        ),
        "consolidation": consolidation,
        "retro": retro,
        "journal": journal,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _human_summary(result: dict) -> str:
    lines = []
    lines.append("self-improve-check summary:")

    c = result["consolidation"]
    label = "DUE" if result["consolidation_due"] else "not due"
    lines.append(f"  consolidation: {label} — {c.get('reason', '')}")
    if c.get("really_critical"):
        lines.append(f"    CRITICAL roles: {', '.join(c['really_critical'])}")
    if c.get("stale_roles"):
        lines.append(f"    stale roles: {', '.join(c['stale_roles'])}")

    r = result["retro"]
    label = "DUE" if result["retro_due"] else "not due"
    lines.append(f"  retro:         {label} — {r.get('reason', '')}")

    j = result["journal"]
    label = "DUE" if result["journal_due"] else "not due"
    lines.append(f"  journal:       {label} — {j.get('reason', '')}")

    lines.append(f"  any_due: {result['any_due']}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check whether ainous-team self-improvement is due.",
        add_help=True,
    )
    parser.add_argument(
        "--root",
        default=None,
        help="Project root directory (default: current working directory)",
    )
    parser.add_argument(
        "--home",
        default=None,
        help="Home directory for ~/.claude/ainous-roles (default: $HOME)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="output_json",
        help="Print JSON result instead of human summary",
    )

    args = parser.parse_args(argv)

    root = args.root if args.root else os.getcwd()
    home = args.home if args.home else os.path.expanduser("~")

    try:
        result = check_all(root, home)
    except Exception:
        # Absolute last-resort fail-open
        result = {
            "consolidation_due": False,
            "retro_due": False,
            "journal_due": False,
            "any_due": False,
            "consolidation": {"due": False, "really_critical": [], "stale_roles": [], "reason": "unexpected error"},
            "retro": {"due": False, "days_since": None, "commits_since": None, "reason": "unexpected error"},
            "journal": {"due": False, "hours_since": None, "reason": "unexpected error"},
        }

    if args.output_json:
        print(json.dumps(result, indent=2))
    else:
        print(_human_summary(result))

    # Always exit 0 — callers read the JSON, not the exit code
    sys.exit(0)


if __name__ == "__main__":
    main()
