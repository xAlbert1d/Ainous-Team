---
name: retro-metrics
description: Quantified retrospective with shipping metrics, health trends, and growth tracking. Use for periodic team reviews, sprint retrospectives, or any reflection that should be data-driven rather than feelings-driven.
---

# Quantified Retrospective

## Core Principle

"What went well / what didn't" without data is just opinion trading. Measure first, then discuss.

## Four Metrics Categories

### 1. Shipping Velocity
Track what actually shipped, not what was planned:
- **Delivery rate**: tasks completed / tasks committed (per period)
- **Shipping streak**: consecutive successful deliveries without rollback or hotfix
- **Cycle time**: from task start to merged — broken into: waiting, active work, review, merge
- **Blocked time**: how long tasks sat waiting for external input

Questions to ask:
- Is delivery rate improving, stable, or declining?
- Where is time being lost? (waiting > active work is a process problem, not a skill problem)
- What broke the shipping streak? Was it preventable?

### 2. Quality Health
Track quality trends over time, not just current snapshot:
- **Test coverage trajectory**: is coverage going up, stable, or eroding?
- **Bug escape rate**: bugs found in production / total bugs found (lower = better)
- **Review turnaround**: time from PR opened to merged
- **Regression frequency**: how often do old bugs return?

Questions to ask:
- Is coverage trajectory positive? If declining, why?
- Are we catching bugs earlier or later in the pipeline?
- Is review turnaround a bottleneck?

### 3. Growth & Learning
Track skill development and knowledge accumulation:
- **New skills acquired**: per person/role, what capabilities were exercised for the first time?
- **Strategy success rate**: what % of playbook strategies succeeded when applied?
- **Knowledge contributions**: entries added to team-knowledge, learnings logged
- **Stuck patterns**: recurring blockers that indicate a skill gap or process gap

Questions to ask:
- Is each role growing or plateauing?
- Are the same mistakes recurring? (indicates learning isn't sticking)
- Which roles are underutilized? Overloaded?

### 4. Team Dynamics
Track collaboration patterns:
- **Handoff friction**: how many back-and-forth cycles per handoff? (fewer = better)
- **Routing accuracy**: % of coordinator dispatches that completed without re-routing
- **Parallel efficiency**: are independent tasks actually running in parallel, or serialized?
- **Escalation rate**: how often do roles escalate to coordinator or user?

Questions to ask:
- Which role pairs have the most handoff friction?
- Is the coordinator routing accurately or frequently re-routing?
- Are we parallelizing effectively?

## Retrospective Process

### Step 1: Gather Data (10 min)
- Read task-history.jsonl for the period
- Read role journals and learnings.jsonl
- Compute the 4 metric categories
- Present as a dashboard, not a wall of text

### Step 2: Identify Patterns (10 min)
- What improved since last retro?
- What declined since last retro?
- What stayed the same despite efforts to change it? (most important — indicates structural issue)

### Step 3: Root Cause (10 min)
For each declining or stuck metric:
- Is this a skill gap? (training/practice)
- Is this a process gap? (workflow change needed)
- Is this a tool gap? (better tooling needed)
- Is this a scope gap? (trying to do too much)

### Step 4: Action Items (5 min)
- **1 team-level action**: affects everyone (e.g., "add coverage gate to all PRs")
- **1 role-level action**: per role that has a stuck pattern (e.g., "developer: add debug skill to default set")
- **1 coordinator-level action**: routing or orchestration improvement
- Max 3 action items total. More than 3 means nothing gets done.

## When to Use

- Weekly/biweekly sprint retrospectives
- Monthly team health reviews
- Post-project wrap-ups
- After incidents or production issues
- Any context where "how are we doing" should be answered with data

## Anti-Patterns

- **Feelings-only retro**: "I feel like we're doing better" without evidence. Measure.
- **Blame retro**: using metrics to assign blame rather than identify systemic issues
- **Action item overload**: 10 action items from a retro means none will happen. Pick 3 max.
- **Ignoring stable-bad**: metrics that aren't declining but are consistently poor get ignored. They're the most important — something structural prevents improvement.
- **Retrospective without data**: gathering the team to discuss without having computed the metrics first. Do the homework before the meeting.
