#!/usr/bin/env bash
# team-status.sh — Display persistent role growth metrics, history, and alerts
# Usage: ./scripts/team-status.sh [--history|--alerts]
set -euo pipefail

GLOBAL_ROLES_DIR="$HOME/.claude/ainous-roles"
PROJECT_ROLES_DIR="${PWD}/.claude/ainous-roles"
MODE="${1:-status}"

python3 - "$GLOBAL_ROLES_DIR" "$PROJECT_ROLES_DIR" "$MODE" << 'PYEOF'
import json, glob, os, sys
from datetime import datetime

global_dir = sys.argv[1]
project_dir = sys.argv[2]
mode = sys.argv[3]

use_color = sys.stdout.isatty()

def c(code, text):
    return f"\033[{code}m{text}\033[0m" if use_color else text

def bold(t): return c("1", t)
def dim(t): return c("2", t)
def green(t): return c("32", t)
def yellow(t): return c("33", t)
def red(t): return c("31", t)
def cyan(t): return c("36", t)

def cpad(text, width, color_fn=None):
    padded = text[:width].ljust(width)
    return color_fn(padded) if color_fn else padded

# Collect growth data
roles = {}
for path in sorted(glob.glob(os.path.join(global_dir, "*/growth.json"))):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        roles[data["role"]] = data
    except (json.JSONDecodeError, KeyError, IOError):
        role_name = os.path.basename(os.path.dirname(path))
        roles[role_name] = None

# Collect project journal status
journals = set()
for path in glob.glob(os.path.join(project_dir, "*/journal.md")):
    role_name = os.path.basename(os.path.dirname(path))
    journals.add(role_name)

if not roles:
    print("No roles found in", global_dir)
    sys.exit(1)

sep = "  "

# ─── STATUS MODE (default) ───────────────────────────────────────────

if mode == "status":
    hdr = ["Role", "Trust", "Metric", "Sessions", "Score", "Trend", "Journal"]
    widths = [14, 8, 26, 8, 7, 8, 7]

    def trend_text(t):
        if t == "improving": return "up"
        if t == "declining": return "down"
        return "flat"

    def trend_color(t):
        if t == "improving": return green
        if t == "declining": return red
        return dim

    def trust_color(level):
        if level == "principal": return green
        if level == "senior": return cyan
        if level == "intern": return red
        return None  # junior = default

    print()
    print(bold("  Team Role Status"))
    print(bold("  ================"))
    print()
    print(sep.join(cpad(h, w, bold) for h, w in zip(hdr, widths)))
    print(sep.join("-" * w for w in widths))

    for role_name in sorted(roles.keys()):
        data = roles[role_name]
        if data is None:
            print(sep.join([cpad(role_name, widths[0])] + [cpad("-", w, dim) for w in widths[1:]]))
        else:
            s = data.get("summary", {})
            t = data.get("trust", {})
            sessions = s.get("total_sessions", 0)
            avg = s.get("avg_score", 0)
            trend = s.get("trend", "neutral")
            trust_level = t.get("level", "?")

            cols = [
                cpad(role_name, widths[0], cyan),
                cpad(trust_level, widths[1], trust_color(trust_level)),
                cpad(data.get("metric", "?"), widths[2]),
                cpad(str(sessions), widths[3]),
                cpad(f"{avg:.1f}" if sessions > 0 else "n/a", widths[4], None if sessions > 0 else dim),
                cpad(trend_text(trend), widths[5], trend_color(trend)),
                cpad("yes" if role_name in journals else "no", widths[6], green if role_name in journals else dim),
            ]
            print(sep.join(cols))

    print()
    total = len(roles)
    active = sum(1 for d in roles.values() if d and d.get("summary", {}).get("total_sessions", 0) > 0)
    with_journals = len(journals)
    print(f"  {bold(str(total))} roles  |  {bold(str(active))} active  |  {bold(str(with_journals))} with journals")
    print()

# ─── HISTORY MODE ─────────────────────────────────────────────────────

elif mode == "--history":
    print()
    print(bold("  Session History (last 5 per role)"))
    print(bold("  ================================="))

    for role_name in sorted(roles.keys()):
        data = roles[role_name]
        if data is None:
            continue
        sessions = data.get("sessions", [])
        if not sessions:
            continue

        print()
        print(f"  {cyan(role_name)} ({data.get('metric', '?')})")

        recent = sessions[-5:]
        prev_score = None
        for s in recent:
            score = s.get("score", 0)
            user_score = s.get("user_score")
            date = s.get("date", "?")
            task = s.get("task", "?")[:55]
            strategies = s.get("strategies_used", [])
            strat_str = ", ".join(strategies) if strategies else dim("none")

            if prev_score is not None:
                if score > prev_score: arrow = green("^")
                elif score < prev_score: arrow = red("v")
                else: arrow = dim("=")
            else:
                arrow = " "

            score_str = f"{score}/10"
            if user_score is not None:
                score_str += f" (user: {user_score})"

            print(f"    {arrow} {dim(date)}  {bold(score_str)}  {task}")
            if strategies:
                print(f"      strategies: {strat_str}")
            prev_score = score

    print()

# ─── ALERTS MODE ──────────────────────────────────────────────────────

elif mode == "--alerts":
    print()
    print(bold("  Team Alerts"))
    print(bold("  ==========="))
    print()

    alerts = []

    for role_name in sorted(roles.keys()):
        data = roles[role_name]
        if data is None:
            alerts.append(("HIGH", role_name, "growth.json is corrupt or unreadable"))
            continue

        s = data.get("summary", {})
        t = data.get("trust", {})
        sessions = data.get("sessions", [])
        total = s.get("total_sessions", 0)
        avg = s.get("avg_score", 0)
        trust_level = t.get("level", "unknown")
        trust_score = t.get("score", 0)

        # Never used
        if total == 0:
            alerts.append(("LOW", role_name, "never used (0 sessions)"))

        # Trust below junior threshold
        if trust_score < 50:
            alerts.append(("HIGH", role_name, f"trust score {trust_score} — below Junior threshold (50)"))

        # Declining trend
        if len(sessions) >= 3:
            recent_avg = sum(sess.get("score", 0) for sess in sessions[-3:]) / 3
            if avg > 0 and recent_avg < avg - 1.0:
                alerts.append(("MED", role_name, f"declining: recent avg {recent_avg:.1f} vs overall {avg:.1f}"))

        # Score miscalibration (user vs self divergence)
        for sess in sessions[-3:]:
            user_s = sess.get("user_score")
            self_s = sess.get("score", 0)
            if user_s is not None and abs(user_s - self_s) > 2:
                alerts.append(("MED", role_name, f"score miscalibration: self={self_s}, user={user_s}"))
                break

        # Stale consolidation (playbook not updated in 7+ days)
        playbook_path = os.path.join(global_dir, role_name, "playbook.md")
        try:
            with open(playbook_path, encoding='utf-8') as pf:
                for line in pf:
                    if line.startswith("last_consolidated:"):
                        last_cons = line.split(":", 1)[1].strip()
                        if last_cons and last_cons != "never":
                            try:
                                # BUG-3 FIX: extract leading YYYY-MM-DD regardless of separator
                                import re as _re
                                _m = _re.match(r'(\d{4}-\d{2}-\d{2})', last_cons)
                                _lc = _m.group(1) if _m else last_cons.split("T")[0].split(" ")[0].split("-consolidation")[0]
                                cons_date = datetime.strptime(_lc, "%Y-%m-%d").date()
                                if (datetime.now().date() - cons_date).days > 1:
                                    alerts.append(("MED", role_name, f"consolidation stale (last: {last_cons})"))
                            except ValueError:
                                pass
                        break
        except FileNotFoundError:
            pass

        # No journal in this project
        if total > 0 and role_name not in journals:
            alerts.append(("LOW", role_name, "active but no journal in this project"))

    if not alerts:
        print(f"  {green('No alerts.')} All roles healthy.")
    else:
        for severity, role, msg in alerts:
            if severity == "HIGH":
                icon = red("[HIGH]")
            elif severity == "MED":
                icon = yellow("[MED] ")
            else:
                icon = dim("[LOW] ")
            print(f"  {icon}  {cyan(role)}: {msg}")

    print()

else:
    print(f"Unknown mode: {mode}")
    print("Usage: team-status.sh [--history|--alerts]")
    sys.exit(1)
PYEOF
