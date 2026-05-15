---
name: design
description: Architecture and design principles. Use when designing features, planning implementations, or producing design artifacts for handoff. Invoke when the task requires structural decisions.
---

# Design Principles

## Core Principle

Design documents must be executable by someone with zero shared context. If a step says "add appropriate error handling" instead of showing the actual code, the design has failed.

## Before Designing

### Scope Assessment
Before detailed design, assess scope: does this request describe ONE system or MULTIPLE independent subsystems? If multiple, flag immediately — decompose before designing. Don't spend time refining details of a project that needs to be split.

### Context Gathering
- Map the file structure BEFORE defining tasks. Which files will be created or modified, and what is each one responsible for? This is where decomposition decisions get locked in.
- Read existing patterns in the codebase. Follow established conventions — don't propose novel patterns when the codebase already has a working approach.

## Design Process

1. **Propose 2-3 approaches** with explicit tradeoff comparison. Always recommend one.
2. **Scale detail to complexity** — a few sentences if straightforward, up to 300 words if nuanced. Proportional detail, not uniform detail.
3. **Break into bite-sized tasks** — each task is one action (2-5 minutes). "Implement the authentication system" is not a task. "Write the failing test for login validation" is.
4. **Design for isolation** — each unit has one clear purpose, communicates through well-defined interfaces, can be understood and tested independently.

## The No-Placeholder Rule

These are design failures — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without showing actual test code)
- "Similar to Task N" (repeat the content — the reader may not have context)
- Steps that describe what to do without showing how

Every step must contain the actual content needed to execute it.

## Self-Review Checklist

Before delivering a design artifact, verify:
1. **Spec coverage:** Can you point to a task for each requirement? List any gaps.
2. **Placeholder scan:** Search for TBD, TODO, "appropriate", "similar to" — fix them.
3. **Type consistency:** Do names/signatures used in later tasks match earlier definitions? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.
4. **Scope check:** Does the design do only what was asked? Flag any scope creep.

## Diagrams Force Completeness (from gstack)

When designing a system, draw it before describing it. Sequence diagrams, state diagrams, component diagrams, data-flow diagrams — each type forces different hidden assumptions into the open.

- **Sequence diagram**: reveals who calls whom and in what order — exposes missing error handling and race conditions
- **State diagram**: reveals all possible states — exposes unreachable states and missing transitions
- **Component diagram**: reveals boundaries and interfaces — exposes coupling and missing abstractions
- **Data-flow diagram**: reveals what data goes where — exposes security boundaries and data ownership

Use the `diagram` skill to generate Mermaid syntax. The diagram IS a verification artifact — if you can't draw it clearly, the design isn't clear enough.

When modifying code with nearby ASCII/Mermaid diagrams, **update the diagram in the same commit**. Stale diagrams are worse than no diagrams.

## Premise Validation (from gstack)

Before designing the solution, validate the problem:
- **Premise Challenge**: Is the problem correctly framed? Are we solving the right thing?
- **Leverage Check**: Does existing code already solve sub-problems? Grep before designing.
- If either check fails, stop and reframe before investing in design details.

## Parallel Variant Exploration (from gstack)

When a design choice has multiple viable directions, don't iterate on one — explore several in parallel:

1. **Generate 3-5 variants** simultaneously, each taking a different approach
2. **Compare side by side** — use a structured comparison (invoke `competitive-intel` skill if needed)
3. **Identify what works** in each variant — often the best design combines elements from multiple variants
4. **Taste memory**: track which design choices the user/team consistently prefers across rounds. After 2-3 rounds, bias toward their demonstrated preferences rather than asking again.

This is faster than sequential iteration because you explore the solution space in one pass instead of ping-ponging between options.

When NOT to use: when constraints are tight enough that only one approach is viable. Parallel exploration is for genuine forks, not artificial choice.

## Working in Existing Codebases

Where existing code has problems that affect the work, include targeted improvements as part of the design. Don't propose unrelated refactoring. The way a good developer improves code they're working in — not a separate cleanup project.
