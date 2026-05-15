---
name: refactor
description: Refactoring methodology and discipline. Use when improving code structure, reducing complexity, or cleaning up before adding features to tangled code.
---

# Refactoring

## Core Principle

Refactoring improves structure WITHOUT changing behavior. If tests break, you changed behavior -- stop and revert. A refactoring that breaks tests is not a refactoring, it is a rewrite.

## When to Refactor

- **After tests are green.** Never refactor red code -- fix first, then improve.
- **Before adding features to tangled code.** Make the change easy, then make the easy change.
- **When you see clear smells.** If you have to re-read a function three times to understand it, that is the signal.
- **NOT speculatively.** Code that works, is tested, and nobody needs to change is not a refactoring target.

## Knowledge vs Code Abstraction

Abstract when the same **business concept** is duplicated -- code that would change together for the same business reason. Two handlers that both validate an order share a concept; extract it.

Keep separate when different concepts **look similar**. A user validation and a product validation may share structure but represent independent rules. Merging them creates coupling where none belongs. Coincidental duplication is not real duplication.

Test: "If the business rule for X changes, would I also change Y?" If no, they are separate concepts despite similar code.

## Priority Framework

- **Critical:** Duplicated business logic (same rule in multiple places -- one will drift), excessive nesting >3 levels (flatten with early returns or extraction), god objects (class/module doing 5+ unrelated things)
- **High:** Magic numbers/strings (extract named constants), unclear names (rename to reveal intent), long functions >50 lines (extract coherent blocks)
- **Nice-to-have:** Minor style inconsistencies, slightly verbose but clear code
- **Skip:** Already clean code. Refactoring clean code is polishing, not improving.

## Anti-Patterns

### Speculative Abstraction
Do not extract "just in case." Every abstraction must be demanded by existing code. If only one caller uses it, it is not an abstraction -- it is indirection.

### Extracting for Testability Alone
If the consuming function's tests already cover the behavior, the code does not need its own function. Extraction adds a seam; seams have cost. Extract when the logic has independent meaning, not just for a test target.

### Premature DRY
Three similar lines are better than one premature abstraction. Wait until you see the pattern three times AND the duplication represents the same concept. Two is a coincidence. Three is a pattern.

## Commit Discipline

1. **Commit green tests before starting.** This is your safety checkpoint.
2. **Refactor in small steps.** Each step: one rename, one extraction, one move. Not three at once.
3. **Run tests after each step.** If red, revert the step -- do not debug forward.
4. **Separate refactor commits from feature commits.** Reviewers need to verify refactors preserve behavior. Mixing with features makes that impossible.

## Safety Net

Always have passing tests before starting. If the code has no tests, write characterization tests first -- tests that assert current behavior, right or wrong. Then refactor with confidence. Running the full suite after each change is not optional; it is the mechanism that makes refactoring safe.
