# Ainous Team

A persistent agent team plugin for [Claude Code](https://claude.ai/code) -- 12 roles, 57 skills, that learn and improve over time. v5.8.0.

Each role accumulates knowledge across sessions: strategies that work get reinforced, strategies that fail get retired. Trust levels gate permissions so agents earn autonomy through clean performance.

## Prerequisites

- [Claude Code CLI](https://claude.ai/code)
- Python 3.6+ (required by hooks)
- bash 3.2+ (macOS stock works)
- git (for knowledge tracking)

## Install

```bash
# Add the marketplace (adjust path to where you cloned the repo):
claude plugin marketplace add /path/to/ainous-team

# Install the plugin:
claude plugin install ainous-team
```

### First-time Setup

After installing the plugin, Claude Code will prompt you to initialize on the next session start. You can also start it manually at any time:

```bash
/team-init
```

This interactive command walks you through choosing your operating mode and then scaffolds `~/.claude/ainous-roles/` with starter files for all 12 roles. The setup is idempotent — running it again won't overwrite existing data.

**Mode options:**

- **Coordinator-as-default** (recommended): Claude automatically plans, delegates to role agents, and synthesizes results. You just type tasks naturally.
- **Agent mode**: You manually invoke roles with `@coordinator`, `@developer`, etc.

**Alternative — manual setup via shell:**

```bash
# Coordinator-as-default mode (recommended)
bash "$(claude plugin path ainous-team)/scripts/setup.sh"

# Agent mode
bash "$(claude plugin path ainous-team)/scripts/setup.sh" --agentmode
```

Post-commit journal reminder for coordinators: run `bash scripts/install-post-commit-journal-reminder.sh` once per repo to enable automatic commit-time prompts.

Before any release, run `bash scripts/verify-role-infrastructure.sh` to confirm all roles have complete 4-file scaffold (playbook, growth, journal, learnings) + agent definition + capability card.

### Coordinator-as-Default Mode

By default, setup configures Claude Code to **be** the coordinator -- it will automatically plan, delegate to role agents, and synthesize results. You just give it tasks naturally:

```bash
# Claude automatically plans, spawns roles, and synthesizes:
implement user auth for the API    # spawns researcher + architect + developer + tester
fix the login bug                  # spawns developer + tester
scan src/ for vulnerabilities      # spawns security
```

To disable later, remove the "You ARE the Coordinator" section from `~/.claude/CLAUDE.md`.

### Agent Mode (`--agentmode`)

If you prefer to invoke roles explicitly:

```bash
@coordinator implement user auth for the API    # full team orchestration
@developer fix the login bug                     # direct role invocation
@security scan src/ for vulnerabilities          # security audit
/team-status                                     # dashboard
/team-history                                    # session history
/team-alerts                                     # health checks
/team-retro                                      # periodic team review
```

## How It Works

```
User --> @coordinator --> plans task --> spawns role teammates --> synthesizes results
                           |                  |                        |
                      @authority         contracts +              verify gates
                   (approval gate)     playbook injection      (loop on failure)
```

1. **User invokes `@coordinator`** with a task
2. **Coordinator selects topology** -- fast-fix for bugfixes, security-first for auth, full-pipeline for features, etc. Then assesses parallelizability and chooses spawn mode (Agent for quick tasks, tmux for long-running).
3. **Coordinator spawns teammates** -- each gets their playbook + project context + team knowledge + execution contract. Can spawn multiple instances of the same role for independent tasks.
4. **Verification gates** between phases -- tests must pass, findings must be actionable, contracts must be fulfilled
5. **Teammates work** -- message @authority for approvals, @security for scans
6. **Coordinator synthesizes** -- presents unified result, asks for rating
7. **On stop** -- coordinator runs team retrospective (cross-role interaction analysis) and detects user corrections (implicit feedback from manual edits)

The coordinator has Write/Bash for journal writes but delegates all implementation to role agents. It has no Edit tool. It must delegate to @developer for code, @writer for docs, @tester for tests.

## Architecture

```
ainous-team plugin
|-- 12 agents        -- coordinator, developer, architect, code-quality, tester,
|                       researcher, writer, security, authority, consolidator, retriever, signal
|-- 57 skills        -- 3 orchestration + 54 domain-expertise (see Skills Vault below)
|-- 5 commands       -- /team-status, /team-history, /team-alerts, /team-retro, /team-signal
|-- 2 hooks          -- SessionStart (context injection), PreToolUse (enforcement)
|-- enforcement      -- script-based Write/Edit/Bash gating (fail-closed, allowlist-based)
\-- runtime charter  -- shared execution semantics injected into every role spawn
```

### Harness Design Patterns

The team implements patterns from recent harness engineering research:

| Pattern | Source | How It's Used |
|---------|--------|---------------|
| **Execution contracts** | [NLAH](https://arxiv.org/html/2603.25723v1) | Every teammate spawn defines required outputs, completion conditions, and scope |
| **Verification gates** | NLAH + [Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps) | Between phases: plan→implement→test→review, with loops on failure |
| **Counterfactual diagnosis** | [Meta-Harness](https://yoonholee.com/meta-harness/) | Consolidator compares sessions with/without strategies to isolate causal impact |
| **Rich diagnostic context** | Meta-Harness | Consolidator reads execution traces, not just summaries, for playbook evolution |
| **Assumption staleness** | Anthropic | Strategies get checked: "would the model do this naturally now?" |
| **Generator-evaluator loops** | Anthropic | Developer ↔ tester/code-quality iterate until tests pass (max 3 rounds) |
| **Shared team memory** | [Multi-Agent Memory Architecture](https://arxiv.org/html/2603.10062v1) | Append-only team-knowledge.md avoids cache coherence; consolidator deduplicates |
| **Voice of the user** | [PAHF](https://arxiv.org/abs/2602.16173) | Implicit feedback from user corrections weighted 3x vs self-scores |
| **Team retrospectives** | [MAR](https://arxiv.org/abs/2512.20845) | Coordinator reflects on cross-role interaction (not self-reflection, which degenerates) |
| **Multi-instance roles** | [A-HMAD](https://aclanthology.org/2025.acl-long.421/) | Same role spawned N times with heterogeneous strategy emphasis |
| **Hybrid spawn modes** | [Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps) | Agent tool for quick tasks, tmux panes for long-running visible work |
| **Named topologies** | [DyLAN](https://arxiv.org/abs/2310.02170) + [Puppeteer](https://blog.promptlayer.com/multi-agent-evolving-orchestration/) | Coordinator selects topology per task (fast-fix, security-first, etc.); consolidator evolves from retros |
| **3-tier memory lifecycle** | [MemOS](https://statics.memtensor.com.cn/files/MemOS_0707.pdf) + [EvoSC](https://arxiv.org/html/2602.01966) | Hot (playbook + recent 5) / warm (full journals) / cold (archived sessions); hard caps on all stores |
| **Self-triggered consolidation** | [EvoSC](https://arxiv.org/html/2602.01966) + [JiuwenClaw](https://earezki.com/ai-news/2026-03-27-openjiuwen-community-releases-jiuwenclaw-a-self-evolving-ai-agent-for-task-management/) | Triple trigger: Stop hook + 2-day critical + overflow at 20 entries |
| **Exploration force** | [Meta-Harness](https://yoonholee.com/meta-harness/) | Consolidator injects `[experimental]` strategies with maturity-decaying rate |
| **Soft enforcement** | Original | Main session gets NOTE when writing directly in coordinator-as-default mode |
| **Failure taxonomy** | NLAH + Anthropic | 7 named failure modes with prescribed recovery actions |
| **Skills vault** | Original + gstack + community | 57 skills across 10 domains, assigned at spawn, invoked autonomously by roles |
| **Session event log** | Anthropic Managed Agents | 7 event types in task-history.jsonl; enables crash recovery |
| **Knowledge lint** | Karpathy LLM Wiki | Consolidator detects contradictions and orphans across knowledge stores |
| **Structured retrieval tags** | MemPalace | Journal entries tagged by task-type and area; retriever pre-filters |
| **Strategy source tagging** | OEL/ERL | [from-failure] vs [from-success] attribution; heuristic format enforcement |

### Phase Definitions (task + role unification)

`templates/phase-definitions.md` -- structured phase metadata that topologies compose. Each phase defines entry/exit criteria (artifact-based, mechanically verifiable), roles, skills, and context instructions.

| Phase | Entry | Exit | Roles |
|-------|-------|------|-------|
| **research** | Task scope defined | researcher-findings.md exists | researcher |
| **design** | Findings exist OR scope clear | architect-design.md exists | architect |
| **implement** | Design exists OR simple fix | Code changes, tests pass | developer |
| **test** | Implementation exists | tester-results.md exists | tester |
| **review** | Tests pass | All CRITICAL resolved | security, code-quality (parallel) |
| **docs** | Review passed | Documentation updated | writer |

Topologies compose phases: `full-pipeline: [research, design, implement, test, review, docs]`, `fast-fix: [implement, test]`, etc. The consolidator evolves phase definitions from retro data.

### Runtime Charter

`agents-instructions/runtime-charter.md` -- shared execution semantics injected into every role spawn. Defines:

- **Execution contract fields** -- required output, completion condition, permission scope, budget, verification criterion
- **State conventions** -- journal format (compiled truth + timeline), task history (JSONL event log), structured learnings (JSONL with utility scores), evidence artifacts
- **Child lifecycle** -- spawn, init, execute, verify, journal, learnings, stop
- **Behavioral guards** -- analysis paralysis (5+ reads without action → STOP), revision stall detection, context degradation tiers (PEAK/GOOD/DEGRADING/POOR), deviation rules (auto-fix bugs, STOP for architecture)
- **Skill self-exclusion** -- skills include "when NOT to use" guidance
- **Mechanical verification gates** -- `test -f` before accepting completion, not just self-reported status
- **Evidence artifacts** -- structured findings for analytical roles (security, code-quality, researcher, architect)
- **Acceptance-gated retry** -- generalized retry pattern for any phase, not just developer-tester

### Failure Taxonomy

7 named failure modes with prescribed recovery actions:

| Mode | Recovery |
|------|----------|
| **missing-artifact** | Re-run phase that should have produced it |
| **verifier-failure** | Developer-tester loop (max 3) |
| **tool-error** | Retry with adjusted parameters |
| **timeout** | Split task, reduce scope |
| **wrong-path** | Re-route to correct role or approach |
| **contract-partial** | Retry with failure context, narrower scope |
| **quality-reject** | Fix findings, re-review |

### Skills Vault

57 skills across 10 domains that the coordinator assigns to roles at spawn time. Roles invoke them autonomously during execution.

**Orchestration skills (3):**

| Skill | Description |
|-------|-------------|
| **team-implement** | End-to-end feature pipeline: research, design, code, test, review |
| **team-review** | Multi-angle review pipeline: security + quality + architecture |
| **team-review-periodic** | Periodic team health review: 1-on-1s, dynamics retro, coordinator self-assessment |

**Domain-expertise skills (48):**

| Category | Skills |
|----------|--------|
| **Engineering Core** | tdd, debug, design, verify, review-response, refactor, perf, api-design, migrate, code-review-ext, devops, release-gate |
| **Testing & Quality** | test-strategy, observability, a11y |
| **Data & Security** | data-model, security-scan, threat-model |
| **Strategic/Leadership** | premise-check, ideate, auto-decide, prioritize, estimate, negotiate |
| **Team Operations** | strategy-evolution, workflow-auto, skill-creator, post-mortem, onboard, retro-metrics |
| **Research & Analysis** | deep-research, knowledge-structure, source-validate, competitive-intel |
| **Writing & Content** | scqa, content-repurpose, tone-enforce, summarize, copywriting, docs, present |
| **Visual & Design** | diagram, infographic, flowchart, ui-layout |
| **Video & Media** | video-script, video-edit, caption-format |

Review ordering is two-stage: spec compliance before quality (catches structural misses before style nits).

### Session Event Log and Crash Recovery

`task-history.jsonl` records 9 event types: `spawn`, `skill-invoked`, `completed`, `failed`, `retried`, `gate-passed`, `gate-failed`, `phase-transition`, `routing-decision`. Each entry is timestamped ISO-8601 with role, phase, and detail fields.

`skill-invoked` events carry a `source` field distinguishing three emission paths: `coordinator-spawn` (coordinator assigned the skill), `role-self-report` (role instruction-based emission), and `hook-auto` (mechanically observed by the `hooks/skill-telemetry` PostToolUse hook — added in v4.14.0). Events also carry `session_id` (v4.14.0) for precise session-scoped aggregation in `hooks/session-end`.

`spawn` events carry a `mode` field (v4.15.0) with value `"agent"` or `"tmux"` indicating which spawn mechanism was used. The field is additive — existing readers without knowledge of `mode` continue to work.

On crash recovery, the coordinator reads the event log to determine where the session was interrupted and resumes from the last successful phase-transition gate.

### Split Persistence

Knowledge is split into three layers:

| Layer | Location | What | Persistence |
|-------|----------|------|-------------|
| **Universal** | `~/.claude/ainous-roles/*/` | Playbooks, growth.json, trust | Across all projects |
| **Shared** | `~/.claude/ainous-roles/team-knowledge.md` | Facts discovered by 2+ roles | Across all projects |
| **Project** | `.claude/ainous-roles/*/` | Journals, memory, entities, traces | Per repository |

Playbooks evolve through consolidation. Growth metrics track performance. Trust scores determine permission levels. Shared team knowledge is append-only — the consolidator deduplicates periodically.

### 4-Phase Learning Pipeline (KAIROS-inspired)

```
Phase 1: Orient   --> scan what changed, build focus list (don't read everything)
Phase 2: Gather   --> pull from task-history, traces, corrections, learnings.jsonl
Phase 3: Consolidate --> WAL-safe writes: temporary first, verify, then promote
Phase 4: Prune    --> compact journals, enforce caps, update indices, verify integrity
```

Triple gate activation: time (>=24h or >=5 sessions) + volume (>=3 entries) + lock (no concurrent, 1-hour stale timeout).

- **Quick capture** fires after every session via Stop hooks (~5 seconds). Captures journal entries, structured learnings (JSONL with utility scores), execution traces, and user corrections.
- **Deep consolidation** auto-triggered (not cron-dependent) -- reads execution traces + learnings.jsonl, performs counterfactual diagnosis, evolves topologies and phase definitions from retros, applies utility-weighted strategy selection (MemRL-inspired), aggressive pruning (5-session inactivity challenge), analyzes user corrections (weighted 3x), promotes shared facts, enforces caps (50 sessions, 30 strategies), injects `[experimental]` strategies, runs knowledge lint.

### Trust Progression

| Level | Score | Permissions |
|-------|-------|-------------|
| **Intern** | < 50 | Read-only, suggestions only |
| **Junior** | 50-74 | Baseline per role (default) |
| **Senior** | 75-89 | Expanded baseline + notify (not approve) |
| **Principal** | 90+ | Domain autonomy (requires user promotion) |

Trust score: +2/session, +1/approval, -5/denial, -15/violation, -3/user-override. Capped 0-100.

### Enforcement

```
PreToolUse hook (script-based, not prompt-based, FAIL-CLOSED):
  Write/Edit   --> check role baseline against authority-book.md
  Bash          --> allowlist of safe read-only commands; rejects subshells ($(), `, <()), pipes to rm/mv/cp/xargs
  Read/Grep/Glob --> instant allow (no enforcement)
  Unknown role / main session --> allow (+ soft warning in coordinator-as-default mode)
  Python crash / parse error --> BLOCK (fail closed)

Protected paths (always denied):
  ~/.claude/.session-role     -- role identity marker, prevents impersonation
  ~/.claude/.session-role-*   -- per-pane markers for tmux parallel mode
```

Trust-aware: Intern roles are blocked from all writes. Senior roles get expanded baselines. Unknown trust levels are treated as Intern. Per-pane role markers (`$TMUX_PANE`) prevent race conditions in tmux parallel mode.

## Roles

| Role | Color | Domain | Tools | Baseline Write Access |
|------|-------|--------|-------|----------------------|
| **coordinator** | -- | Orchestration, planning, synthesis | Read, Write, Grep, Glob, Bash, Agent | Task plans, journals only |
| **developer** | green | Features, bugfixes, refactoring | Read, Write, Edit, Grep, Glob, Bash | `src/`, `lib/`, `app/`, `pkg/` |
| **architect** | cyan | System design, trade-offs | Read, Write, Edit, Grep, Glob, Bash | Design docs, specs |
| **code-quality** | yellow | Reviews, bugs, standards | Read, Grep, Glob, Bash, Agent | Read-only |
| **tester** | magenta | Tests, coverage, edge cases | Read, Write, Edit, Grep, Glob, Bash | Test files only |
| **researcher** | green | Exploration, investigation | Read, Grep, Glob, Bash, WebSearch, WebFetch | Research notes |
| **writer** | cyan | Documentation, READMEs | Read, Write, Edit, Grep, Glob | Docs, *.md files |
| **security** | yellow | Vulnerabilities, threats | Read, Write, Edit, Grep, Glob, Bash, Agent | Security reports |
| **authority** | -- | Approvals, policy | Read, Write, Edit, Grep, Glob, Bash, Agent | Authority-book, decisions |
| **consolidator** | -- | Knowledge distillation | Read, Write, Edit, Grep, Glob, Bash | Playbooks, growth.json |
| **signal** | cyan | External intelligence | Read, Write, Grep, Glob, Bash, WebSearch, WebFetch | Team-knowledge, signal journals |
| **retriever** | -- | Context filtering | Read, Grep, Glob, Agent | Read-only |

Colors use a 4-color mosaic: green (builder/explorer), cyan (design/docs), yellow (reviewers), magenta (tester). Infrastructure roles (coordinator, authority, consolidator, retriever) have no color. Signal uses cyan (information/exploration).

## Governance

### Authority Book

`~/.claude/ainous-roles/authority/authority-book.md` -- the canonical permission matrix.

- **Within baseline**: auto-approved, no authority check needed
- **Outside baseline**: agent must message @authority for approval
- **Escalate to user**: push, destructive git, package installs (no role can approve)

### Decision Log

`~/.claude/ainous-roles/authority/decisions.md` -- structured audit trail of every non-baseline approval (AUTH-001, AUTH-002, ...). Overly broad patterns (`*`, `**/*`) are rejected by the enforcement script.

## File Layout

```
ainous-team/                             <-- the plugin
|-- .claude-plugin/plugin.json           <-- manifest
|-- agents/                              <-- 11 slim agent definitions
|-- agents-instructions/                 <-- full instructions (referenced by agents)
|   \-- runtime-charter.md              <-- shared execution semantics (injected into all spawns)
|-- commands/                            <-- /team-status, /team-history, /team-alerts, /team-retro
|-- skills/                              <-- 15 skills (3 orchestration + 12 domain)
|-- hooks/                               <-- session-start, authority-enforce.sh
|-- scripts/
|   |-- team-status.sh                   <-- dashboard script
|   \-- setup.sh                         <-- first-run bootstrapper
|-- templates/                           <-- starter files for new installs
|-- docs/                                <-- design specs and research (for contributors)
|-- CLAUDE.md                            <-- project rules
\-- LICENSE                              <-- MIT

~/.claude/ainous-roles/              <-- user data (created by setup.sh)
|-- team-knowledge.md                    <-- shared facts (all roles read/write, consolidator deduplicates)
|-- user-corrections.md                  <-- implicit feedback from user edits (coordinator captures)
|-- coordinator/playbook.md              <-- evolved strategies
|-- coordinator/growth.json              <-- performance + trust scores
|-- coordinator/retros.md                <-- team retrospectives (cross-role interaction analysis)
|-- authority/authority-book.md          <-- permission matrix
|-- authority/decisions.md               <-- approval audit trail
|-- consolidator/cross-role-insights.md  <-- patterns across 3+ roles
\-- ... (11 roles × playbook + growth.json)

<project>/.claude/ainous-roles/      <-- project-specific data (created at runtime)
|-- team-knowledge.md                    <-- project-specific shared facts
|-- team-sync/                           <-- coordination dir for tmux-mode spawns
|   |-- state/task-history.jsonl         <-- session event log (7 event types)
|   |-- state/                           <-- phase completion status
|   |-- artifacts/                       <-- role deliverables (findings, reports)
|   \-- index.md                         <-- knowledge index (topic-organized catalog)
|-- researcher/journal.md                <-- session notes for THIS project
|-- researcher/memory.md                 <-- entities + patterns for THIS codebase
\-- ... (per-role journals + memory)
```

## What's new in v5.2.0–v5.8.0

v5.8.0 ships two coordinated security changes. First, the Clinejection defense (scope-reduction-on-taint): when a session is tainted by a WebFetch/WebSearch call, the enforcement hook now applies a reduced-capability profile — Bash is restricted to a read-only allowlist and Write/Edit are restricted to the role's own paths and findings artifacts. This closes the gap where a poisoned agent retained full capabilities after fetching adversarial content. Second, Layer-2 contract-implied authorization was retired after 8 weeks of zero adoption: the scope field was hardcoded empty on every spawn event, making the enforcement block dead code. Deleting dead code reduces surface area; all authorization now flows through Layer-1 (project baselines) and Layer-3 (hardcoded baselines + decisions.md).

v5.7.0 closed a protocol-level bypass in the write-proxy nonce lifecycle. Three key fixes: (1) the per-session nonce moved from task-history persistence to a 0600 file, eliminating cross-session nonce bleed; (2) Bash credential-read gating was widened with a shell-metachar anchor and variable-indirection defense; (3) a teammate-lifecycle-reaper hook was added for crash-safe team-mode state cleanup. These changes harden the enforcement layer without changing the observable API.

Sixteen releases across four capability areas shipped since v5.1.x.

### Artifact provenance and audit (v5.2.0, v5.4.0)

Every persistent-memory write now carries a five-field provenance block (`role`, `session`, `source`, `discovered`, `verified`). The provenance validator in `hooks/authority-enforce.sh` rejects writes that omit or partially fill the block — fail-closed, not warn-only. v5.4.0 added M-3 parity: spawn events are auto-emitted to `task-history.jsonl` at the coordinator level so no spawn goes unlogged even when a role skips the self-report.

- **v5.2.0** — provenance validator: five-field block required on all six persistent-memory surfaces
- **v5.4.0** — spawn-event auto-emission; M-3 parity between coordinator and role self-reports

### Phase 2: semantic supply-chain taint (v5.3.0–v5.6.2)

Introduced a taint-flag mechanism that tracks whether a knowledge claim originates from an external-unsanitized source (signal scan, user correction). Tainted facts cannot flow directly into playbooks without an explicit approval step. A defensive `session_id` fix in v5.6.2 prevents cross-session taint bleed when multiple consolidation runs share the same day timestamp.

- **v5.3.0** — taint-flag mechanism; `external-unsanitized` source type added to provenance
- **v5.3.1** — taint propagation across upstream_chain; consolidator promotion-review gate
- **v5.6.1** — tiered blocking read/apply flow (external-blocking, cross-role-waiting, awaiting-review)
- **v5.6.2** — defensive `session_id` fix; cross-session taint bleed closed

### Team-mode integration (v5.4.1–v5.6.6)

Team-mode (`Agent(team_name=..., name=...)`) is now a first-class spawn path with its own execution policy. A reproducible upstream crash (`H.toolUseContext.getAppState`) fires when a teammate's Write triggers the approval prompt. The policy response: teammates must not call Write/Edit/NotebookEdit; they return content via SendMessage for coordinator recovery-write. Subsequent releases refined state reaper cleanup, the `ainous-team:<role>(<description>)` naming convention, and journal-discipline enforcement at session end.

- **v5.4.1** — team-mode execution policy; crash-safe Write prohibition; coordinator recovery-write pattern (runtime-charter §15)
- **v5.6.0** — state reaper: cleans stale `.claude/ainous-roles/team-sync/state/` files after team sessions end
- **v5.6.5** — naming convention: teammates spawned as `ainous-team:<role>(<description>)` for pane-header clarity
- **v5.6.6** — journal-discipline closure: execution-focused roles must append journal entry before going idle

### Write-proxy protocol (v5.5.0–v5.7.0)

A structured write-proxy envelope lets background teammates persist content even when the coordinator session is not alive at finish time. The envelope format (`<!-- WRITE-PROXY-ENVELOPE v1 -->` with YAML frontmatter) includes the intended destination path, provenance block, and an HMAC computed against a per-session nonce. v5.6.4 shipped a canonical helper script. v5.6.7 added a pre-release gate script that verifies full role infrastructure before any version bump is committed.

- **v5.5.0** — write-proxy envelope v1; SendMessage-based durable fallback (runtime-charter §15.1)
- **v5.5.1** — three-tier identity resolution for write-proxy nonce (env var → coordinator message → random)
- **v5.6.3** — HMAC field added to envelope; tamper-evident envelope body
- **v5.6.4** — canonical HMAC helper: `scripts/compute-envelope-hmac.sh`
- **v5.6.7** — release-gate script: `scripts/verify-role-infrastructure.sh`

### Scripts

Three utility scripts shipped this wave and are available in `scripts/`:

- **`compute-envelope-hmac.sh`** — computes the SHA-256 HMAC for a write-proxy envelope body, keyed by the per-session nonce
- **`install-post-commit-journal-reminder.sh`** — installs a git post-commit hook that prompts the coordinator to append a journal entry after each commit
- **`verify-role-infrastructure.sh`** — pre-release gate that confirms every role has its complete four-file scaffold (playbook, growth, journal, learnings) plus agent definition and capability card

---

## Design Philosophy

The team is not a collection of agents — it is itself an agent at a higher layer of abstraction.

```
Cell        → Role         (individual capability, one function)
Organ       → Role cluster (researcher+architect = "understanding")
Organism    → Team         (11 roles, one coherent output)
```

**Embed, don't repeat.** Each layer wraps the lower layer's capability as a black box. The coordinator doesn't know HOW the developer writes code — only WHEN to invoke it. If two roles produce overlapping output, the consolidator detects this and recommends specialization.

**Dynamic topology, not fixed pipeline.** The coordinator learns which team shapes work for which tasks. A bugfix skips the architect. A security-sensitive feature starts with a security scan. The topology emerges from the task, guided by retro data.

**Exploration force.** Without experimentation, the system converges to a local optimum. The consolidator occasionally injects `[experimental]` strategies. The coordinator occasionally tries unusual role combinations. Exploration rate decays as the system matures — high early, low when stable.

**Minimal stable complexity.** The goal is the leanest team that reliably serves your actual work patterns. Unused roles retire, redundant strategies merge, unstable topologies get abandoned. Like biological homeostasis — converge toward what works, shed what doesn't.

Full design doc: [`docs/design/2026-03-31-team-as-organism.md`](docs/design/2026-03-31-team-as-organism.md)

## Research Foundation

Built on patterns from:

| Source | Pattern Used |
|--------|-------------|
| [Meta-Harness](https://yoonholee.com/meta-harness/) (Lee et al., 2026) | Counterfactual diagnosis, rich diagnostic context for playbook evolution |
| [Natural-Language Agent Harnesses](https://arxiv.org/html/2603.25723v1) (2026) | Execution contracts, verification gates, file-backed state |
| [Anthropic Harness Engineering](https://www.anthropic.com/engineering/harness-design-long-running-apps) (2026) | Generator-evaluator loops, assumption staleness detection |
| [Hyperagents](https://arxiv.org/abs/2603.19461) (Meta, 2026) | Self-improvement principle -- system improves how it improves |
| [Supermemory ASMR](https://supermemory.ai) | Agentic retrieval > vector search; 3-parallel retriever |
| [ATF](https://github.com/massivescale-ai/agentic-trust-framework) (CSA, 2026) | Trust progression (Intern to Principal) with earned autonomy |
| [AutoResearch](https://github.com/karpathy/autoresearch) (Karpathy) | Tight loop + single metric per role |
| [CrewAI](https://docs.crewai.com) | Role-based teams, scoped memory |
| [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams) | Shared task list, mailbox, teammate hooks |
| [Cofounder GIC](https://cofounder.com) | Sleep-time compute for background consolidation |
| [Multi-Agent Memory Architecture](https://arxiv.org/html/2603.10062v1) (2026) | 3-layer hierarchy, append-only shared memory avoids coherence problems |
| [PAHF](https://arxiv.org/abs/2602.16173) (2026) | Implicit feedback from user corrections > explicit ratings |
| [MAR: Multi-Agent Reflexion](https://arxiv.org/abs/2512.20845) (2025) | Multi-persona reflection avoids thought degeneration |
| [A-HMAD](https://aclanthology.org/2025.acl-long.421/) (ACL, 2025) | Heterogeneous agents outperform homogeneous in multi-agent search |
| [EvoSC](https://arxiv.org/html/2602.01966) (Feb 2026) | Self-consolidation with contrastive learning; FIFO queue for experience management |
| [DyLAN](https://arxiv.org/abs/2310.02170) | Agent Importance Score for dynamic team selection |
| [MemOS](https://statics.memtensor.com.cn/files/MemOS_0707.pdf) (Jul 2025) | 3-tier memory lifecycle (working/long-term/cold archive) |
| [NeurIPS 2025 Puppeteer](https://blog.promptlayer.com/multi-agent-evolving-orchestration/) | RL-based dynamic orchestration learns task routing |
| [JiuwenClaw](https://earezki.com/ai-news/2026-03-27-openjiuwen-community-releases-jiuwenclaw-a-self-evolving-ai-agent-for-task-management/) (Mar 2026) | Execution-to-Learning Closed Loop for self-evolving agents |
| [MemPalace](https://arxiv.org/abs/2603.xxxxx) | Structured tags on memory entries for retrieval filtering; temporal validity on facts |
| [Karpathy LLM Wiki](https://github.com/karpathy/llm-wiki) | Knowledge lint pass (contradiction + orphan detection); topic-organized index |
| [Anthropic Managed Agents](https://www.anthropic.com/engineering/building-effective-agents) (2026) | Session event log for crash recovery; "harnesses encode assumptions that go stale" |
| [OEL/ERL](https://arxiv.org/abs/2603.xxxxx) | Strategy source tagging ([from-failure] vs [from-success]); heuristic format enforcement (When X, do Y, because Z) |

## Contributing

Design specs and research notes are in `docs/`. The architecture is documented there for anyone who wants to understand the design decisions.

## License

MIT
