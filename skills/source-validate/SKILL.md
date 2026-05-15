---
name: source-validate
description: Validates credibility and reliability of information sources. Use when processing external signals, evaluating technology claims, or assessing research findings.
---

# Source Validation

## Core Principle

The credibility of a conclusion is bounded by the credibility of its weakest source. Validate before citing.

## Five Checks

### 1. Authority — Who published this?
- Official documentation / primary source → high trust
- Established tech blog with named authors → medium trust
- Anonymous blog post / social media → low trust — verify independently
- AI-generated content → zero trust without verification
- Check: does the author have domain expertise? Relevant credentials?

### 2. Recency — When was this published?
- API docs / changelogs: must be current version
- Blog posts: >12 months old → verify claims against current state
- Research papers: findings may be superseded
- Social media: recency is its only advantage — content may be unverified

### 3. Corroboration — Is this confirmed elsewhere?
- Single source → low confidence (even if authoritative)
- 2 independent sources → medium confidence
- 3+ independent sources → high confidence
- Same claim appearing in 5 blogs that all cite the same original → still single source

### 4. Bias — What's the incentive?
- Vendor docs about their own product → factual but selectively positive
- Comparison articles by one vendor → structurally biased
- Independent benchmarks → more trustworthy but check methodology
- Social media hype → engagement incentive, not truth incentive

### 5. Specificity — Are claims verifiable?
- "X is faster" → unverifiable. Faster than what? By how much? Under what conditions?
- "X processes 10K requests/sec on c5.xlarge" → verifiable
- Vague claims are a red flag even from authoritative sources

## Confidence Scoring

| Score | Criteria |
|-------|----------|
| **High** | Official source + current + corroborated + specific |
| **Medium** | Authoritative source + recent + plausible |
| **Low** | Single source OR old OR no corroboration |
| **Unverified** | Social media / AI-generated / anonymous / no evidence |

## Anti-Patterns

- **Source worship**: assuming everything from a prestigious source is correct. Even official docs have errors.
- **Recency bias**: assuming newer = more accurate. Sometimes the older, battle-tested approach is better documented.
- **Corroboration theater**: 10 articles that all copy the same original claim ≠ 10 independent sources
- **Ignoring negative evidence**: 9 positive reviews and 1 detailed failure report — the failure report is often more informative
