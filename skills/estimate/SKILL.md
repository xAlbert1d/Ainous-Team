---
name: estimate
description: Effort estimation, complexity assessment, and uncertainty communication. Use when scoping work, planning timelines, or communicating delivery expectations. Covers point estimates, ranges, and risk factors.
---

# Estimation

## Core Principle

An estimate without a confidence interval is a guess pretending to be a fact. Always communicate uncertainty.

## Three Estimation Modes

### Mode 1: T-Shirt Sizing (quickest)
For rough planning — not commitments:

| Size | Meaning | Typical Range |
|------|---------|--------------|
| **XS** | Trivial — one file, obvious change | Minutes to 1 hour |
| **S** | Small — few files, clear approach | 1-4 hours |
| **M** | Medium — multiple files, some unknowns | 1-3 days |
| **L** | Large — cross-cutting, design needed | 1-2 weeks |
| **XL** | Epic — needs decomposition before estimating | 2+ weeks → break down first |

Rule: if it's XL, don't estimate — decompose into smaller items and estimate those.

### Mode 2: Range Estimate (most useful)
Three-point estimate with probability:

| Point | Meaning | How to Estimate |
|-------|---------|----------------|
| **Optimistic** | Everything goes right, no surprises | Best case, ~10% probability |
| **Likely** | Normal amount of friction and discovery | Most probable, ~60% probability |
| **Pessimistic** | Significant unknowns surface, rework needed | Worst reasonable case, ~90% probability |

Communicate as: "Likely 3 days, could be done in 1 if straightforward, up to 7 if we hit unknowns in the auth layer."

### Mode 3: Decomposition Estimate (most accurate)
For anything larger than M:
1. Break into subtasks (each estimable independently)
2. Estimate each subtask using range estimate
3. Sum the likely estimates for total
4. Sum the pessimistic estimates for worst-case
5. The total is always more than you think — add 20% buffer for integration and glue work

## Risk Factors That Blow Up Estimates

| Factor | Multiplier | How to Detect |
|--------|-----------|---------------|
| **Unknown codebase** | 2-3x | First time touching this area |
| **External dependencies** | 1.5-2x | Waiting on APIs, approvals, other teams |
| **Unclear requirements** | 2-4x | "We'll figure it out as we go" |
| **Legacy code** | 1.5-3x | No tests, no docs, original author gone |
| **Concurrent changes** | 1.5x | Other people modifying the same files |
| **New technology** | 2-3x | Team hasn't used this stack before |

If 2+ risk factors apply, use the pessimistic estimate as your likely.

## AI Compression Factor

AI changes estimation for certain task types:

| Task Type | Human Estimate | AI-Adjusted |
|-----------|---------------|-------------|
| Boilerplate | 1 day | ~15 minutes |
| Test writing | 1 day | ~30 minutes |
| Documentation | 4 hours | ~15 minutes |
| Feature implementation | 2 days | ~4-8 hours |
| Architecture decisions | 2 days | 2 days (no compression — still needs judgment) |
| Debugging novel issues | 4 hours | 4 hours (no compression — still needs investigation) |

Apply compression to the task breakdown, not the total. Integration and debugging don't compress.

## When to Use

- Sprint planning — scoping what fits in the iteration
- Project proposals — setting delivery expectations
- Resource allocation — deciding team capacity
- Go/no-go decisions — is this feasible in the timeline?
- Not just engineering — works for content production, research, any time-bounded work

## Anti-Patterns

- **Single-point estimates**: "It'll take 3 days" with no uncertainty range. Always give a range.
- **Anchoring**: the first number mentioned becomes the target. Estimate independently before discussing.
- **Planning fallacy**: consistently underestimating because you imagine the best case. Use pessimistic as your default.
- **Estimate as commitment**: an estimate is a prediction, not a promise. If conditions change, update the estimate.
- **Precision theater**: "This will take 3.5 days" — false precision. Say "3-5 days."
