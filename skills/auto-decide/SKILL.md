---
name: auto-decide
description: Decision classification framework — separates mechanical decisions (auto-resolve) from taste decisions (need human input). Use when triaging multiple decisions, planning workflows, or reducing decision fatigue.
---

# Auto-Decision Framework

## Core Principle

Most decisions are mechanical — they have a clear best answer given the constraints. Only surface decisions that require human judgment. The goal: minimize interruptions while preserving human control where it matters.

## Decision Classification

Every decision falls into one of three types:

### Type 1: Mechanical (auto-resolve)
Decisions with a clear best answer given known constraints:
- **Style/formatting**: follow existing conventions
- **Naming**: follow established patterns in the codebase
- **Import organization**: alphabetical, grouped by type
- **Error message wording**: follow the project's error style
- **File placement**: follow existing directory structure
- **Test structure**: mirror source structure

Rule: if the codebase already has 5+ examples of how to handle this, follow the pattern. Don't ask.

### Type 2: Taste (surface to human)
Decisions where reasonable people would disagree:
- **Feature scope**: include this edge case or not?
- **UX tradeoffs**: simpler interface vs more control?
- **Architecture choices**: when two approaches have genuinely different tradeoffs
- **Priority conflicts**: when two important things compete for attention
- **Naming of user-facing concepts**: what users will see and remember

Rule: present the options with tradeoffs. Recommend one. Ask once — don't present the same decision twice.

### Type 3: Policy (escalate)
Decisions that set precedent or affect security/compliance:
- **Security tradeoffs**: convenience vs safety
- **Breaking changes**: backward compatibility decisions
- **External commitments**: anything visible to users, partners, or the public
- **Resource allocation**: significant time/cost commitments
- **Access/permission changes**: who can do what

Rule: escalate with full context. Don't auto-resolve. Don't just ask — explain the implications.

## Six Decision Principles

When auto-resolving mechanical decisions, apply these in order:

1. **Existing pattern wins**: if the codebase already does it one way, follow that way
2. **Simpler is better**: between two equivalent approaches, choose the simpler one
3. **Reversibility matters**: prefer reversible decisions over irreversible ones. A reversible wrong choice is cheap; an irreversible wrong choice is expensive.
4. **User-facing > internal**: when two changes compete, prioritize the one users will notice
5. **Data preservation**: never auto-decide to delete data or reduce information. Always escalate data loss decisions.
6. **Security never auto-resolves down**: never auto-decide to reduce security. Auto-increasing security is fine.

## Batching

When multiple decisions arise in one workflow:
- Auto-resolve all Type 1 decisions silently
- Batch all Type 2 decisions into ONE question with options
- Escalate Type 3 decisions individually with full context

Example batch output:
```
Auto-resolved: file placement (follows existing), naming (matches pattern), test structure (mirrors source)

Taste decisions (need your input):
1. Feature X: include retry logic? (Pro: reliability. Con: complexity, 2 more files)
2. Error messages: verbose with stack trace or clean user-facing? (Pro verbose: debugging. Pro clean: UX)

Recommendation: Yes to retry (reliability matters here), clean errors (user-facing endpoint).
```

## When to Use

- Coordinator routing pipeline — classify candidate actions before presenting to user
- Code review — auto-fix mechanical issues, batch style decisions
- Product planning — separate must-decides from preferences
- Incident triage — auto-resolve known patterns, escalate novel failures
- Any workflow with decision fatigue — reduce the number of interruptions

## Anti-Patterns

- **Asking everything**: treating all decisions as Type 2. Most are Type 1 — just follow the pattern.
- **Auto-resolving everything**: treating all decisions as Type 1. Security and scope decisions need human input.
- **Re-asking decided issues**: presenting the same Type 2 decision twice. Once decided, it becomes Type 1 for this context.
- **Decision without options**: "What should we do?" is not a useful escalation. "Option A (tradeoff) or Option B (tradeoff), I recommend A because X" is.
- **Consensus-seeking on mechanical decisions**: asking 5 people whether to use camelCase or snake_case. Check the codebase. Follow the pattern. Done.
