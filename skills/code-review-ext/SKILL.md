---
name: code-review-ext
description: Comprehensive multi-pass code review covering architecture, logic, performance, security, and conventions. Use for pull request reviews, pre-merge checks, and code audits. Extends the verify skill with proactive quality analysis.
---

# Extended Code Review

## Core Principle

Review the code that matters. A critical bug in a core function is worth 100 style nits in test files.

## Six-Pass Review

### Pass 1: Architecture (does it fit?)
- Does this change belong in this file/module?
- Does it follow existing patterns or introduce a new one? (new patterns need justification)
- Are dependencies reasonable? (importing a heavy library for one function?)
- Could this change break other parts of the system?

### Pass 2: Logic (is it correct?)
- Trace the happy path — does it produce the right result?
- Trace the error path — does it handle failures gracefully?
- Edge cases: null/undefined inputs, empty collections, boundary values, concurrent access
- State management: is state mutated in unexpected places?

### Pass 3: Performance (any hot paths?)
- Is this code in a hot path (called frequently, large data, user-facing latency)?
- O(n squared) or worse in loops? Unnecessary copies? Missing pagination?
- If NOT a hot path, skip detailed perf analysis — premature optimization is waste

### Pass 4: Security (OWASP top 10)
- User input: sanitized before use? Parameterized queries? No dynamic code execution?
- Auth: proper permission checks? No auth bypass paths?
- Secrets: nothing hardcoded? No sensitive data in logs?
- Dependencies: known vulnerabilities in new deps?

### Pass 5: Style (conventions)
- Naming: consistent with codebase conventions?
- Structure: consistent with surrounding code?
- Comments: only where logic isn't self-evident?
- **Don't nitpick style if there are logic bugs.** Fix important things first.

### Pass 6: Test Coverage (what's missing?)
- Are the new code paths tested?
- Are edge cases covered?
- Are error paths tested?
- Would you trust a refactor of this code with these tests as a safety net?

## Review Output Format

```markdown
### [CRITICAL] file.ts:42 — Race condition in auth check
The token validation and the database lookup are not atomic...
**Suggested fix:** Use a transaction or add a mutex.

### [WARNING] api.ts:15 — Missing input validation
User-supplied `limit` parameter is passed directly to SQL...
**Suggested fix:** Sanitize and clamp: `const limit = Math.min(parseInt(req.query.limit) || 10, 100)`

### [SUGGESTION] utils.ts:88 — Simplify with Array.from
The manual loop could be replaced with...
```

## Severity Levels

| Level | Meaning | Action Required |
|-------|---------|----------------|
| **CRITICAL** | Bug, security issue, data loss risk | Must fix before merge |
| **WARNING** | Performance issue, missing validation, fragile pattern | Should fix before merge |
| **SUGGESTION** | Style, readability, minor improvement | Nice to have |

## Two-Pass Severity Separation (from gstack)

Report findings in two passes to prevent informational noise from drowning real issues:
- **Pass 1 (CRITICAL — blocking)**: SQL/data safety, race conditions, trust boundary violations, shell injection, enum/value completeness, auth bypass
- **Pass 2 (INFORMATIONAL — advisory)**: async/sync mixing, type coercion, prompt issues, completeness gaps, style

Present Pass 1 first. Only present Pass 2 after Pass 1 is resolved.

## Enum Completeness (from gstack)

When a diff introduces a new enum value, case, or variant:
- **Read OUTSIDE the diff** — grep for all files that reference sibling values
- Verify the new value is handled in every switch/match/mapping that handles its siblings
- This is the one category where within-diff review is insufficient — you MUST check the rest of the codebase

## Scope Drift Detection (from gstack)

Compare what was requested against what was changed:
1. Read the task description, PR title, commit messages — this is the **stated intent**
2. Run `git diff` — this is the **actual change**
3. If files are modified that don't relate to the stated intent, flag as **SCOPE DRIFT**
4. Output: CLEAN / DRIFT DETECTED / REQUIREMENTS MISSING

## False Positive Learning

When a finding is confirmed as a false positive by the developer:
- Log it to learnings.jsonl with `type: "pitfall"` and `key: "fp-<pattern>"`
- Future reviews check learnings before reporting — auto-skip known FP patterns for this codebase
- This makes the review process smarter per project over time

## Adversarial Cross-Model Review (from gstack)

For high-stakes changes (auth, payments, data migrations, public APIs), use a second AI model as an adversarial reviewer:

- **Independent review**: the second model reviews the same diff without seeing the first model's analysis
- **Challenge mode**: explicitly prompt the second model to "try to break this code" — find edge cases, race conditions, security holes the author missed
- **Cross-model trust boundary**: the second model should NOT have access to the first model's instructions or context — it reviews the code, not the process

When to use:
- Diffs over 200 lines
- Changes to auth, permissions, or security-sensitive code
- Data migrations affecting production data
- Public API changes that will be hard to reverse

This creates genuine adversarial pressure — a single model reviewing its own work has blind spots. A different model has different blind spots.

## Anti-Patterns

- **Style-first review**: 20 comments about formatting, zero about the logic bug on line 42
- **"Looks good to me"**: without evidence that you actually read and understood the change
- **Reviewing without running**: at minimum, mentally trace execution. Ideally, run the tests.
- **Drive-by nits**: leaving 1-line style comments without understanding the broader change
- **Blocking on preferences**: "I would have done it differently" is not a valid blocking concern unless it causes a real problem
- **Within-diff tunnel vision**: reviewing only the lines that changed without checking how they affect the rest of the codebase (see Enum Completeness above)
