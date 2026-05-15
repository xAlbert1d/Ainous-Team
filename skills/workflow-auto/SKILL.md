---
name: workflow-auto
description: Task decomposition and workflow automation. Use when breaking complex goals into step-by-step executable workflows, mapping actions to tools, and optimizing execution order.
---

# Workflow Automation

## Core Principle

Every workflow is a DAG (Directed Acyclic Graph). Identify nodes (tasks), edges (dependencies), and parallelize everything that can run independently.

## Three Phases

### Phase 1: Decompose
- Break the goal into atomic tasks — each task has ONE clear output
- Identify dependencies: which tasks need outputs from other tasks?
- Classify each task: mechanical (deterministic, scriptable) vs. judgment (requires LLM reasoning)
- **Mechanical tasks should be automated.** Don't use LLM judgment for things that can be a script.

### Phase 2: Optimize
- Build the dependency graph — identify the critical path (longest sequential chain)
- Maximize parallelism: tasks without shared dependencies run simultaneously
- Identify bottlenecks: if one task blocks 5 others, prioritize it
- Set budget constraints: time limits, token limits, retry counts per task
- **The deterministic collector pattern**: mechanical fetch first, LLM judgment second

### Phase 3: Execute and Monitor
- Run tasks in dependency order
- Verify outputs at each gate before proceeding
- If a task fails: diagnose (don't retry blindly), fix, then retry (max 3)
- Log execution trace: what ran, what succeeded, what failed, how long

## Workflow Patterns

### Linear Pipeline
`A → B → C → D` — when each step needs the previous output.

### Fan-Out/Fan-In
`A → [B, C, D] → E` — A produces input, B/C/D process in parallel, E synthesizes.

### Conditional Branch
`A → if X then B else C → D` — decision points route to different paths.

### Iterative Loop
`A → B → check → (pass: C) or (fail: A)` — retry with feedback until quality gate passes.

## Anti-Patterns

- **Premature serialization**: running tasks sequentially when they could parallelize
- **Missing gates**: no verification between phases — errors cascade
- **Retry without diagnosis**: re-running the same failing task without understanding why
- **Over-decomposition**: 50 micro-tasks when 5 clear tasks would suffice
- **Invisible dependencies**: tasks that implicitly depend on shared state (files, environment variables) without declaring it
