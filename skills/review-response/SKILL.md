---
name: review-response
description: How to evaluate and respond to code review feedback. Use when receiving review comments, PR feedback, or quality findings from another role. Invoke before implementing any review suggestion.
---

# Responding to Code Review

## Core Principle

Review feedback is suggestions to evaluate, not orders to follow. Verify against codebase reality before implementing.

## Before Implementing Any Suggestion

For each review item, verify:
1. **Technically correct for THIS codebase?** Grep for actual usage patterns.
2. **Breaks existing functionality?** Check callers/consumers of the affected code.
3. **Reason for current implementation?** Read git blame — there may be context the reviewer lacks.
4. **YAGNI check:** If the suggestion adds a feature, grep for actual usage. No callers = don't build it.

## When to Push Back

Push back with technical reasoning when:
- Suggestion breaks existing functionality (show the test/caller that would break)
- Reviewer lacks context you have (cite the specific constraint)
- Violates YAGNI — the suggested feature has no callers
- Technically incorrect for this stack/framework
- Conflicts with prior architectural decisions (cite the decision)

Never push back with: "I disagree" (no reasoning), social comfort ("sure, sounds good" when it's wrong), or authority ("the spec says so" without technical justification).

## Implementation Order

When receiving multiple review items:
1. **Clarify ALL unclear items before implementing ANY.** Items may be related — partial understanding leads to wrong implementation.
2. Blocking issues (breaks, security) first
3. Simple fixes (typos, imports) second
4. Complex fixes (refactoring, logic) last
5. Test each fix individually — verify no regressions between fixes

## Status Protocol

When reporting back after addressing review:
- **DONE** — all items addressed, tests pass
- **DONE_WITH_CONCERNS** — items addressed but I have reservations about X (explain)
- **NEEDS_CONTEXT** — I need more information about items N, M before I can address them
- **BLOCKED** — I cannot address item N because of constraint X
