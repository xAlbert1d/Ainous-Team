---
name: strategy-evolution
description: Playbook evolution methodology for the consolidator role. Use when adding, modifying, or retiring playbook strategies. Invoke during consolidation cycles.
---

# Strategy Evolution

## Core Principle

If you didn't observe an agent fail without the instruction, you don't know if the instruction helps. Evidence of failure without → justification for adding.

## The Description-Override Trap

Strategy descriptions placed near the top of playbooks can cause agents to shortcut the full strategy body. When an agent reads a description that summarizes the workflow, it may follow the summary instead of reading the detailed content below.

**Rule:** Strategy descriptions should say WHEN to apply (triggering conditions), never HOW to apply (process summary). The "how" lives only in the strategy body.

Bad: `"parallel-investigation: run multiple searches simultaneously and merge results"`
Good: `"parallel-investigation: when facing 3+ independent questions about different areas"`

## Before Adding a Strategy

1. **Find evidence of failure without it.** Search journals for sessions where the behavior was missing and it caused problems. No evidence = no strategy.
2. **Check if the model does this naturally.** For strategies older than 10 sessions, ask: "Would the current model do this without being told?" If yes, the strategy is unnecessary overhead.
3. **Check token budget.** Every strategy competes with conversation context in the hot tier. The 30-strategy cap exists for a reason. If at capacity, something must be retired first.

## Writing Effective Strategies

Use implementation intentions: "When X, do Y" is more effective than "generally do Y."

Structure each strategy as:
- **Name:** descriptive verb phrase
- **Source:** `[from-failure]` or `[from-success]` — failure-derived strategies are better for exploration/research, success-derived are better for implementation/execution
- **When:** specific triggering condition (not "when appropriate")
- **Action:** concrete behavior (not "consider doing")
- **Why:** the failure this prevents or the success this reinforces (links to evidence)

## Retiring Strategies

Before retiring, run counterfactual analysis:
1. Find sessions where the strategy WAS used and scored poorly
2. Find sessions where the strategy was NOT used on similar tasks
3. Compare outcomes — if strategy-absent sessions scored higher, the strategy is harmful
4. If both scored poorly, the root cause is elsewhere — do NOT retire

Log causal reasoning: "Retired: X. Evidence: sessions [dates] scored avg 4.2 with X vs avg 7.8 without X on similar tasks."

## Experiment Design

When injecting `[experimental]` strategies:
- Pick the role with the most sessions (most data to evaluate)
- Propose a variant: combine two existing strategies, invert an assumption, or borrow from another role
- After 3 sessions, compare scores: experiment sessions vs baseline sessions
- Promote or retire based on evidence, not intuition
