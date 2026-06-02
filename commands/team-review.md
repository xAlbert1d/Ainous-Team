---
name: team-review
description: Run a full team review pipeline on code or architecture — security, quality, and architecture in parallel.
allowed-tools: [Read, Grep, Glob, Bash, Write, Agent]
---

# Team Review Pipeline

Run a multi-role review using the Ainous Team. This command orchestrates @security, @code-quality, and @architect in parallel for defense-in-depth analysis, with contracts and a verification gate.

**Prerequisites:** Read `agents-instructions/runtime-charter.md` for shared execution semantics.

## Process

1. **Identify the target** — what files, module, or PR to review
2. **Dispatch 3 reviewers in parallel** with execution contracts:

```
@security: scan for vulnerabilities, secrets, OWASP patterns
  Contract: deliver .claude/ainous-roles/team-sync/artifacts/security-findings.md with CRITICAL/HIGH/MEDIUM/LOW severity
  Completion condition: all target files scanned, findings structured

@code-quality: review for bugs, standards, maintainability
  Contract: deliver .claude/ainous-roles/team-sync/artifacts/code-quality-findings.md as must-fix vs nice-to-have
  Completion condition: all target files reviewed, file:line references for each finding

@architect: assess structure, boundaries, design quality
  Contract: deliver .claude/ainous-roles/team-sync/artifacts/architect-assessment.md with specific improvement recommendations
  Completion condition: component boundaries analyzed, trade-offs evaluated
```

3. **Verification gate** — after all reviewers complete:
   - Cross-reference findings: issues flagged by 2+ roles are highest confidence
   - Check for contradictions: if one role approves what another flags, note the conflict
   - If any CRITICAL finding exists, confirm it's actionable (has file:line + fix suggestion)
   - Mechanical check: verify all three artifact files exist at declared paths
   - If any missing → classify as missing-artifact, request delivery

4. **Present findings** grouped by severity: CRITICAL → HIGH → MEDIUM → LOW

## Spawn Template with Contracts

For each reviewer, inject their playbook and contract:

```
Agent(description="@<role>: review <target>", prompt="
  You are <Role>. YOUR PLAYBOOK: [read ~/.claude/ainous-roles/<role>/playbook.md]
  PROJECT CONTEXT: [read .claude/ainous-roles/<role>/journal.md + memory.md]

  TASK: Review <target> from your domain perspective.

  EXECUTION CONTRACT:
  - Required output: structured findings with severity rating and file:line references
  - Completion condition: all files in scope reviewed, each finding has a concrete fix suggestion
  - Permission scope: read-only (no code changes during review)

  BEFORE STARTING: mkdir -p .claude/ainous-roles/<role>
  WHEN FINISHED:
  - Verify your contract (all files reviewed, findings structured)
  - Append session note to .claude/ainous-roles/<role>/journal.md
  - Include: strategies used, self-score, key decisions made during review
")
```

## Output Format

```markdown
## Team Review: <target>

### Cross-Role Agreement (flagged by 2+ roles)
- ...

### Security Findings
- ...

### Code Quality Findings
- ...

### Architecture Findings
- ...

### Contradictions (if any)
- ...

### Verification
- All CRITICAL findings actionable: YES/NO
- Cross-role agreement items: N

### Summary
X findings total: N critical, N high, N medium, N low
```
