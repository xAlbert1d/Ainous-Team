---
name: prioritize
description: Frameworks for ranking competing opportunities — RICE, ICE, MoSCoW, and weighted scoring. Use when triaging backlogs, planning roadmaps, or deciding what to work on next.
---

# Prioritization

## Core Principle

Without a framework, prioritization defaults to "loudest voice wins" or "most recent request wins." Neither correlates with actual value.

## Three Frameworks

### RICE (best for product features)

Score each item on four dimensions, then compute:

**Score = (Reach × Impact × Confidence) / Effort**

| Dimension | How to Estimate |
|-----------|----------------|
| **Reach** | How many users/sessions affected per time period? Use real data, not feelings. |
| **Impact** | How much does each affected user benefit? Scale: 3=massive, 2=high, 1=medium, 0.5=low, 0.25=minimal |
| **Confidence** | How sure are you about Reach and Impact estimates? 100%=data-backed, 80%=informed guess, 50%=speculation |
| **Effort** | Person-weeks (or AI-adjusted: divide by the compression factor from premise-check) |

Rank by RICE score. Ties broken by Confidence (prefer higher certainty).

### ICE (best for quick triage)

Simpler than RICE — score 1-10 on three dimensions:

**Score = Impact × Confidence × Ease**

| Dimension | 1 (low) | 5 (medium) | 10 (high) |
|-----------|---------|------------|-----------|
| **Impact** | Negligible | Noticeable | Transformative |
| **Confidence** | Wild guess | Informed estimate | Data-backed |
| **Ease** | Months of work | Weeks | Hours/days |

Use ICE when you need to rank 20+ items in 15 minutes. Less precise than RICE but much faster.

### MoSCoW (best for scope decisions)

Classify each item into one bucket:

| Bucket | Meaning | Rule |
|--------|---------|------|
| **Must** | Cannot ship without this | If missing, the release is broken or useless |
| **Should** | Important but not blocking | Ship without it if needed, but plan to add soon |
| **Could** | Nice to have | Only if time permits after Must and Should |
| **Won't** | Not this release | Explicitly out of scope (prevents scope creep) |

Rules:
- **Must** items should be <50% of total scope. If everything is Must, nothing is.
- **Won't** is the most valuable bucket — it makes scope decisions explicit.
- Revisit classification when scope changes — a Should can become a Must if requirements shift.

## Weighted Scoring (custom frameworks)

When RICE/ICE/MoSCoW don't fit, build a custom scoring matrix:
1. Define 4-6 dimensions that matter for YOUR context
2. Weight each dimension (must sum to 100%)
3. Score each item 1-10 on each dimension
4. Compute weighted sum
5. Rank

Example for a security team:
| Dimension | Weight |
|-----------|--------|
| Severity | 30% |
| Exploitability | 25% |
| User exposure | 20% |
| Fix complexity | 15% |
| Regulatory risk | 10% |

## When to Use

- Sprint/iteration planning — what to work on this week
- Roadmap reviews — what to build this quarter
- Bug triage — which bugs to fix first
- Feature requests — which requests to prioritize
- Technical debt — which debt to pay down
- Any context with more work than capacity

## Anti-Patterns

- **Everything is P0**: if everything is urgent, nothing is. Force-rank.
- **HIPPO prioritization**: Highest-Paid Person's Opinion drives the roadmap. Use data.
- **Ignoring effort**: a high-impact item that takes 6 months may be lower priority than a medium-impact item that takes 1 day
- **Static priority**: priorities set 3 months ago and never revisited. Reprioritize when context changes.
- **Prioritizing without saying no**: adding items to the top without removing anything from the bottom. Total capacity is finite.
