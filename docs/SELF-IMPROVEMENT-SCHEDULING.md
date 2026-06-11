# Self-Improvement Scheduling

*How the ainous-team ensures consolidation, retrospectives, and coordinator self-assessment
actually happen in long-lived sessions — not just at session boundaries.*

---

## The problem: always-on coordinator, no task-completion boundary

Role agents (developer, tester, researcher, etc.) have a clean lifecycle: they are spawned for a
task, they complete it, and their `SubagentStop` hook fires. That hook runs the Stop-hook rituals
(journal entry, learnings capture, consolidation check). Session boundaries work fine for them.

The coordinator is different. It is the always-on main agent — it never "finishes a task" in the
way a spawned role does. Its session boundaries are `SessionStart` (fires when Claude Code opens)
and `SessionEnd` / coordinator Stop hook (fires when Claude Code closes or the session ends). In a
**long-lived single session** where the user never restarts Claude Code, those boundaries do not
fire. The result: consolidation, team retrospectives, and the coordinator's own journal/self-
assessment accumulate silently and never run.

This is not a theoretical gap. In practice, many users run a single Claude Code session for hours
or days without restarting. The Stop hook never fires. The `SessionStart` consolidation warning
only shows on restart. Self-improvement never happens.

---

## The solution: coordinator-armed durable cron + SessionStart floor

The fix uses two complementary mechanisms:

### 1. Coordinator-armed durable cron (the mid-session trigger)

At each session start, the coordinator checks `CronList` for a job whose prompt contains the
marker `[ainous-self-improve]`. If none exists, it calls `CronCreate` to register a daily durable
cron at 04:37 (off-minute — not :00, which is congested):

```
CronCreate(
  cron="37 4 * * *",
  recurring=true,
  durable=true,
  prompt="[ainous-self-improve] ..."
)
```

Claude Code fires cron prompts **while the REPL is idle** — not as a background daemon. This means
the cron fires mid-session (if the session is long enough and idle at 04:37), which is exactly the
gap the Stop hook misses. The durable flag means the job persists across restarts.

**7-day expiry and re-arming:** Claude Code durable crons expire after 7 days. Re-arming is handled
automatically: a fresh session that finds no `[ainous-self-improve]` job simply re-creates it. No
manual action needed, no coordinator drift possible.

**Coordinator-armed, not hook-armed:** The cron is created by the coordinator at runtime (a tool
call), not pre-registered in `hooks/session-start` or by a hook file. This is deliberate:
Claude Code's `scheduled_tasks.json` format includes runtime pid and session fields that a hook
cannot safely author. Only the LLM tool call path (`CronCreate`) produces a valid durable entry.
Hooks must not write `scheduled_tasks.json`.

### 2. SessionStart staleness reminder (the floor)

`hooks/session-start` already injects a consolidation staleness warning when it detects stale roles
on project open. This warning is the **floor** — it fires on restart after a gap, covering the case
where Claude Code was fully closed between sessions (cron doesn't fire when CC is closed; SessionStart
catch-up handles that). The warning is a reminder, not a block. The coordinator evaluates the gates
and decides whether to act.

The SessionStart text was updated in v5.20.0 to note that the periodic cron also runs mid-session,
so the user understands the full picture.

---

## How the reminder works

When the `[ainous-self-improve]` cron fires, the coordinator receives it as a queued prompt. It
evaluates three gates independently:

**Consolidation gate:**
- Check `last_consolidated` in `~/.claude/ainous-roles/*/playbook.md`
- Count unconsolidated journal entries in project journals
- Spawn `@consolidator` only if: (time >=24h OR sessions >=5) AND entries >=3 AND no concurrent lock
- The consolidator has its own triple-gate lock and self-skips if not due — no double-work risk

**Team retro gate:**
- Read `.claude/ainous-roles/coordinator/reviews.md` for last review date
- Count commits since: `git log --oneline --since="<date>" | wc -l`
- Run `/team-retro` only if 10+ commits or 7+ days have elapsed

**Coordinator journal/self-assessment gate:**
- Check the most recent entry date in `.claude/ainous-roles/coordinator/journal.md`
- Append one entry if more than ~24h have passed and there is something worth noting from recent
  sessions (non-filler; anti-soliloquy principle applies)

**If nothing is due:** do nothing. Silence is correct when all gates are cold.

**If mid-task:** defer all rituals to the next natural pause. Never interrupt active user work.

---

## Version-agnostic degradation contract

This feature follows the plugin's model/version-agnostic principle:

| Condition | Behavior |
|-----------|----------|
| `CronCreate`/`CronList` available | Full periodic reminder armed and firing |
| `CronCreate`/`CronList` unavailable (older Claude Code) | Skip silently — no error, no user-visible warning |
| Claude Code fully closed | Neither cron nor Stop hook fires; SessionStart catch-up handles this on restart |
| Session restarted within 7 days | Re-arm check finds existing job, skips CronCreate |
| Session restarted after 7 days | Re-arm check finds no job, re-creates it |
| Two sessions start simultaneously | Dedupe check can create at most 2 `[ainous-self-improve]` jobs; harmless — both expire within 7 days and all gates are idempotent |

The SessionStart reminder is always present regardless of cron availability. It is the floor that
guarantees at minimum one self-improvement **reminder** per session open — consolidation still
depends on the coordinator evaluating the gates and choosing to act.

---

## Honest limitation

**This is not a background daemon.** Claude Code crons fire only while Claude Code is open and the
REPL is idle. If the user closes Claude Code entirely (no session running), nothing fires. That is
the correct behavior — there is no persistent background process. The SessionStart catch-up on
the next open handles that gap.

This design is honest: the cron is an enhancement that catches mid-session gaps, not a scheduler
that guarantees wall-clock-aligned execution. The Stop hook and SessionStart reminder remain the
primary mechanisms; the cron adds robustness for the long-session case.

---

## Multi-repo & scope

**Trigger scope — project-local.** The `[ainous-self-improve]` durable cron is registered in
`<project>/.claude/scheduled_tasks.json`. Claude Code fires cron prompts only within the session
that created them; each repository arms its own cron in its own `scheduled_tasks.json`. There is no
cross-project firing — repo A's cron will not fire in a session open against repo B.

**Effect scope — global.** When the cron fires and the coordinator spawns `@consolidator`, the
consolidator reads role playbooks and journals from `~/.claude/ainous-roles/*/` (universal) and the
current project's `.claude/ainous-roles/*/` (project-local), then writes back to
`~/.claude/ainous-roles/*/playbook.md`. The write effect is global across all projects.

**Concurrent consolidation is safe.** `scripts/memory-maintain.py` (line 101) acquires an
`fcntl.flock` advisory lock before writing any playbook. If two consolidation runs are triggered
simultaneously (e.g., two repos both fire their cron within the same idle window), the second run
blocks until the first finishes. The lock prevents corruption; neither run is lost — the second
simply starts after the first has committed.

**Natural deduplication via global timestamp.** Each role's `playbook.md` frontmatter carries a
`last_consolidated` timestamp. The consolidator's triple gate requires `time >= 24h` (or
`sessions >= 5`) before running. If repo A fires first and updates `last_consolidated`, repo B's
consolidation run (arriving within 24h) will see a fresh timestamp and skip — no double work.

**Known subtle edge.** Because `last_consolidated` is global but journals are per-project, a
consolidation run from repo A can advance the global timestamp past repo B's unconsolidated
journal entries. If repo B has entries written before the consolidation, they will no longer
satisfy the `entry_date > last_consolidated` condition and may be silently skipped on repo B's
next consolidation cycle. This is not a new bug — it predates the cron, existing any time two
repos share global role state. The periodic cron makes this edge reachable more often. Mitigation:
run `/team-retro` or spawn `@consolidator` explicitly in each active repo before long idle periods.

**`scheduled_tasks.json` and gitignore.** Claude Code writes `scheduled_tasks.json` into
`<project>/.claude/` when a durable cron is registered. This file contains per-session pid and
runtime metadata — it must **not** be committed to a shared repository. The plugin ensures this via
a scoped `.claude/.gitignore` (not the repo root `.gitignore`):

- `scripts/setup.sh` creates or updates `.claude/.gitignore` to include `scheduled_tasks.json`
  during initial scaffolding.
- The coordinator's §5b arming step also checks and appends the entry if absent, protecting
  projects that did not run setup.
- `.claude/.gitignore` is honoured by git for paths under `.claude/` only and does not affect
  the rest of the repository.

---

## Compared to OpenClaw

OpenClaw (JiuwenClaw community release, 2026-03) achieves never-stop agent operation via a
**persistent background daemon** running on the user's own API keys — it stays alive regardless of
whether any UI is open, re-spawning after crashes, firing on wall-clock schedules.

The ainous-team's periodic self-improvement cron is **CC-scoped**: it fires only while Claude Code
is open and the REPL is idle. When Claude Code is fully closed, nothing fires. This is an
intentional design boundary — ainous-team does not bundle a background daemon, OS-level scheduler
(`launchd`, `cron`, `systemd`), or headless process.

If true never-stop self-improvement is wanted — cron firing even when CC is closed — the path is
an OS timer running `claude --print '<[ainous-self-improve] prompt>'` (subscription-backed,
headless). That is a user-level integration choice and is intentionally not bundled in this plugin.
The ainous-team's arming mechanism (`CronCreate`) is LLM-tool-only and cannot call OS schedulers.

---

## AutoDream overlap note

Anthropic's AutoDream (Claude Code v2.1.145+) provides platform-level memory consolidation triggered
by 24h idle or 5-session thresholds. AutoDream and the ainous-team's consolidator are complementary:
AutoDream consolidates Claude's own session memory; the ainous-team consolidator evolves structured
role playbooks, learnings.jsonl, and growth.json. Whether AutoDream's scan scope reaches
`.claude/ainous-roles/` is not publicly confirmed (see `docs/REFERENCES.md` — "AutoDream scan scope
is the key unknown"). The periodic self-improvement reminder is scoped to the ainous-team's own
knowledge surfaces and does not interact with AutoDream's consolidation path.
