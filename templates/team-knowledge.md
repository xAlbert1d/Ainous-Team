# Team Knowledge

Shared facts discovered by the team. Accessible to all roles. Append-only — the consolidator deduplicates periodically.

## Fact Format

Every factual claim uses this structured format:

```
- **fact**: [The factual claim]
  **source**: @role-name (session N) | user-stated | observed
  **confidence**: low (1 observation) | medium (2-4) | high (5+)
  **discovered**: YYYY-MM-DD
  **verified**: YYYY-MM-DD
```

### Rules

- Every factual claim requires source attribution with type: observed / self-described / inferred
- User corrections override all other sources — write to `user-corrections.md`; consolidator weights 3x
- Confidence tracks observation count: 1 = low, 2-4 = medium, 5+ = high
- Facts must include discovery date and last verification date
- Consolidator updates `verified` date when confirming a fact still holds
- Facts not verified within 30 days are flagged for review during consolidation
- Stale facts that are no longer true get removed (git preserves history)

## Project Facts

<!-- Roles append facts here using the structured format above -->

## Conventions

<!-- Code conventions, naming patterns, architecture decisions -->

## Gotchas

<!-- Non-obvious things that have tripped up roles -->
