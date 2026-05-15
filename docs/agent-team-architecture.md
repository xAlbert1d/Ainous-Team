# Agent Team Architecture Guide

A reference architecture for running Claude Code agent teams with tmux-claude-monitor, drawing from OpenClaw's multi-agent patterns and PARA/CODE knowledge management principles.

## Core Principles

### From OpenClaw: Declarative Swarm Orchestration

OpenClaw's breakthrough is treating multi-agent coordination as a declarative config problem, not an imperative coding one. Apply this to Claude Code teams:

1. **Define roles, not steps** — each teammate owns a domain, not a sequence
2. **Shared knowledge, independent context** — teammates read the same CLAUDE.md but have separate context windows
3. **Conflict resolution by boundary** — assign file ownership, never share files between teammates
4. **Exhaust single-agent first** — "Before adding agents, exhaust the capabilities of a single agent" (OpenClaw guide)

### From PARA: Organize Knowledge for Action

Tiago Forte's PARA method organizes information by *actionability*:

| Category | In Agent Teams | Example |
|----------|---------------|---------|
| **Projects** | Active tasks with deadlines | "Implement payment module by Friday" |
| **Areas** | Ongoing responsibilities per teammate | "Security reviewer owns auth/ directory" |
| **Resources** | Shared reference material | CLAUDE.md, API docs, style guides |
| **Archives** | Completed work for reference | Previous PRs, design specs, old sessions |

**Apply to CLAUDE.md:**
```
# Project: tmux-claude-monitor v1.1
Active tasks: see task list (Ctrl+T)

# Areas (teammate ownership)
- scripts/*.py → Code Quality teammate
- tests/*.py → Testing teammate
- README.md, docs/ → Documentation teammate

# Resources
- Design spec: docs/specs/2026-03-30-tmux-claude-monitor-design.md
- Python style: PEP 8, stdlib only, no external deps
- tmux API: man tmux, display-popup, status-left/right

# Archives
- v1.0 implementation: git log (commits 02c25aa..91f531f)
```

### From CODE: Capture → Organize → Distill → Express

The CODE method describes how knowledge flows. Map it to agent team workflow:

| Phase | Agent Team Action | Who |
|-------|------------------|-----|
| **Capture** | Gather findings, discoveries, issues | Each teammate independently |
| **Organize** | Post to shared task list with severity/category | Each teammate |
| **Distill** | Synthesize across all findings, identify patterns | Lead agent |
| **Express** | Produce final report, PR, or commit | Lead agent |

## Architecture

### Team Topology

```
┌─────────────────────────────────────────────────────────┐
│ tmux session                                             │
├──────────────────┬──────────────────┬───────────────────┤
│ Pane 0: Lead     │ Pane 1: Worker A │ Pane 2: Worker B  │
│                  │                  │                   │
│ Coordinates      │ Owns: scripts/   │ Owns: tests/      │
│ Reviews results  │ Focus: quality   │ Focus: coverage   │
│ Synthesizes      │                  │                   │
├──────────────────┴──────────────────┴───────────────────┤
│ Pane 3: Worker C                                         │
│ Owns: docs/, README.md                                   │
│ Focus: documentation                                     │
└─────────────────────────────────────────────────────────┘
│                                                           │
│ tmux-claude-monitor (daemon)                              │
│ ├── Status bar: [3 ● 1 ○ │ 450K (45%) │ ●]             │
│ └── Popup (Ctrl+b u): per-pane context, tokens, rate    │
└───────────────────────────────────────────────────────────┘
```

### Communication Flow

```
Lead ←── task list ──→ Workers
  │                       │
  ├── message(worker) ────┤  (direct messaging)
  │                       │
  ├── broadcast() ────────┤  (rare, for course corrections)
  │                       │
  └── Ctrl+T ─────────────┘  (shared task view)
```

### File System Layout

```
~/.claude/
├── projects/
│   └── your-project-name/
│       ├── <lead-session-id>.jsonl          ← lead's log
│       ├── <worker-a-session-id>.jsonl      ← worker A's log
│       ├── <worker-b-session-id>.jsonl      ← worker B's log
│       └── <worker-c-session-id>.jsonl      ← worker C's log
├── teams/
│   └── <team-name>/
│       └── config.json                      ← team membership
└── tasks/
    └── <team-name>/                         ← shared task list
```

## Team Patterns

### Pattern 1: Code Review Team (Recommended First Test)

Best for: reviewing PRs, auditing codebases, security review

```
Prompt to lead:
"Create a team to review the tmux-claude-monitor codebase:

Teammate 1 (Robustness): Review scripts/ for edge cases, error handling,
  race conditions. Focus on daemon.py and process_scanner.py.

Teammate 2 (Testing): Review test coverage gaps. Add tests for:
  display_name generation, stale session filtering, context_used tracking,
  daemon restart behavior.

Teammate 3 (Docs): Update README.md with new features: context window
  display, Ctrl+b U restart, stale filtering, popup keybindings.

File ownership: scripts/ → T1, tests/ → T2, README.md + docs/ → T3."
```

### Pattern 2: Feature Development Team

Best for: new features with clear module boundaries

```
"Create a team to add session history tracking:

Teammate 1 (Backend): Add scripts/history.py — store daily token
  summaries to ~/.tmux-claude-monitor/history.json. Read by daemon.

Teammate 2 (UI): Add history view to popup.py — show last 7 days
  of token usage as a bar chart in the dashboard.

Teammate 3 (Testing): Write tests for history module and popup
  history view. Cover edge cases: empty history, corrupted file.

Dependency: T1 completes before T2 starts (T2 needs the data format)."
```

### Pattern 3: Debugging Team (Competing Hypotheses)

Best for: investigating bugs with multiple possible causes

```
"The status bar sometimes shows stale data. Investigate:

Teammate 1: Check if daemon.py stops writing to state file (process dies)
Teammate 2: Check if status.py reads a partially-written state file (race)
Teammate 3: Check if tmux caches #() command output (tmux-side caching)

Each: reproduce the issue, identify root cause, propose fix.
Lead: synthesize findings, implement the fix."
```

## CLAUDE.md Template for Agent Teams

```markdown
# Project: [name]

## Quick Start
- Run tests: `python3 -m pytest tests/ -v`
- Start daemon: `python3 scripts/daemon.py`
- Check status: `cat /tmp/tmux-claude-monitor.json | python3 -m json.tool`

## Architecture
[Brief description of how modules connect]

## Module Ownership (for agent teams)
- `scripts/` — implementation code (one owner at a time)
- `tests/` — test code (one owner at a time)
- `docs/` — documentation (one owner at a time)
- `claude-monitor.tmux`, `install.sh` — shell scripts (lead only)

## Conventions
- Python 3.6+ stdlib only — no pip dependencies
- Tests use pytest, run from project root
- Atomic file writes (write to .tmp, then os.replace)
- JSONL timestamps are UTC ISO 8601

## Verification
Before marking any task complete:
1. `python3 -m pytest tests/ -v` — all tests pass
2. No import errors in modified files
3. Changes committed with descriptive message
```

## Monitoring with tmux-claude-monitor

When running agent teams, the monitor provides:

### Status Bar (real-time)
```
 3 ●  0 ○ │ 450.2K (45%) │ ●     "pane_title" 12:30 30-Mar-26
```
- `3 ●` — three active teammates working
- `450.2K (45%)` — combined context usage across all sessions
- `●` green — rate limit healthy

### Popup Dashboard (Ctrl+b u)
```
  SESSIONS
  ━━━━━━━━
  ● [%0]  claude-monitor  opus   main     15.2K in   4.1K out
           ████░░░░░░░░░░░░░░░░  15.2%  (152K/1.0M)
  ● [%1]  claude-monitor  opus   main     12.0K in   3.8K out
           ███░░░░░░░░░░░░░░░░░  12.5%  (125K/1.0M)
  ● [%2]  claude-monitor  opus   main      8.5K in   2.1K out
           ██░░░░░░░░░░░░░░░░░░   8.3%  (83K/1.0M)
  ○ [%3]  claude-monitor  opus   main     22.0K in   6.5K out
           █████░░░░░░░░░░░░░░░  21.0%  (210K/1.0M)
```

### Key Keybindings
| Key | Action |
|-----|--------|
| `Ctrl+b u` | Open monitoring popup |
| `Ctrl+b U` | Restart monitoring daemon |
| `Ctrl+T` | Toggle task list (Claude Code built-in) |
| `Shift+Down` | Cycle teammates (in-process mode) |

## Anti-Patterns

### Don't: Share Files Between Teammates
```
❌ Teammate A and B both edit daemon.py
   → Last write wins, silent data loss

✅ Teammate A owns scripts/, B owns tests/
   → No conflicts, parallel execution
```

### Don't: Use Teams for Sequential Work
```
❌ "First do X, then Y, then Z"
   → One teammate waits, wastes tokens

✅ "X, Y, Z are independent — work in parallel"
   → True concurrency, 3x speedup
```

### Don't: Over-Communicate
```
❌ broadcast("just starting task 3")
   → Noise, costs tokens for every teammate

✅ message(lead, "task 3 complete, found 2 issues")
   → Targeted, actionable
```

### Don't: Skip the Monitor
```
❌ Run teams blind, check results after 2 hours
   → Teammates may go down wrong path

✅ Watch tmux-claude-monitor status bar
   → See active/idle transitions in real-time
   → Ctrl+b u for context usage per teammate
   → Catch runaway sessions early
```

## Cost Model

| Setup | Context Windows | Relative Cost |
|-------|----------------|---------------|
| Single session | 1 | 1x |
| Lead + 2 workers | 3 | ~3x |
| Lead + 4 workers | 5 | ~5x |

**Rule of thumb:** use teams when parallel speed gain > token cost multiplier.
For Pro/Max subscribers (flat rate), the cost is rate limit consumption, not dollars.
Watch the rate indicator: green → yellow → red.
