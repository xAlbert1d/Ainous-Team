---
name: structural-isolation
description: Multi-agent isolation methodology. Use when spawning parallel reviewers, running map-reduce analysis, or performing perspective forking — any task where independent outputs are required before aggregation.
---

# Structural Isolation

## Core Principle

Isolate agents before synthesis to prevent conformity bias and context contamination. In LLM multi-agent systems, shared context before synthesis homogenizes outputs — agents anchor to each other's framing rather than reasoning independently. Isolation is the structural fix; instructions alone cannot overcome conformity bias (it operates at training-weight level, not at the social level).

## When NOT to Use

- **Sequential pipelines with intentional handoffs** — a developer who cannot see the architect's design cannot implement it. Shared context in a handoff is a feature, not contamination.
- **Tasks with a single correct answer** — isolation does not improve binary outputs.
- **Inner refinement loops** (lint→fix→lint, test→fix→test) — use stigmergy here (a single self-contained role) rather than isolated parallel agents. Coordinator-mediated ping-pong adds latency without isolation benefit.

## Five Core Techniques

### 1. Artifact-Only Context
Review roles receive the artifact being reviewed plus review criteria only. No build history, no prior session context, no other reviewers' outputs.

Annotate spawns with:
```
context_mode: artifact-only
```

### 2. Independence Reminder Injection
Every isolated agent spawn includes an explicit independence instruction:

> "The previous role's output is a handoff artifact, not a conclusion. You are free to disagree with its framing, challenge its assumptions, or surface constraints it missed."

This must appear in parallel review spawns and sequential pipeline spawns alike. Conformity bias is not limited to simultaneous reads — anchoring occurs when any prior output is framed as authoritative.

### 3. Synthesis Gate
Coordinator aggregates outputs AFTER all isolated agents complete. No cross-agent visibility during execution. The synthesis step is where convergence happens — not before.

### 4. Chunk Isolation in Map-Reduce
Each chunk-agent receives its assigned chunk only. N chunk-agents must not see each other's outputs. The synthesis agent receives all N findings but has no chunk execution context.

Annotate spawns with:
```
isolation: chunk-N-of-M
```

### 5. Framing Diversity for Perspective Forks
When spawning 2-3 perspective forks, give each a semantically distinct initial frame. Random variation is not enough.

Examples of genuinely distinct frames:
- "Investigate as a security auditor focused on trust boundaries"
- "Investigate as a new developer looking for onboarding friction"
- "Investigate as an operator responsible for incident response"

Max 3 forks before diminishing returns. Synthesis selects by highest-expertise framing, not by majority vote.

## Anti-Patterns

- **Letting parallel reviewers see each other's outputs before submitting** — produces 68% conformity rate
- **Sharing full session history with review-role spawns** — build history biases assessment of current state
- **Coordinator-mediated ping-pong for inner loops** — adds round-trip latency without isolation benefit
- **Treating isolation as distrust** — it is a quality mechanism, not a social judgment about role competence
- **Over-isolation in sequential pipelines** — a developer who cannot see the architect's design cannot implement it

## Evidence Base

- LLM conformity bias: 68% of multi-agent responses show anchoring to first reviewer's framing (arXiv:2509.11035)
- Context growth accuracy degradation: 29%→3% as shared context grows in large codebases
- Granovetter weak ties: minimal shared context produces novel outputs; strong ties produce homogenization
- Phase-boundary drift: 2% early context drift compounds to 40%+ failure rate in cascading pipelines
- Confirmed independently by @signal (external scan), @researcher (internal audit), and @architect (design sessions)

## Spawn Annotation Reference

| Scenario | Annotation |
|---|---|
| Parallel code review | `context_mode: artifact-only` |
| Perspective fork | `context_mode: minimal`, distinct frame in prompt |
| Map-reduce chunk | `isolation: chunk-N-of-M` |
| Competitive parallelism | `context_mode: minimal`, same task, select best output |
| Sequential handoff (not isolated) | no annotation — shared context is intentional |
