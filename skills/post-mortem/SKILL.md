---
name: post-mortem
description: Structured incident analysis after production failures. Use after outages, data loss, security breaches, or any event that impacted users. Blameless methodology with timeline, root cause, and prevention.
---

# Post-Mortem

## Core Principle

Blameless, not careless. The goal is understanding systems, not punishing people. "Who" is irrelevant — "what allowed this to happen" is everything.

## Five Phases

### Phase 1: Timeline Reconstruction
Before analyzing, establish what actually happened:
- Gather timestamps from logs, alerts, deploys, git history, chat messages
- Build a chronological timeline: event → detection → response → mitigation → resolution
- Note the gaps: when did nobody know something was wrong? Those gaps are as important as the events.
- **Time to detect** (TTD): how long between the incident starting and someone noticing?
- **Time to mitigate** (TTM): how long between detection and user impact ending?

### Phase 2: Root Cause Analysis (5 Whys)
Start at the immediate cause. Ask "why?" five times:
1. "The API returned 500s" → Why?
2. "The database connection pool was exhausted" → Why?
3. "A query was holding connections for 30+ seconds" → Why?
4. "The query lacked an index on a column used in WHERE" → Why?
5. "The migration added the column but not the index" → **Root cause: incomplete migration**

Rules:
- Each "why" must be supported by evidence (logs, code, metrics) — not speculation
- If you reach a human ("Bob forgot to add the index"), go one more level: "What process allowed an incomplete migration to ship?"
- Multiple root causes are normal — incidents usually have 2-3 contributing factors

### Phase 3: Contributing Factors
Beyond the root cause, what made the incident worse?
- **Detection gap**: why wasn't this caught earlier? Missing alerts? Missing tests?
- **Response gap**: was the runbook adequate? Did the right people get paged?
- **Mitigation gap**: could we have mitigated faster? Was rollback possible?
- **Testing gap**: why didn't tests catch this? Missing test type? Wrong environment?

### Phase 4: Action Items
Concrete, assigned, time-bound actions. Three categories:

| Category | Example | Timeline |
|----------|---------|----------|
| **Immediate** | Add the missing index, fix the migration | Done during incident |
| **Short-term** | Add alerting for connection pool exhaustion, add integration test | This sprint |
| **Long-term** | Migration checklist that includes index verification, connection pool monitoring dashboard | This quarter |

Rules:
- Max 5 action items. More means nothing gets done.
- Each item has an owner and a deadline.
- "Be more careful" is not an action item. Systemic changes only.

### Phase 5: Document and Share
Write the post-mortem document:

```markdown
## Incident: [Title] — [Date]
**Severity:** SEV-1/2/3
**Duration:** [start] to [resolved]
**Impact:** [who was affected, how many, what they experienced]

### Timeline
[Chronological events with timestamps]

### Root Cause
[5-whys chain with evidence]

### Contributing Factors
[What made it worse]

### Action Items
| # | Action | Owner | Deadline | Status |
|---|--------|-------|----------|--------|

### Lessons Learned
[What this teaches us about our systems]
```

## When to Use

- After any production incident that impacted users
- After security breaches or data exposure
- After significant data loss (even if recovered)
- After near-misses ("we got lucky this time")
- After any event where the team says "we should make sure this never happens again"
- Not just engineering — works for process failures, communication breakdowns, missed deadlines

## Anti-Patterns

- **Blame-first**: "Bob caused the outage" ends the learning. Ask what the system allowed.
- **Action item overload**: 15 action items guarantees none get done. Pick the 3-5 that prevent recurrence.
- **Skipping near-misses**: incidents that were caught before user impact are the cheapest lessons. Post-mortem them too.
- **Heroism narrative**: "Alice saved us by staying up until 3am" — the real question is why was heroism required? Fix the system.
- **Post-mortem without timeline**: jumping to root cause without establishing what happened leads to solving the wrong problem.
