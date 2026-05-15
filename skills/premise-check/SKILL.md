---
name: premise-check
description: Strategic premise validation before committing to a solution. Use before any significant implementation, product decision, architecture change, or resource allocation. Challenges whether the problem is correctly framed.
---

# Premise Check

## Core Principle

The most expensive mistake is building the right solution to the wrong problem. Validate the premise before designing the answer.

## Three Checks

### 1. Premise Challenge
Before accepting the problem statement, ask:
- **Is this the real problem, or a symptom?** Trace the causal chain. "Users can't log in" might be a symptom of "auth service is down" which is a symptom of "deployment broke the config."
- **Who specifically has this problem?** Name a real person or concrete persona. "Users" is too vague.
- **What happens if we do nothing?** If the answer is "nothing much," question priority.
- **Are we the right ones to solve this?** Maybe this is a dependency's problem, a process problem, or a user education problem — not a code problem.

### 2. Leverage Check
Before building from scratch, search for existing leverage:
- **Grep the codebase** — does existing code already solve part of this? Reuse before reinventing.
- **Check dependencies** — does a library already do this? Don't implement what you can import.
- **Check team knowledge** — has someone already investigated this? Read the journals.
- **Check the outside world** — is there an established pattern, RFC, or standard for this?

### 3. Scope Decision
Explicitly choose a scope mode before proceeding:

| Mode | When | Behavior |
|------|------|----------|
| **Expand** | Greenfield, exploration, big opportunity | Dream big, explore adjacent possibilities |
| **Selective Expand** | Good foundation, targeted growth | Hold core scope, cherry-pick high-value additions |
| **Hold** | Well-scoped, execution phase | Maximum rigor on defined scope, resist additions |
| **Reduce** | Overscoped, deadline pressure, uncertain value | Strip to essentials, ship the minimum that validates |

Name your scope mode explicitly: "We are in HOLD mode for this task." This prevents unconscious scope creep.

## The Completeness Principle

AI changes the effort calculus. Tasks that were prohibitively expensive for humans are near-free for AI:

| Task Type | AI Speed Multiplier |
|-----------|-------------------|
| Boilerplate | ~100x |
| Tests | ~50x |
| Documentation | ~40x |
| Features | ~30x |
| Architecture decisions | ~1x (still needs human judgment) |

Implication: for tasks in the top rows, **always do 100%**. The delta between 80% test coverage and 100% is trivial for AI. "Good enough" is a human-era constraint. The exception: architecture decisions still require human judgment — AI speed doesn't help if the direction is wrong.

## When to Use

- Before starting any task estimated at >1 hour of work
- When a task description feels vague or assumes a solution
- When someone says "just build X" without explaining the problem X solves
- When the team is about to commit significant resources to a direction
- Product decisions, hiring plans, market strategies — not just code

## Anti-Patterns

- **Solution-first thinking**: "We need a microservice for this" before validating the problem exists
- **Scope creep disguised as thoroughness**: expanding scope without explicitly choosing EXPAND mode
- **Skipping leverage check**: building from scratch because "it's faster" (it almost never is)
- **Premature commitment**: locking into a direction before the premise is validated — especially dangerous because sunk cost bias makes it harder to change later
