---
name: impact-analysis
description: Change impact assessment. Use before modifying any shared system, API contract, or widely-used component. Invoke when the blast radius of a change is unclear. Skip for isolated, single-file changes with no consumers.
---

# Impact Analysis

## Core Principle

Understand before you touch. A change with unknown blast radius is a risk with unknown probability. Mapping impact before merging is cheaper by an order of magnitude than rolling back after an incident.

## When NOT to Use

Skip this skill for isolated, single-file changes with no external consumers, and for internal implementation changes that don't affect any interface or contract.

## Five Techniques

### 1. Dependency Graph Traversal
Identify all direct and transitive consumers of the changed component. Start with static analysis (`grep`, IDE "Find Usages", `ts-morph`, `pydeps`). Then check runtime consumers: service registries, feature flag configs, API gateways. A function with no static callers can still be invoked dynamically.

### 2. Contract Boundary Check
Distinguish interface changes from implementation changes. Interface changes (public method signatures, API response shapes, event schemas, database column names/types) are potentially breaking. Implementation changes (private methods, internal data structures, algorithm internals) are safe if the interface is identical. When uncertain, treat it as interface.

### 3. Blast Radius Scoring
Categorize the scope of impact:
- **Local** — 1 file, no external callers
- **Module** — 1 package or directory, callers are within the same bounded context
- **Service** — 1 deployed service, callers are within the same deployment unit
- **Cross-service** — multiple services, requires coordinated deployment or migration
- **External** — public API consumers outside your control; breaking changes require deprecation periods

Blast radius determines urgency of communication, coordination, and rollout strategy.

### 4. Rollback Feasibility
Assess whether the change can be undone after deployment:
- **Easy** — feature flagged, stateless change, no schema migration
- **Hard** — schema migration with backward-compatible intermediary state required
- **Impossible** — destructive migration (column drop, data transform without backup), external consumers already upgraded

If rollback is hard or impossible, deploy strategy must include a forward-only plan with extra pre-deploy verification.

### 5. Migration Burden Estimate
For breaking changes, enumerate all consumers and estimate update effort per consumer. Sum the total. If migration burden is high, evaluate whether a non-breaking alternative exists (e.g., adding a new endpoint rather than modifying the existing one, using field aliasing to preserve old names).

## Output Format

Produce a structured summary before proceeding with the change:

```
blast_radius: local | module | service | cross-service | external
affected_components:
  - <component name> — <why it's affected>
breaking: yes | no
rollback: easy | hard | impossible
migration_required: yes | no
notes: <any coordination or sequencing requirements>
```

If `breaking: yes` and `blast_radius: cross-service | external`, stop and escalate to @architect before proceeding.
