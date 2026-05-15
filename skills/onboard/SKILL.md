---
name: onboard
description: How to ramp up on a new codebase, project, or team. Systematic codebase archaeology, finding entry points, understanding conventions. Use when joining a project, starting a new engagement, or helping someone get oriented.
---

# Onboarding

## Core Principle

Don't read the whole codebase. Find the entry points, trace the flows, build a mental model. You should be productive in hours, not weeks.

## Five Steps

### Step 1: Understand the Shape (15 minutes)
Before reading any code:
- `git log --oneline -20` — what's been worked on recently?
- `ls` the top-level directories — what's the project structure?
- Read README.md — what does this project do?
- Read CLAUDE.md / CONTRIBUTING.md — what are the conventions?
- `git shortlog -sn --since="3 months ago"` — who are the active contributors?

You should now know: what the project does, how it's structured, what's active, and who to ask.

### Step 2: Find the Entry Points (30 minutes)
Every project has 2-3 entry points where execution starts:
- **Web app**: routes file, main app config, middleware stack
- **API**: endpoint definitions, request handlers
- **CLI**: main command, argument parsing
- **Library**: exported public API, index file
- **Worker**: job definitions, queue consumers

Read the entry points. Don't go deep — just map the first level of calls.

### Step 3: Trace One Flow End-to-End (1 hour)
Pick the most important user action (login, create record, process payment — whatever the project's core is) and trace it from entry point to database and back:
- Request comes in → where does it go?
- What middleware/interceptors does it pass through?
- Which service/module handles the business logic?
- What database queries does it run?
- What response does it return?

After tracing one flow, you understand the architecture patterns. Other flows follow the same patterns.

### Step 4: Understand the Conventions (30 minutes)
Read 3 recent PRs or commits:
- How are files named and organized?
- What test patterns are used?
- What's the error handling style?
- What's the commit message format?
- What tools are used (linter, formatter, CI)?

Don't invent new conventions — follow existing ones.

### Step 5: Make a Small Change (1 hour)
The fastest way to learn a codebase is to change it:
- Pick a small, well-defined task (fix a typo, add a log line, update a comment)
- Follow the full workflow: branch, change, test, PR
- This forces you through the development process and reveals hidden requirements (CI checks, review process, deploy steps)

## What to Document for Others

After onboarding, write what you wish you'd known:
- Where the entry points are
- The one flow you traced (as a sequence diagram)
- Non-obvious conventions you discovered
- Things that confused you (they'll confuse the next person too)

## When to Use

- Joining a new project or team
- Starting work on an unfamiliar area of a large codebase
- Helping a new team member ramp up
- After a project has been dormant and you need to re-orient
- Evaluating a codebase for acquisition, integration, or migration

## Anti-Patterns

- **Reading everything**: you'll forget most of it. Trace flows instead.
- **Starting with tests**: tests are verification, not documentation. Start with entry points.
- **Ignoring the README**: it exists for a reason. Read it first.
- **Big first change**: your first PR should be small enough to merge same-day. Build trust before making big changes.
- **Not asking questions**: "I should figure this out myself" wastes time. Ask the active contributors.
