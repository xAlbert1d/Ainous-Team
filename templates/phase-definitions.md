# Phase Definitions

**You are reading the Template layer.** Templates define structural scaffolding only — phase sequence, entry/exit criteria, required artifacts. They do not encode technique (→ Skills) or identity (→ Roles). Keep phase definitions artifact-gated and topology-agnostic.

Reusable phase building blocks that topologies compose. Each phase defines entry/exit criteria, roles, skills, and artifact contracts. The coordinator reads this file during startup and uses it to drive multi-phase pipelines.

Phases are data, not instructions. The coordinator decides WHICH phases to run (topology selection). This file defines WHAT each phase contains.

---

## phase: research

**Entry criteria:** Task scope is defined by user request
**Exit criteria:** `artifacts/researcher-findings.md` exists with ≥1 structured finding
**Roles:** researcher
**Parallel:** false (typically first phase)
**Default skills:** deep-research, source-validate, verify
**Artifacts produced:** researcher-findings.md
**Artifacts consumed:** (none — first phase)
**Max retries:** 2
**Context instructions:** Explore broadly first, then narrow. Produce structured findings with confidence levels. Check team-knowledge before investigating — skip if the answer is already known.

---

## phase: design

**Entry criteria:** `artifacts/researcher-findings.md` exists OR task scope is clear from user request
**Exit criteria:** `artifacts/architect-design.md` exists with component boundaries and interfaces; `artifacts/designer-spec.md` exists when UX/UI/brand work is in scope
**Roles:** architect (structure/feasibility), designer (UX/UI/brand — conditional on design scope)
**Parallel:** true when both architect and designer are active (separate artifacts, no cross-dependency)
**Default skills:** design, api-design, premise-check, diagram, verify
**Artifacts produced:** architect-design.md, designer-spec.md (when designer is active)
**Artifacts consumed:** researcher-findings.md
**Max retries:** 2
**Context instructions:** Read researcher-findings first. Validate the premise before designing (premise-check). Design for the constraints discovered. Produce concrete interfaces, not abstract descriptions. Include a Mermaid diagram of the architecture. When designer is active: architect owns structural feasibility; designer owns UX/UI/brand — they produce separate artifacts and should not block each other.

---

## phase: implement

**Entry criteria:** `artifacts/architect-design.md` exists OR task is a simple fix (fast-fix topology)
**Exit criteria:** Code changes exist in git diff, referenced tests pass
**Roles:** developer
**Parallel:** false (but may run parallel with test phase in fast-fix)
**Default skills:** tdd, debug, verify, review-response
**Artifacts produced:** (code changes — verified by test pass)
**Artifacts consumed:** architect-design.md, designer-spec.md (when present — developer reads designer-spec for component states, tokens, and interaction rules)
**Max retries:** 3
**Context instructions:** Read architect-design first. If designer-spec.md exists, read it for UI component states, design tokens, and accessibility requirements before implementing any UI layer. Follow the designed interfaces. Write tests alongside code. Apply deviation rules: auto-fix bugs (Rule 1-3), STOP for architectural concerns (Rule 4).

---

## phase: test

**Entry criteria:** Implementation code exists (git diff shows changes)
**Exit criteria:** `artifacts/tester-results.md` exists, test pass/fail status documented
**Roles:** tester
**Parallel:** false (sequential with implement, may loop)
**Default skills:** tdd, test-strategy, verify
**Artifacts produced:** tester-results.md
**Artifacts consumed:** architect-design.md (for expected behavior)
**Max retries:** 3 (loops with implement phase — stall detection applies)
**Context instructions:** Read architect-design for expected behavior. Test boundary conditions and error paths, not just happy path. If tests fail, produce actionable failure descriptions for the developer.

---

## phase: review

**Entry criteria:** Tests pass, implementation complete
**Exit criteria:** All CRITICAL findings resolved; `artifacts/security-findings.md` and `artifacts/code-quality-findings.md` exist
**Roles:** security, code-quality; designer (conditional — when UI/UX changes are in scope, reviews for accessibility and design-spec conformance)
**Parallel:** true (independent parallel review)
**Default skills:** security-scan, threat-model, verify, code-review-ext, refactor
**Artifacts produced:** security-findings.md, code-quality-findings.md
**Artifacts consumed:** (reads code directly via git diff)
**Max retries:** 2 (loops with implement phase for fixes)
**Context instructions:** Independent parallel review. Each reviewer produces its own artifact. Do not coordinate with each other — independent perspectives are more valuable than consensus. Apply two-pass severity separation: CRITICAL first, INFORMATIONAL second. When designer reviews: focus on accessibility conformance, design-spec deviation, and interaction-state completeness — not code quality (that's code-quality's domain).

---

## phase: docs

**Entry criteria:** Review phase passed (or skipped), code is final
**Exit criteria:** Documentation updated — README, CHANGELOG, or relevant docs reflect changes
**Roles:** writer
**Parallel:** false (final phase)
**Default skills:** docs, summarize, verify
**Artifacts produced:** (documentation changes in-tree)
**Artifacts consumed:** architect-design.md (for understanding intent)
**Max retries:** 1
**Context instructions:** Read the git diff and existing docs. Update what changed — same PR, not a follow-up. If a new feature was added, add documentation for it. If no user-facing changes, skip with "Clean — no doc updates needed."

---

## Topology Compositions

Topologies select and compose phases. The coordinator chooses a topology, then executes its phases in order with verification gates between each.

```
full-pipeline:  [research, design, implement, test, review, docs]
fast-fix:       [implement, test]
security-first: [research*, design, implement, review*]
research-only:  [research]
review-only:    [review]
docs-only:      [docs]
signal-scan:    (not phase-based — single role dispatch)
map-reduce:     [research* (N isolated chunk-agents), synthesis]
```

`*` = topology override (see below)

### Topology Overrides

Topologies can override phase defaults for specific contexts:

**security-first:**
- research: roles=[security], skills=[security-scan, threat-model, verify]
- review: roles=[security] (security-only re-review after implementation)

**fast-fix:**
- implement: entry criteria relaxed (no design artifact needed)

---

## topology: map-reduce

**When:** Large systematic analysis (>50 files), codebase-wide security scans, documentation audits, comprehensive code reviews of large PRs, perspective forking, competitive parallelism scenarios.

**Entry criteria:** Task scope can be partitioned into N non-overlapping chunks with a defined synthesis criterion
**Exit criteria:** `artifacts/map-reduce-synthesis.md` exists with aggregated findings from all chunk-agents; all chunk result artifacts present at `artifacts/chunk-<N>-results.md`
**Phases:**
1. **research* (N isolated chunk-agents)** — coordinator partitions scope into N non-overlapping chunks; spawns N parallel research instances, each with isolated chunk scope and no cross-chunk context
2. **synthesis** — single synthesis agent receives all N chunk result artifacts and aggregates findings

**Isolation invariant:** Chunk agents MUST NOT see each other's outputs. Each receives only its chunk + synthesis criteria. This prevents the accuracy degradation (documented: 29%→3% on long contexts) caused by growing shared context.

**Phase overrides:**
- research*: roles=[researcher OR security OR code-quality, depending on task domain], skills=[structural-isolation, verify], `context_mode: minimal`, parallel=true
- synthesis: roles=[researcher OR architect], skills=[summarize, verify], `context_mode: artifact-only`

**Artifacts produced:**
- `artifacts/chunk-<N>-results.md` — one per chunk-agent (produced by research* phase)
- `artifacts/map-reduce-synthesis.md` — aggregated findings (produced by synthesis phase)

**Max retries:** 1 per chunk-agent (failed chunks re-run with narrowed scope before synthesis)

**Skip conditions:**
- Skip design: map-reduce is analysis-only; no implementation design needed
- Skip docs: unless synthesis findings are intended as permanent documentation

See `skills/structural-isolation.md` for chunk boundary design and isolation techniques.

---

### Skip Conditions

Phases can be skipped when conditions are met:
- **Skip research:** task scope is already clear from user prompt (no ambiguity)
- **Skip design:** task is a simple fix within one file (fast-fix topology)
- **Skip docs:** change is internal-only with no user-facing impact
- **Skip review:** change is documentation-only or trivial (typo fix)

The coordinator decides skips during Step 3 (Generate Candidates). Log skipped phases in the routing-decision event.
