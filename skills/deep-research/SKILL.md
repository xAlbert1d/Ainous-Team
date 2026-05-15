---
name: deep-research
description: Synthesizes insights from multiple sources — filters noise, identifies patterns, produces actionable summaries. Use for technology evaluation, paper analysis, codebase archaeology, or market research.
---

# Deep Research Synthesis

## Core Principle

Orient first, dive second. Build a map of what exists before reading anything deeply.

## Five Phases

### Phase 1: Scope
- Define exactly what you're looking for — a question, not a topic
- BAD: "Research React" — too broad, will drown in noise
- GOOD: "What are the trade-offs of React Server Components vs. traditional SSR for our use case?"
- Set boundaries: time period, source types, depth

### Phase 2: Gather
- Collect from multiple source types — don't rely on one channel
- Primary sources first: official docs, papers, source code, changelogs
- Secondary sources second: blog posts, tutorials, conference talks
- Tertiary sources last: social media, forum discussions
- Use the `source-validate` skill on each source

### Phase 3: Filter
- Score each source for relevance to your specific question (0-1)
- Discard anything below 0.6 relevance
- The **3-source rule**: a finding mentioned by 3+ independent sources gets confidence boost
- Watch for the "echo chamber" effect: 10 articles citing the same original ≠ 10 independent findings

### Phase 4: Pattern
- Group findings by theme — what keeps coming up?
- Note contradictions — two sources disagreeing is MORE informative than two agreeing
- Identify gaps — what questions remain unanswered?
- Look for trend signals: is adoption growing or declining? What changed recently?

### Phase 5: Synthesize
- Produce structured output with provenance for every claim
- Lead with the answer to the original question
- Include confidence levels: certain / probable / speculative
- Separate facts from opinions from your own inferences

## Output Format

```markdown
## Research: [Original Question]

### Answer
[Direct answer with confidence level]

### Key Findings
1. [Finding] — [source] — confidence: [level]
2. [Finding] — [source] — confidence: [level]

### Contradictions
- [Source A says X, Source B says Y — analysis of why]

### Gaps
- [What we still don't know]

### Recommendation
[What to do next, given these findings]
```

## Three-Layer Search Framework (from gstack ETHOS)

When evaluating solutions, search in three layers — each layer has different trust rules:

| Layer | Description | Trust Rule |
|-------|-------------|------------|
| **Layer 1: Tried and true** | Established, battle-tested solutions | Don't reinvent. If it exists and works, use it. |
| **Layer 2: New and popular** | Recent, trending approaches | Scrutinize what you find. Popular ≠ correct. |
| **Layer 3: First principles** | Reasoning from fundamentals | Prize above everything. When first-principles reasoning contradicts convention, log the "eureka moment" — name it and explain why convention is wrong. |

The layers are a priority order for search: check Layer 1 first (fastest), Layer 2 next (most noise), Layer 3 last (highest value but highest cost).

## Anti-Patterns

- **Reading everything**: the Orient phase exists to prevent this. Build a focus list first.
- **Summarizing without judgment**: synthesis requires you to evaluate and reconcile sources, not just list them
- **Losing provenance**: every claim must trace back to its source. "It's well known that..." is not a citation.
- **Recency anchoring**: the latest blog post isn't necessarily the best source
- **Skipping Layer 1**: reinventing something that already exists because you didn't search established solutions first
