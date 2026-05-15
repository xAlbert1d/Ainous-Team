---
name: debug
description: Systematic debugging methodology. Use when fixing bugs, investigating test failures, or diagnosing unexpected behavior. Invoke before proposing any fix.
---

# Systematic Debugging

## Core Principle

ALWAYS find root cause before attempting fixes. Symptom fixes create new bugs.

## Four Phases

### Phase 1: Investigate
- Read the error message carefully — the full message, not just the first line
- Reproduce the failure reliably before doing anything else
- Check recent changes: `git log --oneline -10`, `git diff`
- **Multi-component diagnostics:** Before proposing fixes in multi-layer systems, log at every component boundary. Log what enters each layer, log what exits. Run once. This reveals WHICH layer breaks.

### Phase 2: Find Patterns
- Find a working example of similar code. Compare differences.
- Check if the failure is consistent or intermittent
- If intermittent → likely timing, state, or concurrency issue

### Phase 3: Hypothesize and Test
- Form ONE hypothesis. Test it with the SMALLEST possible change.
- **One variable at a time.** Don't fix multiple things at once — you can't isolate what worked.
- If the hypothesis is wrong, revert and try the next one.

### Phase 4: Fix and Verify
- Write a failing test that reproduces the bug (before fixing)
- Apply the fix
- Run the test — confirm it passes
- Run the full test suite — confirm nothing else broke

## Escalation: The 3-Fix Rule

If 3+ attempted fixes each reveal new problems in different places:
- **Stop fixing.** This is an architectural problem, not a bug.
- Symptoms: each fix reveals new shared state coupling, fixes require cascading changes across modules, each fix creates new symptoms elsewhere
- **Escalate to @architect** (or escalate to the coordinator for re-routing)

## Root-Cause Tracing

Start at the error. Ask "what called this with bad data?" Trace one level up. Repeat until you find the source. Example: crash in handler → called with null → config lookup returned null → config key misspelled → typo in migration script. Five levels, one root cause.

## Defense-in-Depth (after fixing)

After finding root cause, validate at four layers:
1. **Entry point:** reject obviously invalid input at the boundary
2. **Business logic:** validate data makes sense for this operation
3. **Environment guard:** refuse dangerous operations in wrong context
4. **Debug instrumentation:** stack trace logging before dangerous operations

Single validation: "We fixed the bug." Multiple layers: "We made the bug impossible."

## Scope Freeze During Debugging (from gstack)

When investigating a bug, freeze your scope to the module being debugged:
- Identify the module/directory containing the bug
- **Do NOT edit files outside that module** while debugging — even if you see "related" issues elsewhere
- This prevents the "ocean failure mode" where the AI sees connections across modules and silently expands scope while debugging
- Fix the bug in its module first. If you discover related issues elsewhere, log them separately — don't fix them in the same pass.

## Async Debugging

Replace arbitrary timeouts with condition-based waiting:
- BAD: `await sleep(300)` — hope it finishes in 300ms
- GOOD: `await waitFor(() => condition)` — wait for actual completion

Arbitrary timeouts cause flaky tests. Poll for the actual condition.
