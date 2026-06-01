# Runtime Charter — Shared Execution Semantics

**Layer contract:** This charter governs role behavior (identity layer). Phase definitions govern when roles run (template layer). Skills govern how roles reason (expertise layer). Do not embed phase logic or skill technique inside role instructions.

This document defines how all ainous-team roles execute within the system.
Each role loads this charter during its Startup Sequence.
Individual role instructions define WHAT a role does; this charter defines HOW.

**For team-mode teammates only:** Subagent spawns automatically receive this charter via the agent-definition system prompt. Team-mode teammates (spawned via `Agent(team_name=..., name=...)`) do NOT — the harness does not inject the agent definition. Your coordinator has directed you here via the spawn-prompt identity header; load this file fully before any tool calls. See coordinator-instructions.md §Team-mode spawn protocol Step 5.

## 1. Execution Contract

Every role spawn includes an execution contract with these fields:
- **Required output:** specific files, findings, or artifacts the role must deliver
- **Completion condition:** how to know the work is done (tests pass, findings listed, etc.)
- **Permission scope:** baseline write paths for this role
- **Budget:** scope limit (e.g., "only the auth module")
- **Verification criterion:** what the coordinator will mechanically check to confirm completion

A role MUST NOT declare "Contract met: yes" unless all required outputs exist at their declared paths.

## 2. State Conventions

- **Journals:** `.claude/ainous-roles/<role>/journal.md` — append-only session records
- **Memory:** `.claude/ainous-roles/<role>/memory.md` — codebase facts and entities
- **Team sync:** `.claude/ainous-roles/team-sync/` — inter-role coordination
  - `state/` — phase completion status, contract fulfillment
  - `artifacts/` — role deliverables (findings, reports, intermediate outputs)
- **Task history:** `.claude/ainous-roles/team-sync/state/task-history.jsonl` — structured phase completion log

### Journal Entry Format

```
## <date> — <task summary>
**Tags:** <task-type: implement|fix|review|design|research|docs>, <area: e.g. auth, api, build>
**Task:** <what was done>
**Outcome:** <result>
**Contract met:** <yes/no — which outputs delivered>
**Learned:** <key insight>
**Strategies used:** <named strategies from playbook>
**Execution trace:** <key decisions, errors, pivots>
```

The `Tags` line enables structured retrieval — the @retriever can filter by task-type and area before doing text matching, significantly improving accuracy on large journals.

### Task History Entry Format (JSONL, one per line)

The task history is the team's **session log** — an append-only record of all significant events, not just phase completions. Any harness (coordinator) can read this log to understand what happened and resume after interruption.

Event types:

```json
{"timestamp": "ISO-8601", "event": "spawn", "role": "<role>", "phase": "<phase>", "detail": "<task summary>"}
{"timestamp": "ISO-8601", "event": "skill-invoked", "role": "<role>", "skill": "<skill-name>", "session": "<session-id or ISO date>", "source": "coordinator-spawn | role-self-report"}
{"timestamp": "ISO-8601", "event": "completed", "role": "<role>", "phase": "<phase>", "artifacts": ["<path>"], "contract_status": "met|unmet|partial", "confidence": 8, "confidence_basis": "tested|reasoned|inferred|guessed", "uncertain_areas": ["<area-1>", "<area-2>"]}
{"timestamp": "ISO-8601", "event": "failed", "role": "<role>", "phase": "<phase>", "failure_mode": "<mode>", "detail": "<error>"}
{"timestamp": "ISO-8601", "event": "retried", "role": "<role>", "phase": "<phase>", "attempt": 2}
{"timestamp": "ISO-8601", "event": "gate-passed", "phase": "<phase>", "detail": "all artifacts verified"}
{"timestamp": "ISO-8601", "event": "gate-failed", "phase": "<phase>", "failure_mode": "<mode>"}
{"timestamp": "ISO-8601", "event": "phase-transition", "from_phase": "<phase>", "to_phase": "<phase>", "gate_status": "passed", "artifacts_verified": ["<artifact-name>"]}
{"type": "routing-decision", "timestamp": "ISO-8601", "task_id": "<task-id>", "typed_candidates": [...], "filtered": ["<role>: <reason>"], "selected": "DELEGATE_ROLE", "role": "<role>", "topology": "<topology-name>", "phases": ["<phase-list>"]}
{"timestamp": "ISO-8601", "event": "HALT", "role": "<role>", "phase": "<phase>", "reason": "<specific defect — what was found>", "evidence": "<what was observed that triggers the halt>"}
{"timestamp": "ISO-8601", "event": "framing-doubt", "role": "<role>", "phase": "<phase>", "doubt": "<what feels wrong about the problem framing>", "blocking": false}
```

**HALT authorization**: Every role is explicitly authorized to emit a HALT event when it detects a defect that will propagate downstream if not addressed. HALT is a quality signal, not a failure — framing it as failure suppresses the signal. Coordinator reads HALT events before proceeding to the next phase and treats them as verification gate failures.

**framing-doubt**: Non-blocking signal emitted when a role has uncertainty about the problem framing but not enough confidence to HALT. Coordinator reads framing-doubt events at synthesis time, not immediately. Multiple framing-doubt events from different roles on the same task are a strong signal to pause and re-examine the brief.

Note: `confidence` and `uncertain_areas` are optional but strongly encouraged. `confidence_basis` is required when `confidence` is provided. Roles that consistently omit confidence are flagged by consolidator for calibration review.

### team-knowledge.md Write Protocol (F-2)

Before writing to `$HOME/.claude/ainous-roles/team-knowledge.md` or `.claude/ainous-roles/team-knowledge.md`, follow this advisory lock sequence:

1. Acquire advisory lock: `touch <path>.lock` then verify you created it by checking its mtime is less than 2 seconds old (`stat -f %m <path>.lock` on macOS, `stat -c %Y <path>.lock` on Linux, compare to `date +%s`).
2. Write your facts to the knowledge file.
3. Release lock: `rm <path>.lock`
4. If a lock file is found that is older than 60 seconds, treat it as stale — remove it and re-acquire.

This is an advisory lock (not OS-enforced), but it prevents interleaved entries when a consolidation run and a role write happen concurrently. All roles and the consolidator must follow this protocol when writing to either team-knowledge file.

## 3. Execution Traces

Roles should save raw diagnostic data to `.claude/ainous-roles/<role>/traces/` during sessions:
- Error outputs (full stderr/stdout from failed commands)
- Key tool call sequences that led to success or failure
- Strategy application context (which strategy was tried, what happened)

Traces are the consolidator's richest signal — research shows summaries lose 16 points of diagnostic accuracy vs raw traces. The consolidator greps traces selectively; roles write them as they work.

File naming: `<date>-<task-slug>.md` (e.g., `2026-04-09-auth-bugfix.md`)

## 4. Strategy Annotation During Use

When a role uses a playbook strategy during a session, annotate the result inline in the journal:
```
**Strategies used:** strategy-name [success, context: large refactor], other-strategy [failed, context: monorepo with shared deps]
```

These annotations give the consolidator richer signal than binary "used/not used" — they capture WHY a strategy succeeded or failed in context.

## 5. Child Lifecycle

### Startup Sequence (canonical — referenced by role instruction files)

On activation, every role executes these steps in order, substituting `<role>` with its own role name:

1. Read the **runtime charter**: `${CLAUDE_PLUGIN_ROOT}/agents-instructions/runtime-charter.md` — shared execution semantics for all roles
2. Read your **playbook**: `~/.claude/ainous-roles/<role>/playbook.md` (evolved strategies)
3. Read **project context**: `.claude/ainous-roles/<role>/journal.md` and `memory.md` (if exist)
4. Read **team knowledge**: `~/.claude/ainous-roles/team-knowledge.md` and `.claude/ainous-roles/team-knowledge.md`
5. Initialize: `mkdir -p .claude/ainous-roles/<role> .claude/ainous-roles/<role>/traces .claude/ainous-roles/team-sync/state .claude/ainous-roles/team-sync/artifacts`
6. Set role marker: `echo "<role>" > ~/.claude/.session-role || exit 1`

Roles with additional startup reads (e.g., authority loading the authority-book and decision log, signal loading subscriptions) append those reads inline in their own instruction files after step 2.

---

1. **Spawn** — coordinator provides execution contract + skill assignment; agent self-loads its playbook, project context, and this charter via Startup Sequence
2. **Init** — role creates directories: `mkdir -p .claude/ainous-roles/<role> .claude/ainous-roles/<role>/traces .claude/ainous-roles/team-sync/state .claude/ainous-roles/team-sync/artifacts`
3. **Execute** — role works within permission scope, checkpoints every 15 min, saves traces for significant errors/decisions. Subject to behavioral guards (see sections 11-12).
4. **Verify** — role self-checks contract (required outputs exist at paths)
5. **Journal** — role appends session entry with strategy annotations. This write is mandatory before returning, even when spawned via the Agent tool. The Stop hook does not fire for subagent contexts — the journal entry must be written inline by the role itself, not deferred to the hook.
6. **Learnings** — role appends structured entries to `learnings.jsonl` for genuine discoveries (apply the 5-minute test: would knowing this save 5+ minutes in a future session?)
7. **Stop** — Stop hook fires, captures any missed learnings

## 6. Verification Gates

Between phases, the coordinator mechanically verifies before proceeding:
1. **HALT check (runs before all other checks)**: grep `task-history.jsonl` for `"event":"HALT"` entries in the current phase. If any HALT event exists, the gate fails immediately — artifact presence is irrelevant. Emit `gate-failed` with `failure_mode: "halt-emitted"`. Escalate to user with the HALT reason and evidence.
2. Check that declared output files exist and pass schema: `scripts/verify-artifact.sh <name> <path>` (exits 0 = pass, exits 2 = fail). The script checks file existence AND required sections/frontmatter per the artifact manifest. In warn mode (default) it exits 0 and logs an `artifact-schema-warn` event on schema failure — promote to enforce mode by setting `VERIFY_ARTIFACT_MODE=enforce`.
3. Check that task-history.jsonl has a completion entry for the phase
4. If verification fails, apply the failure taxonomy (see coordinator instructions)

Only proceed to the next phase when the gate passes. HALT events are first-class gate failures — they cannot be overridden by artifact presence or role claims of completion.

**Emitting roles**: every role is explicitly authorized to emit a HALT event when it detects a defect that will propagate downstream. Format: `{"timestamp": "...", "event": "HALT", "role": "<role>", "phase": "<phase>", "reason": "<specific defect>", "evidence": "<observed pattern or code>"}`. Suppressing a defect signal to avoid appearing to fail is the anti-pattern. HALT is a quality signal, not a failure.

## 7. Evidence Artifacts & Named Handoff Contracts

Roles produce **typed artifacts** in `.claude/ainous-roles/team-sync/artifacts/`. Each artifact has a named producer and named consumer — downstream roles know exactly what file to read from the previous phase.

## Artifact Registry

Named artifacts and their schemas live in `agents/capabilities/artifacts/`. See `agents/capabilities/artifacts/index.yaml` for the full registry. The coordinator's gate (step 2 above) runs `scripts/verify-artifact.sh <name> <path>` which checks file existence AND required sections/frontmatter per the manifest for that artifact name.

### Artifact Format

Each artifact file must include:
- **Header**: role name, date, task summary
- **Findings**: structured blocks with file path, line number (if applicable), severity/confidence, and specific observation
- **Handoff notes**: what the consumer should pay attention to, known gaps, unresolved questions

### Contract Rules

- A role MUST check for upstream artifacts before starting work. If the execution contract says "reads: architect-design.md" and the file doesn't exist, STOP and report missing input.
- A role MUST produce its declared artifact before claiming contract completion. The coordinator mechanically verifies: `test -f .claude/ainous-roles/team-sync/artifacts/<expected-file>`.
- Artifacts are ephemeral per task — cleared at the start of each new pipeline. They are NOT the permanent record (journals are).
- When a pipeline has multiple passes (e.g., developer→tester→developer), artifacts are overwritten with the latest version. Git preserves history.

### Informed Roles

Each artifact contract includes an `informed_roles` list — roles that should receive the artifact as read-only context even though they are not the primary consumer. Example: security-findings.md is consumed by developer but also informs architect (who made the design decisions that created the vulnerability). Coordinator injects informed_roles' artifacts into spawn context at the start of the next phase.

## 8. Acceptance-Gated Retry

When a phase output fails its completion condition:
1. Identify the failure mode (see failure taxonomy)
2. Send the role the failure output as context
3. **Track issue count**: count the number of issues/failures in each iteration
4. Retry up to N times (default: 3 for implementation, 2 for others)
5. **Stall detection**: if `issue_count >= prev_issue_count` after a retry, the revision loop is stalling — break early and escalate rather than burning remaining iterations on a non-converging problem

   **Yes-And retry variant (S-2)**: when stall is detected specifically in a tester↔developer loop, before escalating try one Yes-And reframe. Instead of sending the developer a list of failures, send:
   - "The following tests PASS: [list of passing tests]. Extend coverage for these edge cases: [failing tests reframed as missing requirements, not failures]."
   - This reframes failures as missing coverage rather than broken code, which reduces anchoring bias and often breaks the stall by changing the developer's frame of reference.
   - Apply Yes-And at most once per loop. If issue count still does not decrease after the reframe, escalate normally.

6. If max retries exceeded OR stall detected, escalate to coordinator for re-routing or user escalation
7. Log each retry in task-history.jsonl with `"action": "retried"` and include `"issues": <count>`

This pattern applies to ANY phase, not just developer↔tester.

## 9. Structured Learnings (JSONL)

In addition to Markdown journal entries, roles log structured learnings to `.claude/ainous-roles/<role>/learnings.jsonl`. This enables programmatic search, deduplication, and staleness detection by the consolidator.

### Learning Entry Format

```json
{"timestamp": "ISO-8601", "skill": "<skill-used>", "type": "<type>", "key": "<unique-key>", "insight": "<what was learned>", "confidence": 8, "source": "observed|user-stated", "files": ["<related-file-paths>"], "utility": 0}
```

### Utility Scoring (MemRL-inspired)

Each learning entry has a `utility` score (integer, starts at 0) that tracks real-world impact:
- **+2** when the learning is invoked and the session succeeds (strategy applied → good outcome)
- **+1** when the learning is referenced during planning or decision-making
- **-1** when the learning is invoked but the session fails or the strategy doesn't help
- **-2** when the learning contradicts observed reality (fact was wrong)

The consolidator updates utility scores during Phase 3. Higher-utility learnings are injected first at startup (sort by utility descending, then recency). This ensures the most impactful learnings get context priority, not just the most recent ones.

Utility scoring solves the "flat memory" problem: without it, a brilliant insight from session 3 and a trivial observation from session 50 compete equally for context space. With utility, impact wins over recency.

### Learning Types

| Type | Description | Example |
|------|-------------|---------|
| `operational` | How to do something in this project | "Run `bun test --filter auth` for auth module tests" |
| `pattern` | A code or architecture pattern discovered | "All API routes use middleware chain in routes/index.ts" |
| `pitfall` | A mistake to avoid | "Don't modify shared state in parallel test suites" |
| `preference` | User or project preference | "User prefers single bundled PRs for refactors" |
| `architecture` | System design insight | "Auth service is stateless — session stored in Redis" |
| `tool` | Tool usage insight | "gh pr create needs --base flag when not on default branch" |

### Rules

- **Append-only**: latest entry wins for dedup by `key` + `type`
- **5-minute test**: only log if knowing this would save 5+ minutes in a future session
- **File references**: include `files` array when the learning relates to specific code paths — enables staleness pruning (if the file no longer exists, the learning may be stale)
- At skill startup, if >5 learnings exist, inject the top 3 by utility score (not just most recent)
- The consolidator reads learnings.jsonl for structured signal alongside Markdown journals
- **Skill invocation tracking**: when a role reads and applies a skill during execution, it MUST emit a `skill-invoked` event to task-history.jsonl **before** emitting its `completed` event. This is a mandatory pre-condition for completion, not optional prose. Format:
  ```bash
  scripts/log-event.sh skill-invoked role=<role> skill=<skill-name> session=<ISO-date> source=role-self-report
  ```
  Emit one event per skill actually applied (read its content and acted on its principles). Do NOT emit for skills assigned but not consulted — omission here is correct signal. Source MUST be `"role-self-report"` for role-emitted events. This data enables the consolidator to identify unused skills (candidates for pruning) and high-value skills (candidates for default assignment to more roles).

## 10. Anti-Soliloquy Principle

- If a role has nothing actionable to report, produce no output — do not pad with status messages like "I reviewed everything and it looks good" or "No issues found."
- Every output must contain either: (a) concrete findings or artifacts, or (b) a clean completion signal with evidence reference.
- Never output idle status text. Roles produce artifacts or nothing.
- Status padding wastes tokens and obscures signal. If clean, say `Clean — no findings [scope: <what was checked>]`, not a paragraph explaining what you looked at.
- This applies to all roles, including analytical roles (security, code-quality). A security scan that finds nothing should output one line, not a report about what it scanned.

## 11. Behavioral Guards

### Phase-Boundary Quality Checkpoint (F-3)

Between every phase transition, before spawning the next phase's role, the coordinator runs a 3-question quality check:

1. Did the previous phase produce its required exit artifact? (mechanical: `test -f <artifact-path>`)
2. Does the artifact's content match the task's original intent? (drift check — re-read the original task description and compare against the artifact's stated scope and conclusions)
3. Is the artifact internally consistent? (no contradictions, no missing sections declared in the format)

If any check fails, log a `gate-failed` event and do NOT proceed to the next phase. Apply the failure taxonomy and retry or escalate.

> Context drift — not context size — causes the majority of cascading failures. A 2% semantic drift per phase compounds to 40%+ failure rate by chain end.

### Analysis Paralysis Guard (from GSD)

If a role makes **5+ consecutive read-only tool calls** (Read, Grep, Glob, LS) without an action call (Edit, Write, Bash), it MUST stop and either:
- **Act**: make the change based on what was learned
- **Report blocked**: explain what is preventing action and escalate

This prevents roles from spiraling into endless exploration. Reading is preparation for action, not a substitute for it. The guard applies during the Execute phase — startup context loading (phase 1-2) is exempt.

### Sequential Conformity Guard

**Sequential Conformity Guard**: Anti-conformity injection is not limited to parallel reviewers. In sequential pipelines, each role that receives another role's output as a handoff should receive in its spawn prompt: "The previous role's output is a handoff artifact, not a conclusion. You are free to disagree with its framing, challenge its assumptions, or surface constraints it missed." Apply this especially to: developer receiving architect design, code-quality receiving any prior finding, researcher receiving a pre-framed brief.

## 12. Deviation Rules (from GSD)

When a role discovers something outside its execution contract scope during work, apply these rules in priority order:

| Rule | Condition | Action |
|------|-----------|--------|
| **Rule 0** | Third attempt on the same approach without measurable progress | STOP. Declare approach failed. Emit HALT or framing-doubt event with findings. Do not attempt the same approach a fourth time. |
| **Rule 1** | Found a bug (broken code, failing test) | Auto-fix it. Don't ask. Log the fix. |
| **Rule 2** | Missing critical functionality for contract completion | Auto-add the minimum needed. Don't ask. Log it. |
| **Rule 3** | Found a blocking issue (dependency, config, environment) | Auto-fix if possible. If not, report as BLOCKED. |
| **Rule 4** | Discovered an architectural concern or scope expansion | STOP. Report to coordinator. Do NOT auto-fix. |

Priority: `Rule 4 > Rules 1-3`. Architectural changes always escalate. Bugs, missing pieces, and blockers get auto-fixed within the role's baseline permissions.

Rule 0 addresses the sunk cost fallacy — the most dangerous unguarded cognitive bias in iterative development. Three identical attempts without improvement means the approach is wrong, not the execution.

This complements authority enforcement: authority controls what a role CAN do; deviation rules control what it SHOULD do without asking.

## 13. Context Degradation Tiers (from GSD)

Context quality can degrade as the context window fills. Roles adjust behavior based on **observed
pressure signals**, not on their own estimate of how full the window is. Self-estimated fill
percentages are unreliable — a large-context session (e.g. 1M tokens) running at "70% fill" still
has hundreds of thousands of tokens available and should operate at full exploration. Tier changes
MUST be triggered by an explicit coordinator signal OR by directly observed tool/error pressure,
never by a role's self-guessed percentage.

**Large-context sessions** (where the coordinator has not signaled degradation and no tool errors
are appearing): operate as PEAK regardless of perceived fill. The lower tiers simply do not fire.

**Tier activation rules:**
- **PEAK** — default; active unless a lower tier is triggered.
- **GOOD / DEGRADING / POOR** — activate only when the coordinator explicitly signals a tier
  downgrade (e.g. injects "context-pressure: DEGRADING" into the role's prompt or mailbox), OR
  when the role observes direct tool pressure: repeated tool-call failures, truncated outputs, or
  the Early Warning Signs below.

| Tier | Activation Condition | Behavior |
|------|---------------------|----------|
| **PEAK** | Default — no pressure signals | Full exploration, detailed analysis, rich output |
| **GOOD** | Coordinator signals GOOD, or minor output truncation observed | Normal operation, standard detail |
| **DEGRADING** | Coordinator signals DEGRADING, or 2+ consecutive tool errors | Compress output, skip optional analysis, prioritize contract deliverables |
| **POOR** | Coordinator signals POOR, or repeated tool failures blocking progress | Minimum viable output only, complete current task and stop, do not start new subtasks |

**Degradation is graceful**: on large-context models the lower tiers will never fire during normal
operation — they exist as a safety net for weaker models or genuinely long sessions. Roles on small
contexts (200K) that receive no coordinator signal should watch Early Warning Signs more actively
and self-trigger one tier lower if they appear.

### Early Warning Signs (detect before hitting hard limits)
1. **Silent partial completion**: role starts skipping steps it previously followed
2. **Increasing vagueness**: output becomes less specific, uses more hedging language
3. **Skipped protocol steps**: role stops logging to journal/traces, skips verification

If a role detects these signs in its own output, it should: (a) log a `context-pressure` trace, (b) switch to the next lower tier's behavior, (c) complete current work and report status rather than starting new subtasks.

## 14. Skill Self-Exclusion

Skills should include guidance on when NOT to apply themselves. A skill that fires on every task adds noise, not value.

Each skill's `description` field should include negative triggers alongside positive ones:
- "Use when X. Do NOT use when Y."
- Example: `debug` — "Use when fixing bugs. Do NOT use when the task is greenfield implementation with no existing behavior to debug."

When a role is deciding whether to invoke an assigned skill, it should check: "Does this task match the skill's positive trigger AND not match any negative trigger?" If uncertain, skip the skill — false positives (applying an irrelevant skill) are more expensive than false negatives (missing a relevant one).

---

## 15. Team-Mode Execution Policy

**Scope:** This section applies only to roles spawned via `Agent(team_name=..., name=...)` — i.e., team-mode teammates. Subagent spawns via `Agent(subagent_type=...)` without `team_name` are unaffected.

### The crash reality

Claude Code has a reproducible harness bug (`H.toolUseContext.getAppState is not a function` at `cli.js:8231`) that crashes the session when a teammate's Write triggers the team-lead approval prompt. This crash is upstream — it fires after `authority-enforce.sh` returns exit 0, in a second permission layer our plugin cannot reach. Baseline coverage does not prevent it.

Until upstream ships a fix, teammates MUST NOT call Write, Edit, or NotebookEdit tools. **As of v5.9.0, this is mechanically enforced:** `authority-enforce.sh` blocks Write and Edit calls when `CLAUDE_TEAM_NAME` env var is set (team-mode teammate detection). Team-leads (`CLAUDE_TEAM_ROLE=team-lead`) are exempt. Subagent-mode spawns (no `team_name`) are unaffected. If you attempt a Write, you will receive a PreToolUse block with exit 2 citing this section. Use the §15.1 write-proxy envelope protocol instead.

### The workable pattern (canonical)

Teammates that need to persist content (findings artifacts, journal entries, learnings, etc.) MUST:

1. Produce the content in full.
2. Return it via `SendMessage` to the team-lead in a clearly-delimited payload.
3. Include the intended destination path and the required provenance block.
4. Go idle after the message.

The team-lead (coordinator) receives the message and performs the Write on the teammate's behalf, preserving role attribution in the provenance block (`role: <teammate's role>`, not `role: coordinator`).

### Honest residual

Under this policy, team-mode teammates cannot independently update their own playbook memory, journal, or learnings. The consolidation loop depends on role-authored persistent writes; under team-mode, knowledge persistence requires an active coordinator at journal-write time. This is a structural limitation imposed by the upstream crash bug, not a bug in this policy.

Async and background teammate patterns are blocked until either (a) the upstream crash bug is fixed, or (b) a coordinator-mediated write-proxy protocol with handoff-at-stop semantics is designed and shipped. This constraint is flagged as D-0 for the architect — team-mode teammates are epistemically disposable under current Claude Code versions: they do work but cannot leave memory.

### When this policy may be relaxed

Never, under current Claude Code versions. When an upstream fix ships, this section will be revisited and the write restriction lifted.

### 15.1 Durable fallback — write-proxy protocol (v5.5.0)

**Note on teammate addressing:** your coordinator constructs your `name` with a descriptive format like `ainous-team:<role>(<task>)`. When you emit `SendMessage({to: ...})` to peer teammates, you must use their full name verbatim (including special characters) — the mailbox system is exact-match. Your coordinator's name is always `team-lead` regardless.

**When to use:** Any teammate spawned with `background: true`, or when the coordinator session may not be alive when the teammate finishes. Also use when SendMessage delivery to an awake coordinator is not guaranteed.

**How to emit:** Prepend `<!-- WRITE-PROXY-ENVELOPE v1 -->` to your SendMessage message body, followed by YAML frontmatter:

```
<!-- WRITE-PROXY-ENVELOPE v1 -->
---
intended_destination: <absolute path inside project root>
role: <your role>
session: <your spawn session id>
hmac: <sha256 HMAC of envelope body excluding this line, keyed by write_proxy_nonce>
provenance:
  role: <your role>
  session: <your spawn session id>
  source: role-self-report
  discovered: <ISO8601 date>
  verified: null
---
<content body — written verbatim to intended_destination>
```

The `write_proxy_nonce` is resolved at startup via the priority chain below — see **Startup: get your nonce** below.

**Computing the HMAC.** Construct the full envelope text (including the `<!-- WRITE-PROXY-ENVELOPE v1 -->` marker; leave the `hmac:` line either empty or absent), then:

```bash
HMAC=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/compute-envelope-hmac.sh" "$NONCE" <<< "$envelope_text")
```

The helper script wraps `hooks/_hmac_common.py`, which is the same code the write-proxy hook uses for verification — they cannot disagree. Do NOT compute the HMAC manually in your own Python or shell; protocol nuances around nonce encoding (`bytes.fromhex`, not `.encode()`) have historically caused mismatches (C-2 rejections with identical nonce values).

**Startup: get your nonce (team-mode teammates only).** Your coordinator should have injected your write-proxy nonce into your initial prompt as part of the identity header (format: `write-proxy-nonce: <hex>`). **This is your primary source.** Cache the nonce for HMAC computation.

If the identity header does not contain a nonce (coordinator didn't inject one), fall back to reading `~/.claude/teams/{team_name}/nonces/{teammate_name}.nonce` — the file is credential-denied from Bash egress but readable via the Read tool by the owning teammate.

If neither path yields a nonce, do NOT attempt write-proxy envelopes. Fall back to synchronous SendMessage (§15) and inform the coordinator that write-proxy is unavailable. The coordinator will write on your behalf per §15.

**Composition with §15:** Additive. Synchronous SendMessage (§15 canonical flow) remains valid for interactive sessions. The write-proxy envelope is the durability layer for async/background cases.

**Audit trail:** Every successful hook-driven write emits a `hook-write` event to `task-history.jsonl` with fields: `ts`, `schema`, `event`, `source`, `role`, `teammate_name`, `team_name`, `destination`, `bytes_written`, `envelope_hmac`.

