---
name: team-implement
description: Run a full team implementation pipeline — research, design, code, test, and review for end-to-end feature development.
allowed-tools: [Read, Grep, Glob, Bash, Write, Agent]
---

# Team Implementation Pipeline

Run a multi-role implementation using the Ainous Team. This command orchestrates the full pipeline from research to review, using execution contracts and verification gates.

## Process

**Prerequisites:** Read `agents-instructions/runtime-charter.md` for shared execution semantics.

1. **Understand the task** — read the user's request and project context
2. **Dispatch in phases with contracts and verification gates:**

```
Phase 1 — Research (parallel):
  @researcher: explore the codebase area, find patterns and constraints
    Contract: deliver .claude/ainous-roles/team-sync/artifacts/researcher-findings.md with affected files, patterns, constraints
  @architect: design the approach, propose alternatives
    Contract: deliver .claude/ainous-roles/team-sync/artifacts/architect-design.md with chosen approach, rejected alternatives, file change list

  ── VERIFY GATE 1 ──
  Coordinator reviews FINDINGS.md + DESIGN.md:
  - Mechanical check: test -f .claude/ainous-roles/team-sync/artifacts/researcher-findings.md && test -f .claude/ainous-roles/team-sync/artifacts/architect-design.md
  - If missing → classify as missing-artifact, apply failure taxonomy recovery
  - Does the design account for all constraints found by researcher?
  - Are there conflicts between findings and proposed approach?
  - If issues found → message @architect with researcher findings, request revision

Phase 2 — Implementation (after gate 1):
  @developer: implement the chosen design
    Contract: deliver working code + list of files changed
    Completion condition: code runs without errors
    Note: if design identifies independent modules, spawn multiple @developer
    instances in parallel (one per module, each with its own contract)
  @tester: write tests (parallel with developer if TDD)
    Contract: deliver test files + coverage report

  ── VERIFY GATE 2 ──
  Coordinator checks:
  - Do tests pass? (run test command)
  - Does implementation match DESIGN.md's file change list?
  - If tests fail → message @developer with failure output, request fix
  - Loop developer ↔ tester until tests pass (max 3 iterations)

Phase 3 — Review (after gate 2, parallel):
  @security: scan the implementation
    Contract: deliver .claude/ainous-roles/team-sync/artifacts/security-findings.md with severity ratings
  @code-quality: review the code
    Contract: deliver .claude/ainous-roles/team-sync/artifacts/code-quality-findings.md with must-fix vs nice-to-have

  ── VERIFY GATE 3 ──
  If CRITICAL or HIGH findings:
  - Message @developer with specific findings + fix instructions
  - Re-run affected reviewers after fix
  - Loop until no CRITICAL findings remain

  **Generalized retry:** All verification gates use acceptance-gated retry (see runtime charter §6).
  Any phase can be retried, not just developer↔tester. Max retries per phase:
  - Research/Design: 2
  - Implementation: 3
  - Review: 2
  - Finalize: 1

Phase 4 — Finalize:
  @writer: update docs if needed
    Contract: deliver updated doc files
```

3. **Synthesize** — collect all results, resolve conflicts, present to user

## Spawn Template with Contracts

Use the Agent tool with `subagent_type: "ainous-team:<role>"` to spawn team agents. The agent self-loads its own playbook, project context, and runtime charter. Only provide the task and contract:

```
Agent(
  description: "@<role>: <task summary>",
  subagent_type: "ainous-team:<role>",
  prompt: "
    YOUR TASK: <specific task>

    EXECUTION CONTRACT:
    - Required output: <what you must deliver — specific files or structured findings>
    - Completion condition: <how to know you're done — tests pass, findings listed, etc.>
    - Permission scope: <what you can write — your baseline paths>
    - Budget: <scope limit — e.g. 'only the auth module, not the entire codebase'>

    YOUR AVAILABLE SKILLS: <skill-list from coordinator skill mapping>
  "
)
```

## Key Rules

- **Coordinator never writes code** — always delegate to @developer
- **Parallel where independent** — researcher + architect, security + code-quality
- **Sequential where dependent** — developer waits for architect's design
- **Verify at every gate** — don't proceed to next phase with unresolved issues
- **Loop on failure** — developer ↔ evaluator loop until tests pass (max 3 iterations)
- **Ask user to rate** at the end (1-10)

## Output Format

```markdown
## Implementation Complete: <feature>

### Research Findings
- ...

### Architecture Decision
- Chosen approach: ...
- Rejected alternatives: ...

### Implementation
- Files created/modified: ...
- Tests: X passing, X total

### Review Results
- Security: N findings (X critical, X high, X medium)
- Code Quality: N must-fix, N nice-to-have
- Resolution: [all critical/high findings addressed | N remaining]

### Verification Gates
- Gate 1 (research→design): PASSED
- Gate 2 (implementation→tests): PASSED [N iterations]
- Gate 3 (review→fixes): PASSED

### Rating
Rate this team output (1-10, or skip):
```
