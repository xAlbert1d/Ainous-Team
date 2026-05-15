---
name: skill-creator
description: Meta-skill for creating new AI skills in .md format. Use when designing, structuring, or improving skills for the vault.
---

# Skill Creator (Meta Skill)

## Core Principle

A skill is a **composable unit of domain expertise**. It contains principles, techniques, and anti-patterns — NOT workflow orchestration. Agents choose when to invoke skills autonomously; skills don't command agents.

## Skill Anatomy

Every skill follows this structure:

```markdown
---
name: <kebab-case-name>
description: <one-line description. Start with action verb. Include when-to-use trigger.>
---

# <Skill Title>

## Core Principle
<One sentence: the single most important thing to remember>

## Phases / Technique
<2-4 phases with concrete steps>

## Anti-Patterns
<What NOT to do — specific, with examples>

## When to Use
<Trigger conditions — be specific>
```

## Quality Criteria

### 1. Actionable, Not Aspirational
- BAD: "Write clean, maintainable code"
- GOOD: "Every function has ONE return type. If you need Optional, the caller should handle None explicitly."

### 2. Anti-Patterns Are Essential
- Every skill MUST have anti-patterns. They prevent more bugs than the positive instructions.
- Anti-patterns should be specific failures you've seen, not generic warnings.

### 3. Trigger Description Matters
- The `description` field determines when the skill gets invoked
- Include specific trigger words: "Use when fixing bugs" not "Use for development"
- Start with an action verb

### 4. Phase Structure
- 2-4 phases maximum. More phases = less likely to be followed.
- Each phase has a clear input and output.
- Gate between phases: "Before proceeding, verify X"

### 5. Composable, Not Comprehensive
- A skill should do ONE thing well
- If your skill covers 5 different domains, split it into 5 skills
- Skills can reference other skills: "invoke the `verify` skill before claiming completion"

## Process

1. **Identify the gap**: What mistake keeps happening? What expertise is missing?
2. **Write the anti-patterns first**: What should the skill prevent?
3. **Extract the technique**: What does an expert do differently?
4. **Structure into phases**: Order the steps, add gates
5. **Write the trigger**: When should this skill activate?
6. **Test mentally**: Would a junior developer following this skill produce expert-level output?

## Anti-Patterns

- **Kitchen sink skill**: covers everything, teaches nothing. Split it.
- **Philosophy skill**: lots of principles, no concrete steps. Add phases with commands/examples.
- **Copy-paste skill**: copied from a blog post without rewriting for the team's context. Absorb and rewrite.
- **Dead skill**: never invoked because the trigger description doesn't match real use cases. Fix the description.
- **Orchestration skill**: tells agents what to do step-by-step (that's the coordinator's job). Skills teach HOW, not WHEN.
