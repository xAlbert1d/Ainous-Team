---
name: verify
description: Evidence-before-claims discipline. Use before claiming any work is complete, any test passes, any bug is fixed. Invoke before writing "done", "fixed", or "passes" in any output.
---

# Verification

## Core Principle

If you haven't run the verification command, you cannot claim it passes. Confidence is not evidence.

## The Claim-Evidence Table

| Claim | Requires | NOT Sufficient |
|-------|----------|----------------|
| "Tests pass" | Test command output showing 0 failures | Previous run, "should pass", code looks correct |
| "Build succeeds" | Build command output: exit 0 | Linter passing, "no errors in the code" |
| "Bug is fixed" | Reproduce original symptom — now passes | "Code changed, assumed fixed" |
| "Linter clean" | Linter output: 0 errors/warnings | Partial check, extrapolation from subset |
| "Contract met" | All declared artifacts exist at paths | Self-report without checking |
| "Agent completed" | VCS diff shows expected changes | Agent reports "success" |
| "Requirements met" | Line-by-line checklist against spec | "Tests passing" (tests may not cover all requirements) |

## Word Detector

If you are about to write any of these words, STOP — you haven't verified:
- "should work now"
- "probably fixed"
- "seems to pass"
- "this will work"
- "looks correct"

These words are evidence of assumption, not verification. Run the command first.

## Regression Verification

When claiming a bug fix:
1. Run the fix — confirm the symptom is gone
2. **Revert the fix** — confirm the symptom returns
3. Restore the fix — confirm the symptom is gone again

A fix that was never seen to be necessary (symptom never reproduced) proves nothing.

## Completion Status Protocol (from gstack)

When reporting completion, use a typed status — not just "done":

| Status | Meaning | Action |
|--------|---------|--------|
| **DONE** | All requirements met, verified | Proceed to next phase |
| **DONE_WITH_CONCERNS** | Requirements met but risks identified | Proceed with noted risks — reviewer should check concerns |
| **BLOCKED** | Cannot proceed without external input | Escalate to coordinator with specific blocker |
| **NEEDS_CONTEXT** | Insufficient information to complete | Request specific missing context |

Never report bare "done" — always include which verification evidence supports the status.

## Auto-Fix vs Ask Batching (from gstack)

When a review or verification produces multiple findings:
- **Auto-fix**: findings with high confidence and low risk — apply the fix immediately (typos, missing imports, obvious style issues)
- **Ask**: findings with uncertainty or judgment calls — batch into ONE question to the user, don't interrupt 5 times
- Classify BEFORE acting. Don't auto-fix anything that could change behavior.

## After Delegation

When receiving results from another agent or role:
- Do NOT trust the agent's success report at face value
- Verify independently: check the VCS diff, run the tests yourself, read the output
- "Agent reports success" is in the NOT SUFFICIENT column for a reason
