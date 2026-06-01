# Full Project Analysis: ainous-team v5.9.5

> Baseline analysis produced by the ainous-team coordinator + roles (security, code-quality,
> architect, researcher) against a local copy of the plugin source. Date: 2026-06-01.
> This is the foundation document for the refinement work tracked in the roadmap at the end.

## 1. What it is

A **persistent agent-team plugin for Claude Code**, built by xdimension.ai. It turns a single
Claude session into a coordinator that delegates work to **12 specialized role-agents** (architect,
developer, tester, security, researcher, etc.), each backed by **57 skills** (methodology docs
injected on demand). Its distinguishing claim over plain subagents: roles **accumulate knowledge
across sessions** — strategies that work get reinforced into per-role "playbooks," and **trust
levels gate permissions** so agents "earn autonomy."

**Honest reframe:** it's an ambitious *orchestration + governance + memory* layer on top of Claude
Code's hooks and subagents — where the governance is real code and the memory/learning is scheduled
LLM-driven file editing.

## 2. End-to-end task lifecycle

```
SESSION START
  └─ hooks/session-start (SessionStart): injects coordinator identity + playbook + team-knowledge;
     reads state from ~/.claude/ainous-roles/<role>/ and project .claude/; runs GC sweeps.

TASK ARRIVES → COORDINATOR
  └─ plans, routes via agents/capabilities/index.json + per-role keywords
  └─ spawns role via Agent tool, subagent_type: ainous-team:<role>
     • role loads: agents/<role>.md (model, tools) + agents-instructions/<role>-instructions.md
       + runtime-charter.md + its playbook.md + relevant skills (default + conditional)

DURING THE TASK — hook chain:
  • PreToolUse (Edit|Write|Bash|Read) → authority-enforce.sh   [THE enforced gate, 10s]
  • PostToolUse (Skill|Agent)         → skill-telemetry
  • PostToolUse (Agent)               → spawn-telemetry         [logs spawn, mints write-proxy nonce]
  • PostToolUse (WebFetch|WebSearch)  → taint-flag              [marks untrusted external content]
  • PostToolUse (SendMessage)         → write-proxy             [HMAC-gated teammate writes]

ROLE OUTPUT → coordinator synthesizes; role appends to journal.md + learnings.jsonl

SESSION END
  • SessionEnd → session-end (aggregates skill events into growth.json, fail-open)
  • SessionEnd / SubagentStop → teammate-lifecycle-reaper

CONSOLIDATION LOOP ("learning")
  • coordinator Stop hook is *supposed* to spawn @consolidator
  • consolidator reads learnings.jsonl → evolves playbook.md, updates trust, prunes/promotes
    strategies, enforces memory caps
  • ⚠️ opportunistic prose execution, not a guaranteed scheduled job
```

**Critical insight** (CLAUDE-DESIGN.md:101-103): *"This is not autonomous learning — it is scheduled
LLM-driven editing."* The hook **reads** trust level; only the consolidator LLM **writes** it. If
consolidation never runs, a role accumulates sessions while trust, playbook, and memory caps all
stand still.

## 3. Component inventory

| Category | Components | Status |
|----------|-----------|--------|
| Hooks (9 / 5 events) | `authority-enforce.sh` | 🟢 Load-bearing — sole enforced safety surface (2,177 lines) |
| | `session-start`, `session-end` | 🟢 Load-bearing — injection + GC + growth aggregation |
| | `spawn-telemetry`, `write-proxy`, `taint-flag` | 🟡 Supporting — provenance (S-1/S-2 HIGH bugs FIXED + verified) |
| | `skill-telemetry`, `teammate-lifecycle-reaper` | 🟡 Supporting — observability + cleanup |
| Roles (12) | coordinator/architect/security (opus); developer/tester/researcher/writer/code-quality/authority/consolidator/signal (sonnet); retriever (haiku) | 🟢 Core. Dual-sourced in `agents/*.md` + `capabilities/*.json` |
| Skills (57) | dev-core (tdd, debug, verify, refactor, design…) | 🟢 On-mission |
| | content/video cluster (video-script, video-edit, caption-format…) | 🔴 Off-mission for a dev team |
| | team-review / team-review-periodic / team-implement | 🟡 Misclassified — belong in `commands/` |
| Commands (6) | team-init, team-status, team-history, team-alerts, team-retro, team-signal | 🟢 User-facing |
| Scripts (12) | log-event, verify-artifact, pre-ship-gate, setup, team-status, compute-envelope-hmac, get-spawn-nonce, verify-* | 🟢/🟡 Mostly supporting |
| | `layer2-effectiveness-audit.sh` (Layer-2 retired v5.8.0) | 🔴 Dead weight — DELETED in cleanup |
| | `migrate-legacy-provenance.sh` (one-time migration) | 🟡 NOT dead — `tests/test-provenance.sh` TC10-12 depend on it; kept |
| Instructions | runtime-charter.md + 12 role files (~3,800 lines) | 🟢 Core; ~593 lines duplicated boilerplate |
| Dart app | `app/pm-client/` (1,118 lines, Flutter pulse UI) | 🔴 Non-plugin artifact in the package |
| Schemas/Templates | `schemas/events/*.json`, `templates/` | 🟡 `spawn.json` diverges from emitter; `knowledge-index.md` template dead |
| Tests | 6 bats, 14 .sh, 1 dart | 🟡 Real for `authority-enforce`; thin elsewhere |

## 4. Persistence & learning model

**Two tiers of state:**
- **Universal** `~/.claude/ainous-roles/<role>/` — `playbook.md`, `growth.json` (sessions + trust),
  `journal.md`, `learnings.jsonl`
- **Project** `.claude/ainous-roles/` + `team-knowledge.md` + `team-sync/state/task-history.jsonl`

**Learning machinery (all consolidator-driven prose):** trust progression (Intern→Contractor→
Employee→Trusted, +2/clean session, −5/denial); Shu-Ha-Ri strategy maturity; tiered promotion gate;
caps (50 sessions, 30 strategies) — **all enforced only when consolidation runs.**

**Structural weakness:** the consolidator is a single ~880-line prompt that is simultaneously the
only enforcer of memory caps, stale-fact pruning, dedup, trust updates, AND the gate against
poisoned-memory promotion. No code runs if it doesn't.

## 5. Maturity assessment

**A sophisticated, heavily-iterated personal/research tool with one production-grade subsystem —
not production-ready software as a whole.**

- Version history (v5.3→v5.9.5, ~20 point releases) shows the energy went into the
  **security/governance surface** (`authority-enforce.sh`), which is genuinely mature and
  well-tested (58+ adversarial bats cases).
- Everything else lags: zero test coverage for the reaper (`rmtree`!), taint-propagation,
  session-start GC, team-status; `promotion-review.bats` tests a classifier it authors inside itself.
- Accumulated cruft: dead Layer-2 script, one-time migration script still shipping, a Flutter app in
  the package, a schema no emitter satisfies, a dead hook registration.
- Two HIGH security bugs (S-1 path traversal, S-2 HMAC bypass) in the provenance machinery —
  now FIXED and independently verified (S-1 closed; S-2 closed across all four write-proxy tiers).

## 6. README claims vs reality

| README claim | Reality |
|--------------|---------|
| "12 roles, 57 skills" | ✅ True (3 misclassified, several off-mission) |
| "learn and improve over time" | 🟡 Scheduled LLM editing, not learning; real only if consolidator runs |
| "strategies reinforced/retired" | 🟡 Aspirational — consolidator prose, no enforcement |
| "trust levels gate permissions" | 🟢 *Reading* trust is enforced; 🟡 *updating* it is prose |
| "agents earn autonomy" | 🟡 Only if consolidation runs |
| persistent & specialized roles | ✅ True and well-implemented |

The design doc is unusually honest: its appendix self-classifies nearly every learning mechanism as
NORMATIVE (prose) vs the lone ENFORCED row (`authority-enforce.sh`). The README oversells; the design
doc tells the truth.

## Bottom line

ainous-team is **a well-engineered governance core wrapped in an aspirational learning narrative.**
The trust/authority/provenance layer is real, hardened, tested. The "self-improving team" is genuine
in design but **prose-enforced and fragile**, hinging on a single consolidator prompt nothing
guarantees will run. The single thread across every audit: **mechanical invariants are stuck in prose
that should be code.** Fixing that (extract `memory-maintain.py`) is the highest-leverage move —
it's what would make the README's central promise true.

---

## Refinement roadmap

**P0 — highest leverage**
1. Extract mechanical memory hygiene into `scripts/memory-maintain.py`, invoke from SessionEnd hook
   (fail-open) + pre-ship-gate. Kills the consolidator single-point-of-failure.
2. Re-tier judgment roles to opus: consolidator (P0), researcher (P1). Touch BOTH `agents/<role>.md`
   and `capabilities/<role>.json`.

### Compatibility principle (governing constraint)

**The plugin must stay model-agnostic and Claude-Code-version-agnostic.** Any version of Claude
Code installs and runs it cleanly on any Claude model. Newer/better models (4.8+) make it work
*better* as progressive enhancements — they are NEVER hard requirements. Concretely:
- Use family aliases (`opus`/`sonnet`/`haiku`) only — never dated model IDs. Aliases resolve on
  every CC version and auto-track the latest model.
- Any newer-only frontmatter feature (`effort:`, `opusplan`, `opus[1m]`) must be OPT-IN and
  documented, never in the shipped defaults — an older CC that can't parse it must still work.
- Degrade gracefully: a feature that isn't available must be ignored, not fatal.

**P1 — Opus 4.8 capability wins (OPTIONAL progressive enhancements, NOT defaults)**
- Document (don't bake in) `effort:` frontmatter (retriever low; architect/security xhigh) as an
  opt-in tweak for users on CC versions that support it.
- Document `opusplan` for the coordinator as an opt-in alternative to `opus` — do not ship as default.
- README notes only: `opus[1m]` opt-in; Bedrock/Vertex resolves `opus`→4.6.
- Verify each against the installed CC version before recommending; ship nothing that an older CC
  would choke on.

**P1/P2 — stop scaffolding a frontier model on a 1M window**
- Collapse PEAK/GOOD/POOR context-degradation ladder (runtime-charter.md:270-284).
- Reframe "Orient-First/never read everything"; bump journal compaction 5→15.
- Default spawn verbosity `coaching`→`supporting` for sonnet/opus roles.
- Loosen keyword-routing; let role `description` carry semantic weight.
- Add a model-absorption retirement test to the consolidator.
- KEEP anti-conformity injection (gets more reliable on Opus 4.8).

**P2 — bloat & dead weight — DONE**
- ✅ Cut: video-script, video-edit, caption-format.
- ✅ Converted team-review/team-review-periodic/team-implement to `commands/` (command-orchestration
  docs, not role skills; updated team-retro.md + README + design-doc counts → 54 skills).
- ✅ Extracted `app/pm-client/` to `ainous-team/pm-client/`; removed dead operator `app/` baseline.
- ✅ Deleted `templates/knowledge-index.md`, `scripts/layer2-effectiveness-audit.sh`. (Note:
  `scripts/migrate-legacy-provenance.sh` was initially flagged dead but is kept — live test dep.)
- ✅ Moved `confidence-calibration` to `default_skills` (10 roles).
- ⚠️ Instruction boilerplate: consolidated the Startup Sequence to a runtime-charter §5 pointer
  (−31 net lines, 9 files). Deliberately LEFT the Stop-hook frontmatter (harness-coupled), team-mode
  paragraphs (role-specific artifact names), and conformity guard (not byte-identical) inline — those
  would be lossy. ~550 lines deferred as not-safely-mergeable.

**Accepted residual (security)**
- R-nonce-clobber (MEDIUM, accepted): `spawn-telemetry` O_TRUNC overwrites a nonce on re-spawn —
  required for crash-recovery; only a self-defeating DoS for an already-trusted spawner. Documented in
  `spawn-telemetry` + CLAUDE-DESIGN.md §Residuals.

**Security fixes (from bug audit) — DONE + verified**
- ✅ S-1: `spawn-telemetry` path components now charset-validated + realpath-contained (fail-open).
- ✅ S-2: all four write-proxy tiers bind the nonce to the matched spawn event, never to
  caller-supplied names; `_find_spawn_event` uses AND-matching; Tier-1 rejects name mismatch.
  Independently adversarially verified closed.
- ✅ Q-12: `WebFetch|WebSearch` wired into the PreToolUse matcher.
- New regression tests: `tests/test-write-proxy.sh` TC-WP-19/20a/20b; `tests/test-memory-maintain.sh`.
