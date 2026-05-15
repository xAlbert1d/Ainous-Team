---
name: summarize
description: Condenses complex content into actionable summaries. Use for journal compaction, compiled truth synthesis, research distillation, and any long-form-to-short-form transformation.
---

# Long-Form Summary Compression

## Core Principle

If removing a sentence doesn't change the reader's next action, cut it.

## Four Phases

### Phase 1: Identify Key Claims
- Read the full source before summarizing anything
- Mark every claim that is: actionable, surprising, or load-bearing (other claims depend on it)
- Ignore: repetition, hedging, background the audience already knows, examples that illustrate an already-clear point

### Phase 2: Extract Supporting Evidence
- For each key claim, find its strongest supporting evidence
- Keep ONE piece of evidence per claim (the most compelling)
- If a claim has no evidence, flag it as unsupported — don't summarize unsupported claims as fact

### Phase 3: Remove Redundancy
- Group claims by topic — merge duplicates
- If two claims say the same thing differently, keep the clearer one
- Convert relative references to absolute: "yesterday" → "2026-04-13", "the bug we discussed" → "the race condition in auth.ts"

### Phase 4: Structure for Scanning
- Lead with the most important insight (inverted pyramid)
- Use bullet points for parallel items
- Use bold for key terms on first appearance
- Target: 20% of original length or less

## Compression Levels

| Level | Ratio | Use When |
|-------|-------|----------|
| **Executive** | 5-10% | Status updates, compiled truth sections |
| **Working** | 15-25% | Journal compaction, research summaries |
| **Detailed** | 30-50% | Architecture overviews, onboarding docs |

## Anti-Patterns

- **Summarizing summaries**: each compression pass loses nuance. Go back to the source.
- **Context stripping**: removing qualifiers that change meaning — "works for small datasets" becomes "works"
- **Uniform compression**: treating all sections equally. Important sections get more space.
- **Opinion laundering**: presenting "the author argues X" as "X is true"
- **Over-compression**: a summary that raises more questions than it answers
