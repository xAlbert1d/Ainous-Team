---
name: competitive-intel
description: Structured comparison analysis of tools, frameworks, or approaches. Use for technology selection, architecture decisions, tool migration evaluation, or market analysis.
---

# Competitive Intelligence

## Core Principle

A good comparison answers: "Given our specific constraints, which option optimizes for what we care about?" Generic comparisons are useless.

## Four Phases

### Phase 1: Define Dimensions
- What matters for THIS decision? Not all dimensions are equal.
- Common dimensions: performance, developer experience, ecosystem, maintenance burden, cost, security, community, documentation
- Weight dimensions: which are dealbreakers vs. nice-to-haves?
- Add a "migration cost" dimension if switching from an existing tool

### Phase 2: Gather Evidence
- Use primary sources: official docs, benchmarks, changelogs, GitHub activity
- For each dimension per option: find concrete evidence, not marketing claims
- Check: when was the last release? How many maintainers? Issue response time?
- Apply `source-validate` skill to each piece of evidence

### Phase 3: Compare
- Build a comparison matrix: options as columns, dimensions as rows
- Score each cell: strong / adequate / weak / unknown
- Don't force a score when data is insufficient — mark as "unknown"
- Highlight where options differ most — similarities don't help decisions

### Phase 4: Recommend
- State your recommendation with confidence level
- Explain which dimensions drove the decision
- Acknowledge trade-offs: "We lose X but gain Y"
- Include: "Reconsider if..." conditions that would change the recommendation

## Output Format

```markdown
## Comparison: [Option A] vs [Option B] vs [Option C]

### Decision Dimensions (weighted)
| Dimension | Weight | Option A | Option B |
|-----------|--------|----------|----------|
| Performance | High | Strong | Adequate |
| Ecosystem | Medium | Adequate | Strong |
| Migration | High | Low cost | High cost |

### Recommendation
[Option A] — because [reason]. Trade-off: [what you give up].
Reconsider if: [condition that changes the answer].
```

## Anti-Patterns

- **Irrelevant dimensions**: comparing on features you'll never use
- **Ignoring ecosystem**: the tool is great but nobody uses it — no Stack Overflow answers, no community plugins
- **Snapshot analysis**: comparing today's state without trends. Is the project growing or declining?
- **Brand bias**: choosing the popular option without evaluating alternatives
- **Missing migration cost**: the best tool isn't worth it if switching takes 6 months
