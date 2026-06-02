# Team-as-Organism Design

> The following describes intended behavior expressed as prompt-level instruction to roles. Mechanical enforcement status is tracked in the appendix. For enforced invariants, see CLAUDE.md.

---

## 1. Premise

<a id="design-three-layers"></a>

The ainous-team is built on three orthogonal layers. No single concept dominates — they combine to produce structured, expertise-driven, context-aware work.

| Layer | What it defines | Examples |
|-------|----------------|---------|
| **Templates** | Structural scaffolding — phases, entry/exit criteria, artifact contracts, journal format | `templates/phase-definitions.md`, knowledge format, task-history schema |
| **Skills** | Domain expertise — principles, techniques, anti-patterns | `skills/debug.md`, `skills/security-scan.md`, `skills/api-design.md` |
| **Roles** | Identity and persistent learning — who you are, what you've learned, trust level | `agents/developer.md`, playbooks, journals, growth.json |

**The coordinator reads all three and composes them per task:**
- Selects a **topology** (from templates) that defines phase sequence and artifact gates
- Assigns **skills** to roles for the task's domain requirements
- Spawns **roles** that carry their accumulated expertise

**Design rule:** When deciding where something belongs — ask which layer it is:
- Does it define *when* and *what order*? → Template
- Does it define *how* (technique, principle)? → Skill
- Does it define *who* (identity, memory)? → Role

Mixing layers is the most common source of architectural drift. A skill that defines phase order belongs in templates. A role that encodes technique belongs in skills.

---

## 2. Coordinator Intelligence

<a id="design-coordinator-intelligence"></a>

### Coordinator Routing Pipeline

- Coordinator follows a 7-step deterministic pipeline
- Steps 1,2,4,5,6,7 are mechanical; Step 3 (generate candidates) is the only LLM-creative step
- Typed action candidates: DELEGATE_ROLE, DIRECT_ANSWER, ESCALATE_USER, SKIP
- Deduplication before ranking prevents overlapping role spawns
- Context pressure emergency: trigger micro-consolidation when context approaches limits
- **Routing accountability**: routing-decision event MUST be logged before any spawn — unaudited sessions flagged by consolidator
- **Expertise-weighted synthesis**: coordinator weights role outputs by domain expertise, not equal averaging (prevents integrative compromise)
- **Model tiering**: Heavy (opus) for complex reasoning, Standard (sonnet) for most work, Light (haiku) for mechanical tasks — 40-60% cost reduction
- **Voting vs Consensus synthesis**: reasoning tasks (design debates, tradeoffs) → voting: highest-expertise view wins. Knowledge tasks (bug identification, code analysis) → consensus: synthesize overlapping findings. Classification rule: if roles could legitimately disagree based on different priorities → voting; if observing same ground truth → consensus.
- **Anti-conformity for parallel reviewers**: when 2+ roles review the same artifact in parallel, inject explicit independence instruction into each prompt — prevents LLM conformity bias where the second reviewer anchors to the first's framing

<a id="agent-cards"></a>

### Agent Cards

- `agents/capabilities/` holds one `<role>.json` per role with: task_types, input_artifacts, output_artifacts, keywords, anti_keywords, max_parallel, topology_phases. `agents/capabilities/index.json` is the registry index with routing hint.
- Coordinator checks Agent Cards before LLM-reasoning about routing (Step 3) — reduces routing from creative to mechanical for clear-match tasks

<a id="design-situational-leadership"></a>

### Situational Leadership — Spawn Verbosity

- Coordinator adapts prompt detail to role maturity: `directive` (Intern) → `coaching` (Contractor) → `supporting` (Employee) → `delegating` (Trusted)
- `spawn_verbosity` field in growth.json, computed by consolidator from session_count × avg_score, regresses on recent contract failures
- Directive: full step-by-step + explicit success criteria. Delegating: outcome only — role knows what to do

<a id="design-predictive-routing"></a>

### Predictive Routing

- Coordinator scans task-history.jsonl for recent spawn sequences on the current branch
- If a pattern emerges (e.g., researcher→architect→developer), suggests likely next role
- Reduces re-planning overhead for sequential tasks within the same workflow

<a id="design-llm-native"></a>

### LLM-Native Patterns

- **Competitive parallelism**: spawn N instances on high-ambiguity measurable tasks, select best — exploit perfect parallelism with zero coordination overhead
- **Perspective forking**: spawn 2-3 instances with explicitly different framings (not random) — synthesize for non-obvious constraints. Max 3 forks before diminishing returns
- **Adversarial critic spawn**: before accepting major design or plan, spawn critic with "find the strongest argument this is wrong" — zero-ego review impossible in human teams
- **Map-Reduce topology**: for large systematic analysis (>50 files), split into N isolated chunk-agents + synthesis agent. Isolation prevents 29%→3% accuracy degradation from shared context growth
- **Precision context curation**: `context_mode: minimal|standard|full|artifact-only` at spawn. Exploration tasks get minimal context (preserves novelty). Review tasks get artifact-only (no build history bias). Granovetter weak ties: minimal shared context produces novel outputs
- **Sequential anti-conformity**: inject independence reminder in sequential pipelines, not just parallel reviews — "the previous role's output is a handoff artifact, not a conclusion"

---

## 3. Learning Loop

<a id="design-learning-loop"></a>

### Consolidation Pipeline (4-Phase)

- Consolidator follows a 4-phase sequential pipeline: Orient, Gather Signal, Consolidate, Prune & Index
- **Orient**: Scan what changed, build focus list (do not read everything)
- **Gather Signal**: Pull from task-history, traces, corrections (only areas identified in Orient)
- **Consolidate**: WAL-safe writes — temporary first, verify, then promote. Only file-writing phase.
- **Prune & Index**: Compact journals, enforce caps, update indices
- Triple gate activation: time (>=24h or >=5 sessions) + volume (>=3 entries) + lock (no concurrent consolidation)

### Consolidator-Updated Playbooks

Playbooks are updated by the consolidator role at triple-gated intervals. The consolidator re-writes strategy entries based on task-history evidence. This is not autonomous learning — it is scheduled LLM-driven editing. (Note: the original documentation used the phrase "self-improving playbooks," which overclaims. The update path is an LLM prompt, not autonomous gradient descent.)

Utility scoring (MemRL-inspired framing) is a prompt-computed heuristic: each learning carries a utility score updated on success (+2), reference (+1), failure (-1), contradiction (-2). High-utility learnings get context priority over recent ones. This is not a trained model — it is a bookkeeping convention executed by the consolidator prompt.

<a id="design-shu-ha-ri"></a>

### Shu-Ha-Ri Strategy Maturity

- Playbook strategies carry `maturity: shu|ha|ri` field
- **Shu** (follow exactly): new/unproven strategy — default
- **Ha** (adapt the principle): promoted after 3+ successful applications across independent sessions
- **Ri** (transcend): consolidator staleness check at 10+ sessions — "would the model do this naturally?" If yes → retire to Ri Archive, remove from active injection
- Safety-critical rules never graduate past Shu regardless of session count
- Ri is primarily a pruning criterion, not an achievement: if the model has internalized it, the instruction is scaffolding that can come down

<a id="session-log"></a>

### Session Log & Crash Recovery (design rationale)

- `.claude/ainous-roles/team-sync/state/task-history.jsonl` is the append-only session event log (write path enforced by hook — see CLAUDE.md)
- Coordinator reads this on startup to detect and resume interrupted sessions
- Design principle: "Harnesses encode assumptions that go stale" — design for interfaces, not implementations
- The session log IS the interface: any coordinator instance can read it and resume
- Events carry a `schema: "<N>"` field; writers emit via `scripts/log-event.sh` which validates against `schemas/events/<event-type>.json`. Readers tolerate events without the field (treat as `schema: 0`). Mode toggle via `LOG_EVENT_MODE=warn|enforce` — currently ships in warn-only mode.

### Execution Traces & Diagnostic Signal (design rationale)

- Consolidator greps traces selectively (research shows 16-point accuracy gap: summaries vs raw traces)
- Compacted journal entries include `[trace: ...]` lineage links back to raw traces
- Strategy annotations in journals: `strategy-name [success/failed, context: ...]` for richer consolidation signal

### Event-Based Micro-Consolidation

- Supplements scheduled consolidation with immediate capture on high-signal events
- Triggers: error recovery, user correction, strategy failure
- Focused single-role update — does not run full consolidation pipeline

### Self-Triggered Consolidation

- **Stop hook**: auto-spawns @consolidator when stale (>1 day) + 3 unconsolidated entries
- **Session-start critical**: >2 days stale → CRITICAL warning (run consolidator FIRST)
- **Overflow emergency**: >20 unconsolidated entries per role → WARNING
- No dependency on CronCreate — the learning loop is self-sustaining

### Exploration Force

- Consolidator injects `[experimental]` strategies with maturity-decaying rate
- 0-20 sessions: 1 experiment per consolidation; 20-100: 1 per 3; 100+: 1 per 10
- Topology experiments: coordinator gets suggestions every 5 consolidation cycles
- Failed experiments retired; successful ones promoted to regular strategies

<a id="design-memory-lifecycle"></a>

### Memory Lifecycle (3-tier)

Conceptual memory lifecycle. Enforcement relies on the consolidator's Phase 4b prompt-directed archival; absent a consolidator run, caps are not enforced.

- **Hot** (in-context): playbook strategies + last 5 journal entries
- **Warm** (on-disk): full journals, growth.json, team-knowledge
- **Cold** (archived): sessions >50 archived to `~/.claude/ainous-roles/<role>/sessions-archive.jsonl` (forensic review only — not read during normal operation), expired decisions in `decisions-archive.md`, retired strategies in playbook Ri Archive
- Hard caps: 50 sessions in growth.json (enforced in consolidator Phase 4b — WAL-safe: acquire advisory lock, archive to `sessions-archive.jsonl`, verify with absolute pathlib, then truncate), 30 strategies per playbook, journals compacted after 5 entries
- Expired decisions rotated to `decisions-archive.md`
- WAL (Write-Ahead Log) safety: consolidator writes to temporary first, atomically promotes. Crash-safe.

<a id="design-structured-learnings"></a>

### Structured Learnings

- Roles log JSONL entries to `<role>/learnings.jsonl` alongside Markdown journals
- Format: `{timestamp, skill, type, key, insight, confidence, source, files}`
- Types: operational, pattern, pitfall, preference, architecture, tool
- Enables programmatic dedup, search, staleness detection (file reference pruning)
- Consolidator reads learnings.jsonl for structured signal; prunes stale entries in Phase 4
- **Aggressive pruning**: strategies not invoked in 5 sessions get challenged; negative-utility strategies retired immediately; skill invocation data drives default assignment evolution
- All role Stop hooks now write to learnings.jsonl (fully implemented). Consolidator Phase 2 updates utility scores from task-history evidence. Retriever is stateless — outputs via response only, writes no files.

### Journal Format (Compiled Truth + Timeline)

- Journals use compiled truth + timeline format
- **Above the line (Compiled Truth)**: Running synthesis, destructively rewritten by consolidator each cycle
- **Below the line (Timeline)**: Append-only chronological evidence, never deleted or reordered
- Roles read compiled truth for instant context; timeline preserves provenance

---

## 4. Quality Signals

<a id="design-quality-signals"></a>

### Andon Cord & Framing Doubt

- Any role can emit a `HALT` event when it detects a defect that will propagate downstream — HALT is a quality signal, not a failure
- `framing-doubt` is a non-blocking variant — role signals uncertainty about problem framing without stopping; coordinator reads it at synthesis
- Rule 0 in Deviation Rules: third attempt on the same approach without measurable progress → HALT, declare approach failed, do not attempt a fourth time
- Every role is explicitly authorized to emit HALT; suppressing a defect signal to avoid "failing" is the anti-pattern
- Note: the enforcement gate (`hooks/authority-enforce.sh`) does NOT consume HALT events. HALT is a prompt-level convention between roles and the coordinator.

### Confidence Calibration

- `completed` events carry optional fields: `confidence` (0-10), `confidence_basis` (tested|reasoned|inferred|guessed), `uncertain_areas` ([...])
- Coordinator down-weights at verification gates: confidence ≥ 8 proceeds normally; 6-7 proceeds with flagged uncertainties; < 6 requires additional verification pass
- Consolidator tracks calibration accuracy per role — if stated confidence doesn't predict pass rate, it's discounted
- Renaming from "psychological safety" (biological framing) to "confidence calibration" (LLM-correct framing): LLMs have trained overconfidence, not fear-suppressed uncertainty

### Behavioral Guards

- **Analysis paralysis guard**: 5+ consecutive read-only calls without action → STOP (act or report blocked)
- **Revision loop stall detection**: if issue count doesn't decrease between retries, break early. When tester↔developer stall is detected, switch to Yes-And variant: affirm passing tests, reframe failures as missing coverage requirements — breaks anchoring bias that causes pure-rejection loops to stall.
- **Context degradation tiers**: PEAK (0-30%) → GOOD (30-50%) → DEGRADING (50-70%) → POOR (70%+) with graduated behavior
- **Deviation rules**: auto-fix bugs/blockers (Rules 1-3), STOP for architectural concerns (Rule 4)
- **Skill self-exclusion**: skills include "when NOT to use" guidance to prevent false-positive invocation
- **Smart Discuss**: coordinator proposes answers when escalating, never asks bare open questions
- **Files-modified overlap detection**: check for file-level overlap before parallel spawns
- **Phase-boundary quality checkpoint**: between every phase transition, coordinator runs 3-question check: artifact exists? content matches original intent (drift check)? internally consistent? Failure → gate-failed event, do not proceed. Context drift (not context size) causes majority of cascading failures — 2% early drift compounds to 40%+ failure rate.
- **Stigmergy for inner loops**: for tight refinement cycles (lint→fix→lint, test→fix→test), spawn a single self-contained role rather than coordinator-mediated ping-pong — reduces coordinator round-trip latency for fast mechanical cycles

### Structural Provocation & Double-Loop Learning

- **Single-loop**: fix the error within existing assumptions (current consolidation behavior)
- **Double-loop**: question the assumptions themselves — triggered when same issue recurs across 3+ roles, user corrections contradict strategy success records, or score declines despite refinements
- **Structural Provocation**: coordinator injects counter-hypothesis forcing into spawn prompts — "Assume the current approach is wrong. What would we expect to observe?" Primary LLM mechanism for double-loop learning (cannot rely on felt dissonance — LLMs have none)
- **Governing Assumptions Audit**: consolidator runs every 10 sessions — lists top structural assumptions, checks task-history for contradicting evidence, proposes structural changes to coordinator

---

## 5. Collective Intelligence

<a id="design-collective-intelligence"></a>

### Periodic Team Reviews

- `/team-retro` command triggers periodic team health review (also auto-prompted every 7 days / 10 commits)
- Four-part process: individual growth reviews (1-on-1s), team dynamics retro, coordinator self-assessment, action items
- Coordinator evaluated on: routing accuracy, team utilization, growth facilitation, skill assignment
- Reviews stored in `.claude/ainous-roles/coordinator/reviews.md`

### Collective Intelligence

- **Team-level strategies:** handoff patterns + team norms span multiple roles, evolved from review data
- **Handoff patterns:** learned optimal formats for role-pair handoffs, stored in `coordinator/handoff-patterns.md`
- **Skill auto-generation:** when 3+ roles share a technique, consolidator proposes a new skill for the vault
- **Team health metrics:** growth rate, specialization index, knowledge sharing velocity, handoff friction score

### Shared Team Knowledge

- `$HOME/.claude/ainous-roles/team-knowledge.md` — shared facts accessible to all roles
- Append-only: roles add facts, consolidator deduplicates periodically
- Facts promoted when 2+ roles independently discover the same thing
- Project-level: `.claude/ainous-roles/team-knowledge.md` for project-specific shared facts
- **Advisory lock**: before writing to team-knowledge.md, acquire advisory lock (`touch .lock`, verify mtime <2s), write, release (`rm .lock`). Lock files >60s old are stale — remove and re-acquire.

### Structured Facts with Provenance

- Team-knowledge uses structured facts: `{fact, source, confidence, discovered, verified}`
- Source types: observed, self-described, inferred (user-confirmed retired 2026-04-17 — never emitted; user-level confidence flows via the `user-corrections.md` carrier, weighted 3x by consolidator)
- Confidence tracks observation count: 1=low, 2-4=medium, 5+=high
- Facts not verified within 30 days flagged for review

### Team Retrospectives & Implicit Feedback

- Coordinator runs team retro on Stop (when 2+ roles were spawned): analyzes handoffs, routing, contracts, bottlenecks
- Retros stored in `.claude/ainous-roles/coordinator/retros.md`
- Voice of the User: coordinator detects user corrections via `git diff` at session end
- User corrections stored in `$HOME/.claude/ainous-roles/user-corrections.md`, weighted 3x by consolidator
- Repeated correction patterns become `[user-learned]` strategies

### Signal Agent (External Intelligence)

- @signal monitors external information sources: GitHub, HackerNews, Reddit, Product Hunt, RSS feeds, X/Twitter, ArXiv, blogs
- Deterministic collector pattern: mechanical fetch (reliable) → LLM filter (judgment) → store structured signals
- B+C hybrid routing: signals go to coordinator (Channel B) + directly to roles matching subscription keywords (Channel C)
- Camoufox antifingerprint browser for sources that block standard scrapers (fallback — prefers APIs and RSS)
- Three scan modes: quick (Tier 1 sources, ~5min), deep (all tiers, ~30min), targeted (specific topic)
- `/team-signal` command triggers scans; coordinator can also dispatch on-demand
- Subscription config per project: `.claude/ainous-roles/signal/subscriptions.md`
- Consolidator evolves role subscription lists based on which signals led to actual improvements
- **Serendipity principle**: mandatory exploration quota — every scan includes signals that do NOT match any subscription (Granovetter's weak ties, exploration-exploitation tradeoff)
- Triage over matching: signals should challenge assumptions, not just confirm interests

---

## 6. Observability & Topology

<a id="design-observability"></a>

### Consolidation & Observability

- `/team-status` — team health dashboard (sessions, scores, trends)
- `/team-alerts` — health checks (unused roles, declining scores, low trust, stale consolidation, score miscalibration)
- Cross-role insights: `$HOME/.claude/ainous-roles/consolidator/cross-role-insights.md`
- Consolidator reads execution traces (not just summaries) for evidence-based playbook evolution
- Consolidator reads coordinator retros for routing strategy evolution
- Consolidator reads user corrections (weighted 3x) for implicit feedback integration
- Strategies older than 10 sessions get staleness checks: "would the model do this naturally now?"
- Consolidator uses counterfactual diagnosis: compares sessions with/without strategies to isolate causal impact

<a id="design-topology"></a>

### Topology & Routing

- Coordinator selects named topology per task (full-pipeline, fast-fix, security-first, research-only, review-only, docs-only, signal-scan)
- Topologies defined in coordinator playbook, evolved by consolidator from retro data
- Agent Importance Score (dispatch_count / avg_contribution) from retros guides routing

### Phase Definitions

- Topologies compose phases from `templates/phase-definitions.md` — each phase has entry/exit criteria, roles, skills, artifacts
- Six core phases: research, design, implement, test, review, docs
- Phase transitions logged to task-history.jsonl with artifacts verified
- Coordinator writes phase summary between phases to manage context
- Consolidator evolves phase definitions from retro data (3+ sessions threshold)
- Entry/exit criteria are artifact-based and mechanically verifiable (`test -f`)
- Phase skills are defaults, overridable by coordinator per task

<a id="named-artifacts"></a>

### Named Artifact Contracts

- Each role has named input/output artifacts with explicit producer→consumer contracts
- Named artifacts live as manifests at `agents/capabilities/artifacts/<name>.yaml`; each declares producer, consumer, required_sections, and required_frontmatter. See `agents/capabilities/artifacts/index.yaml` for the registry. The coordinator gate runs `scripts/verify-artifact.sh <name> <path>` which replaces the prior `test -f` check.
- Downstream roles check for upstream artifacts before starting; coordinator verifies artifacts exist before accepting completion
- Artifacts are ephemeral per task (cleared at pipeline start), not permanent records

<a id="design-multi-instance"></a>

### Multi-Instance & Spawn Modes

- Any role can be spawned multiple times for independent tasks (different file targets required for write roles)
- Hybrid spawn: Agent tool for quick tasks, tmux panes for long-running visible work
- Tmux mode coordinates via `.claude/ainous-roles/team-sync/` directory

---

## 7. Role Intelligence & Contracts

<a id="design-role-intelligence"></a>

### Role Intelligence Layers

- Each role's `## Character` section has five subsections beyond archetype + commitments + anti-pattern:
- **Cannot Override**: the authority gradient — what I cannot override regardless of context. Acyclic hierarchy: user → security/authority → architect → developer/tester → supporting roles. Note: architect and researcher defer on different axes — architect cannot override researcher's factual codebase findings; researcher cannot override architect's design decisions. They are peers with orthogonal authority domains, not ordered.
- **Escalates To**: handoff targets when scope exceeds my domain. This is a DAG toward coordinator. Distinct from Cannot Override — escalation is about routing work, not blocking it.
- **Under Pressure**: role-specific behavior in DEGRADING/POOR context — complements charter's universal compression rule with role-specific focus (security never compresses CRITICAL findings; architect commits to one design; researcher reports with labeled uncertainty)
- **Competence Boundary**: what I don't reliably know — prevents motivated reasoning by making knowledge limits explicit; roles flag and defer rather than inventing outside their domain
- The two authority graphs (Cannot Override, Escalates To) are verified acyclic independently. Cannot Override terminates at user/authority. Escalates To terminates at coordinator or user.

<a id="runtime-charter"></a>

### Runtime Charter

- `agents-instructions/runtime-charter.md` — shared execution semantics injected into every role spawn
- Defines: contract format, state conventions, child lifecycle, verification gates, evidence artifacts, acceptance-gated retry
- All roles follow the charter; individual role instructions define domain-specific behavior

### Execution Contracts & Verification Gates

- Every teammate spawn includes an execution contract: required outputs, completion conditions, scope
- Verification gates between phases prevent cascading errors from unverified work
- Developer ↔ tester/code-quality loop until tests pass (max 3 iterations)
- Consolidator uses counterfactual diagnosis: compares sessions with/without strategies to isolate causal impact

### Failure Taxonomy

- Named failure modes with specific recovery actions defined in coordinator instructions
- Seven modes: missing-artifact, verifier-failure, tool-error, timeout, wrong-path, contract-partial, quality-reject
- Each mode has a trigger condition, recovery action, and max retry count
- Failures logged to `.claude/ainous-roles/team-sync/state/task-history.jsonl`

<a id="skills-vault"></a>

### Skills Vault

- Skills live in `skills/` — composable domain-expertise modules
- The coordinator assigns a skill set to each role at spawn (mapping defined in `agents/capabilities/<role>.json` under `default_skills` and `conditional_skills`)
- Agents choose autonomously when to invoke assigned skills — not mandatory, not forced
- Skills contain principles, techniques, and anti-patterns — not workflow orchestration
- Available skills (62): a11y, api-design, auto-decide, caption-format, code-review-ext, competitive-intel, compliance-check, confidence-calibration, content-repurpose, contract-testing, copywriting, data-model, debug, deep-research, design, devops, diagram, docs, estimate, flowchart, ideate, image-background, image-craft-base, image-hero, image-icon, image-illustration, image-social-card, image-texture, image-thumbnail, impact-analysis, infographic, knowledge-structure, migrate, negotiate, observability, onboard, perf, post-mortem, premise-check, present, prioritize, refactor, release-gate, retro-metrics, review-response, runbook-creation, scqa, security-scan, skill-creator, source-validate, strategy-evolution, structural-isolation, summarize, tdd, test-strategy, threat-model, tone-enforce, ui-layout, verify, video-edit, video-script, workflow-auto
- Pipeline-orchestration commands (team-implement, team-review, team-review-periodic) moved to `commands/` — they are user-facing commands, not role-injected skills
- The skill mapping is evolvable by the consolidator based on retro data

### Anti-Soliloquy Principle

- Roles produce artifacts or clean completion signals — never status padding
- "No issues found" with scope reference, not paragraphs explaining what was checked

### Action Space vs Threshold Doctrine

- Authority expands action space for higher trust (more file patterns) but never relaxes risk thresholds
- Safety classifier is constant regardless of trust level or context

<a id="phase-2-supply-chain"></a>

---

## 8. Phase 2 — Semantic Supply Chain Mitigation

Web fetches flow into role context, which flows into persistent memory, which flows into future role spawns — a propagation path for injected content. Phase 2 closes the observable surface of this path.

**Mechanism:** PostToolUse `hooks/taint-flag` fires after every WebFetch or WebSearch (`async: false` — D-6 closes TOCTOU race). It writes a session-scoped flag file at `~/.claude/.taint-flags/<sha256(session_id ‖ nonce)>`. The nonce is generated at session start and stored at `~/.claude/.taint-nonces/<sha256(session_id)>.nonce` (mode 0600). PreToolUse `_validate_taint_field` in authority-enforce.sh reads the flag at Write/Edit time and auto-injects `upstream_chain: [<flag_ts>]` into writes to the 6 provenance-gated surfaces via `hookSpecificOutput.updatedInput`.

**Key invariants:**
- Flag-file path is unforgeable (sha256 of session_id + unreadable nonce via Bash egress)
- `TAINT_FLAG_WRITE_DENY` deny pattern blocks role-initiated writes to `taint-flags/` — only the hook may write
- `NONCE_DIR_WRITE_DENY` blocks role-initiated writes to the nonce dir
- Append-only predicate (reject shorter-than-prior) prevents truncation attacks
- Flag files older than 7 days are swept at SessionStart (D-7 GC)
- Artifacts with non-empty `upstream_chain` cannot auto-promote — require human-review gate (v3 tiered-blocking)

**Residuals (explicitly accepted):**
- R-1: In-session injection (unclosed) — taint tracks tool-surface fetches, not in-context prompt content
- R-2: MCP sources (uncovered) — policy-gated only
- R-3: Bash curl (uncovered) — roles retain Bash; Bash egress bypasses taint-flag hook
- R-4: `content_hash` is forensics-only — not a tamper-resistance claim
- R-5: Nonce is discoverable via Read tool — forgery resistance comes from write-deny on flag paths, not nonce secrecy
- R-nonce-clobber (MEDIUM, accepted v5.9.5): The per-spawn nonce file (`~/.claude/teams/<team>/nonces/<mate>.nonce`) is written with O_TRUNC, so re-spawning the same `(team_name, teammate_name)` overwrites the prior nonce — this is intentional, because crash-recovery re-spawn requires the newest teammate session to own the HMAC key that write-proxy reads back. The only abuse is a self-defeating DoS: an attacker must already hold the Agent (full-trust spawn) capability, gains no path/surface/identity it could not get by spawning its own teammate, and merely invalidates a victim's in-flight envelopes (visible as HMAC-mismatch lines in the write-proxy error log plus an anomalous spawn event in task-history.jsonl). O_EXCL was rejected because it would silently break legitimate re-spawn by stranding the recovered teammate on a stale nonce.

**v5.8.0 extension — Scope-reduction-on-taint (C-2):** When `_session_is_tainted(session_id)` returns True, `authority-enforce.sh` applies a reduced-capability profile for the remainder of the session: Bash is restricted to a read-only allowlist (ls, cat, grep, head, tail, wc, find, pwd, echo, rg, git status/log/diff — no curl, wget, pip install, or modification commands); Write/Edit are restricted to the role's own paths (`.claude/ainous-roles/<role>/`) and the findings artifacts directory (`.claude/ainous-roles/team-sync/artifacts/`); Read is unrestricted. Decisions are logged to `~/.claude/.authority-tainted-decisions.log`. The session-sticky nature means once tainted, not cleared within the session — escape hatch is coordinator-initiated fresh spawn. This closes the 8-hour detection gap where a tainted role retained full Bash and network access after a poisoned WebFetch. See design artifact `.claude/ainous-roles/team-sync/artifacts/v5.8-design-next-wave.md §C-2`.

**v5.9.0 extension — Agent-boundary taint propagation (Option A):** Closes the context-dependent injection laundering gap identified in ClawGuard (April 2026): a tainted role (A) summarizes fetched content, passes the summary to a clean peer (B) via Agent or SendMessage, and B's writes attest `upstream_chain: []` — true-by-hook, false-in-reality. Option A extends `hooks/spawn-telemetry` (PostToolUse on Agent): when the parent session is tainted at spawn time, the hook writes an inherited taint-flag record into the **child's** session flag file (path `sha256(child_sid ‖ child_nonce)`), carrying `upstream_chain: [{inherited: true, parent_hashed_sid: <hash>, ts: ...}]`. The child's first Write to a provenance surface triggers `_validate_taint_field` exactly as if the child had WebFetched. D-3 invariant preserved: hook writes taint, not role. Child session_id sourced from `tool_result.session_id` in PostToolUse payload; fail-open when unavailable (propagation deferred, logged). Residual R-6: if `spawn-telemetry` crashes, propagation fails silently (fail-open at propagation step vs. fail-closed at validation step — an asymmetry documented in the design). Option B' (envelope-field precision propagation) deferred to v5.9.1 pending over-blocking rate data. Test coverage: `tests/test-taint-propagation.sh` (5 TCs — TC-TP-1 through TC-TP-5). See `.claude/ainous-roles/team-sync/artifacts/v5.9-design-taint-boundary.md`.

**Canonical design:** `.claude/ainous-roles/team-sync/artifacts/semantic-supply-chain-design-v2.1.md`

<a id="phase-3a-spawn-observability"></a>

## 9. Phase 3a — Spawn-Event Observability

**Mechanism:** PostToolUse `hooks/spawn-telemetry` fires after every Agent tool invocation. It mechanically writes a `spawn` event to task-history.jsonl with: `role`, `teammate_name`, `team_name`, `spawn_mode` (`"agent"` | `"team_name"`), `background`, `prompt_bytes`, `session_id`, `write_proxy_nonce_sha256`. No coordinator discipline required — the hook fires regardless.

**Result:** Spawn events are now mechanically emitted, closing the observability gap.

**Layer-2 retired in v5.8.0** — contract-implied authorization was never populated in practice; removed rather than patched. Eight weeks of production spawn events showed `scope: []` on every event; the enforcement block iterated an empty list and fell through to Layer-3 on 100% of writes. Authorization now flows: Layer-1 (project baselines) → Layer-3 (hardcoded baselines + decisions.md). Spawn events continue to emit for observability but no longer carry a `scope` field. See `docs/open-issues.md` (OI-v57-1 CLOSED) for decision record.

**Canonical design:** `.claude/ainous-roles/team-sync/artifacts/architect-design-phase3-team-mode-integration.md`

<a id="team-mode-integration"></a>

## 10. Team-Mode × Plugin Integration

Claude Code supports native tmux teammate spawning via `Agent(team_name=..., name=...)`. The plugin integrates with this surface; several design decisions were forced by upstream constraints.

**The crash constraint:** Claude Code has a reproducible crash (`H.toolUseContext.getAppState is not a function`) when a teammate's Write/Edit tool triggers the team-lead approval UI. This fires after `authority-enforce.sh` exits 0 — beyond our enforcement reach.

**Policy response (v5.4.1 §15):** Teammates MUST NOT call Write, Edit, or NotebookEdit. Teammates produce content, return it via SendMessage in a clearly-delimited payload with intended destination path + provenance block. The coordinator (team-lead) performs the Write preserving role attribution. This is charter-level policy, not hook enforcement.

**Write-proxy protocol (v5.5.0 §15.1):** Envelope-based durability channel for async/background teammates where the coordinator may not be alive at teammate-stop time. Teammate SendMessages an HMAC-authenticated envelope (`<!-- WRITE-PROXY-ENVELOPE v1 -->`); PostToolUse `hooks/write-proxy` intercepts, verifies HMAC via `hooks/_hmac_common.py`, applies path containment (C-1), writes via Python `open()` (bypasses the crash path), emits `hook-write` audit event (C-3). Three-tier identity resolution: `session_id` → spawn event → envelope `role` field → teammate-nonce event → `teammate_name`/`team_name` direct. HMAC computed via `scripts/compute-envelope-hmac.sh` (canonical helper, shared formula).

**Operational decisions:**
- **State-reaper (v5.6.0):** SessionStart sweeps `~/.claude/teams/*/config.json`, archives entries whose lead PID is dead — prevents stale active-team state from blocking new team creation
- **Naming convention (v5.6.5):** `name="ainous-team:<role>(<description>)"` — provides informative pane dividers; enforced by coordinator spawn-prompt discipline
- **Journal-discipline (v5.6.6):** Execution-focused roles (researcher, developer, etc.) need explicit `journal-path` injection in spawn prompt + end-of-task ritual; the Stop hook does not fire in subagent/teammate contexts — journals must be written inline. `scripts/install-post-commit-journal-reminder.sh` installs a git hook to reinforce coordinator discipline.
- **Release-gate (v5.6.7):** `scripts/verify-role-infrastructure.sh` verifies all roles have 4-file scaffold (playbook.md, growth.json, journal.md, learnings.jsonl) + agent stub + capabilities JSON before shipping.

**Artifact references:**
- `.claude/ainous-roles/team-sync/artifacts/architect-design-phase3-team-mode-integration.md`
- `.claude/ainous-roles/team-sync/artifacts/architect-design-write-proxy-protocol.md`
- `docs/team-mode-recovery.md`

<a id="governance-mechanisms"></a>

---

## Appendix: Governance Mechanisms

The following mechanisms span three classification tiers. NORMATIVE rows are prompt-level instructions with no code enforcement. PARTIAL rows have partial mechanical backing noted inline. ENFORCED rows are fully code-backed. As of v5.10.0+ the enforced surface includes both `hooks/authority-enforce.sh` (security gate) and `scripts/memory-maintain.py` (memory lifecycle gate), the latter invoked fail-open from the SessionEnd hook and checked hard-fail in `scripts/pre-ship-gate.sh` (see CLAUDE.md §Enforcement).

| Mechanism | Status | Source |
|-----------|--------|--------|
| Mechanical routing via Agent Cards | NORMATIVE | `coordinator-instructions.md` instructs check of `index.json`; no code enforces the lookup |
| Consolidator-updated playbooks / utility scoring | NORMATIVE | Python block in consolidator prompt the LLM is asked to execute mentally; no standalone script |
| Memory Lifecycle Hot/Warm/Cold tiers | NORMATIVE | No cache manager, no TTL, no eviction daemon; tiers are conceptual |
| Expertise-weighted synthesis | NORMATIVE | Prose-only in coordinator instructions |
| Structural provocation injection | NORMATIVE | Prose trigger with LLM self-detection |
| Anti-conformity for parallel reviewers | NORMATIVE | Coordinator self-discipline |
| Strategy promotion / reinforce / RETIREMENT (incl. playbook 30-cap retirement) | NORMATIVE | Retirement and reinforce are consolidator judgment. `enforce_playbook_cap()` in `scripts/memory-maintain.py` mechanically REPORTS when the cap is exceeded (exits 1 in `--check`), but does not auto-retire any strategy — the comment in code reads "retirement requires consolidator judgment." Cap violation is thus reported mechanically; retirement action remains normative. |
| Poisoned-memory promotion gate (D-8) | NORMATIVE | Prose-only in consolidator instructions; no code gate |
| Advisory lock on team-knowledge | NORMATIVE | Explicitly not OS-enforced |
| Context degradation tiers (PEAK/GOOD/POOR) | NORMATIVE | LLM self-assesses from heuristics; no token counter |
| Predictive routing / situational-leadership spawn verbosity | NORMATIVE | Prose-only in coordinator instructions |
| 50-session memory cap (v5.10.0+) | ENFORCED | `enforce_session_cap()` in `scripts/memory-maintain.py` — WAL-safe trim + archive to `sessions-archive.jsonl`; invoked fail-open from `hooks/session-end` and hard-fail from `scripts/pre-ship-gate.sh` Gate 3. Previously a Python block the LLM was asked to execute mentally. |
| learnings.jsonl dedup (v5.10.0+) | ENFORCED | `dedup_learnings()` in `scripts/memory-maintain.py` — keeps highest-confidence entry per (key, type) pair; WAL-safe under advisory lock; same invocation chain as session cap. |
| learnings.jsonl orphan-prune (v5.10.0+) | ENFORCED | `prune_orphan_learnings()` in `scripts/memory-maintain.py` — removes entries whose every referenced file is missing; same invocation chain. |
| Expired-decision rotation (v5.10.0+) | ENFORCED | `rotate_expired_decisions()` in `scripts/memory-maintain.py` — moves decisions.md blocks with a past `expires:` date to `decisions-archive.md`; WAL-safe under advisory lock; same invocation chain. |
| Stale-fact flagging (v5.10.0+) | ENFORCED (flagging); NORMATIVE (deletion) | `flag_stale_facts()` in `scripts/memory-maintain.py` mechanically annotates team-knowledge.md lines with `<!-- STALE: last-seen YYYY-MM-DD -->` when the `discovered:` date is older than 180 days. No facts are removed by the script — deletion or consolidation of flagged facts remains consolidator judgment. |
| Knowledge-index integrity (v5.10.0+) | ENFORCED | `verify_index_integrity()` in `scripts/memory-maintain.py` — checks all Markdown links in `team-sync/index.md`; removes broken link substrings (fail-safe: refuses if removal would shrink the index by >30%); WAL-safe under advisory lock; same invocation chain. |
| Trust-level audit — clamping DOWN (v5.12.0+) | ENFORCED | `trust_audit()` in `scripts/memory-maintain.py` — mechanically CLAMPS trust.level down to the maximum justified by session history (score + sessions_completed); fail-safe; WAL-safe; checked in pre-ship Gate 4. "Principal" level (manual grant) is exempt from auto-clamping. Never raises trust. |
| Trust-level audit — RAISING | NORMATIVE | `trust_audit()` deliberately never raises trust.level — raising is left to consolidator judgment. Only downward clamping is mechanical. |
| Soft enforcement (main session NOTE) | PARTIAL | Implemented in `hooks/authority-enforce.sh:35-41` but advisory only — emits a NOTE, does not block. Behavior is informational, not a safety invariant. |
| HALT events wired end-to-end | PARTIAL | `runtime-charter.md` (emit) + coordinator instructions (grep). Enforcement gate does NOT read HALT. |
| Session-log crash recovery (read path) | PARTIAL | Writes exist (task-history.jsonl, hook-enforced). Read path is a prompt instruction; not a hook or daemon. |
| Fail-closed authority gate | ENFORCED | `hooks/authority-enforce.sh` — the primary security-surface code-backed claim |
| Taint-flag mitigation (v5.3.0+) | ENFORCED | `hooks/taint-flag` (PostToolUse) + `_validate_taint_field` (PreToolUse in authority-enforce.sh) — mechanically backed. See §phase-2-supply-chain. |
| Scope-reduction-on-taint (v5.8.0+) | ENFORCED | `_session_is_tainted` predicate in `authority-enforce.sh` — tainted sessions restricted to read-only Bash allowlist and role-own/artifacts Write paths. See §phase-2-supply-chain and design artifact `v5.8-design-next-wave.md`. |
| Agent-boundary taint propagation (v5.9.0, Option A) | ENFORCED | `hooks/spawn-telemetry` extended — parent-to-child taint inheritance on Agent spawn when parent is tainted. Closes cross-agent laundering gap. Fail-open when child_sid unavailable. See §phase-2-supply-chain. |
| Spawn-event auto-emission (v5.4.0+) | ENFORCED | `hooks/spawn-telemetry` PostToolUse hook — mechanical, not discipline-dependent |
| Write-proxy hook (v5.5.0+) | ENFORCED | `hooks/write-proxy` PostToolUse hook on SendMessage — HMAC-verified writes on teammate behalf |
| No-teammate-Write policy (v5.4.1 §15) | ENFORCED (v5.9.0) | PreToolUse block in `authority-enforce.sh` — CLAUDE_TEAM_NAME env var detection; team-leads (CLAUDE_TEAM_ROLE=team-lead) exempt. Previously normative-only. |
| Archive-file capping — sessions-archive.jsonl / decisions-archive.md (v5.12.1) | ENFORCED | `cap_sessions_archive()` and `cap_decisions_archive()` in `scripts/memory-maintain.py` — keep the most recent N entries (`ARCHIVE_SESSION_CAP=500`, `ARCHIVE_DECISION_CAP=200`), drop oldest; WAL-safe under advisory lock; same fail-open SessionEnd invocation chain; reported in `--check`. Bounds the cold-storage growth that capping the hot arrays moved downstream. |
| Model-field consistency between agents/*.md and capabilities/*.json (v5.12.1) | ENFORCED | `scripts/verify-model-consistency.sh` — asserts each role's authoritative `agents/<role>.md` frontmatter `model:` equals its `capabilities/<role>.json` `"model"`; wired as pre-ship Gate 5 (exit 5 on mismatch). Catches dual-source drift without removing either field. |
| Pane-divider naming convention (v5.6.5) | NORMATIVE | Coordinator spawn-prompt discipline; no enforcement hook |

**Intentional vs. candidate classification note (as of v5.12.0):** NORMATIVE rows that require genuine LLM judgment and are intentionally permanent: expertise-weighted synthesis, predictive routing, situational-leadership spawn verbosity, poisoned-memory promotion gate (D-8), strategy retirement, trust raising, and HALT wiring. These involve trade-off reasoning that cannot be safely reduced to a predicate. NORMATIVE rows that are candidates for future mechanical enforcement: mechanical routing via Agent Cards (predicate over index.json is straightforward) and advisory lock on team-knowledge (could become OS-level). (Archive-file capping and model-field consistency were candidates in earlier drafts; both became ENFORCED in v5.12.1 — see the rows above.)

*Source of truth for this table: `docs/2026-04-17-critical-refinement-analysis.md §F2`. Do not duplicate — reference that file for updates.*
