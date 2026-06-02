---
name: team-review-periodic
description: Periodic team health review — individual growth, team dynamics, coordinator self-assessment, and action items. Triggered by /team-retro or automatically every 7 days / 10 commits.
allowed-tools: [Read, Grep, Glob, Bash, Write, Agent]
---

# Periodic Team Review

Triggered by `/team-retro` or automatically when 7+ days or 10+ commits since last review.

## Part 1: Individual Growth Reviews (the "1-on-1s")

For each active role (roles with sessions since last review):

1. **Read** the role's growth.json: score trend (improving, flat, declining), session count, trust level
2. **Read** recent journal entries: what tasks, what outcomes, what was learned
3. **Read** strategy annotations: which strategies succeeded/failed in context
4. **Assess:**
   - **Growth trajectory:** Is this role getting better? Score trend over last 5 sessions
   - **Skill utilization:** Is the role using its assigned skills effectively? Any skill never invoked?
   - **Stuck patterns:** Is the role hitting the same failure mode repeatedly?
   - **Trust progress:** Is the role earning trust? Ready for promotion?
5. **Output per role:**
   ```
   ### @<role> — <growth: improving / flat / declining>
   Sessions: N since last review | Avg score: X.X (trend: +/-Y.Y)
   Trust: <level> (N sessions to next promotion)
   Top strategy: <name> [used N times, avg score X.X]
   Growth area: <what this role should focus on>
   Risk: <any concerning patterns, or "none">
   ```

## Part 2: Team Dynamics Review (the "retro")

Analyze cross-role patterns from the review period:

1. **Handoff quality:** Read coordinator retros. Which role pairs have smooth handoffs? Which have friction?
   - Score each active role pair: architect->developer, developer->tester, security->developer, etc.
   - If a pair has 3+ handoffs in the period, assess: "Do outputs from role A consistently match what role B needs?"
   - **Learn handoff patterns:** If a specific handoff format works well, record it as a team-level strategy
2. **Topology effectiveness:** Which topologies were used? Which scored well?
   - If a topology was used 3+ times: compute avg team score
   - If a custom topology outperformed the default: propose it as a named topology
3. **Contract fulfillment rate:** What % of contracts were met on first attempt?
   - Below 70% = team has a quality problem
   - Above 90% = contracts may be too easy (not pushing the team)
4. **Cross-role learning gaps:** Did 2+ roles independently discover the same thing? If so, it should be in team-knowledge.md

## Part 3: Coordinator Self-Assessment (the "manager review")

The coordinator evaluates itself on 4 dimensions:

1. **Routing accuracy:** Did tasks go to the right roles? Any mis-routes this period?
2. **Team utilization:** Were roles under-used or over-worked? Any role with 0 sessions?
3. **Growth facilitation:** Did the team collectively improve? Average score trend across all active roles
4. **Skill assignment:** Were the right skills assigned? Any evidence that a different skill set would have helped?

Scoring (1-10):
- 9-10: Team improving, routing accurate, handoffs smooth, all roles growing
- 7-8: Mostly good, 1-2 areas to improve
- 5-6: Significant issues in routing or team dynamics
- 1-4: Major problems — team is regressing or dysfunctional

## Part 4: Action Items

Produce exactly 3 action items for the next period:
1. One **team-level** action (handoff improvement, topology change, team-knowledge gap)
2. One **role-level** action (specific role needs a new strategy, skill, or trust promotion)
3. One **coordinator-level** action (routing change, skill assignment adjustment, process improvement)

## Output: Team Review Report

Write to `.claude/ainous-roles/coordinator/reviews.md`:

```
## Review: <date range>
**Period:** <start> to <end> | Commits: N | Sessions: N

### Individual Growth
<per-role summaries from Part 1>

### Team Dynamics
**Handoff quality:** <assessment>
**Best pair:** <role-A> -> <role-B> (N smooth handoffs)
**Friction pair:** <role-X> -> <role-Y> (reason)
**Contract fulfillment:** N% first-attempt
**Topology scores:** <topology>: X.X avg (N uses)

### Coordinator Self-Assessment
**Routing:** X/10 | **Utilization:** X/10 | **Growth:** X/10 | **Skills:** X/10
**Overall:** X/10

### Action Items
1. [team] <action>
2. [role] <action>
3. [coordinator] <action>

### Learned Handoff Patterns
<any new handoff patterns discovered this period>

### Proposed Changes
<topology changes, skill mapping changes, trust promotions>
```
