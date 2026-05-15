---
name: tdd
description: Test-driven development principles. Use when implementing features or fixing bugs where tests exist or should exist. Invoke when you're about to write code that should be tested.
---

# Test-Driven Development

## Core Principle

Tests-first answer "what should this do?" Tests-after answer "what does this do?"
Tests-after are biased by your implementation — you verify what you built, not what was required.

## The Cycle

1. **Write a failing test** for the next behavior you need
2. **Run it — watch it fail.** If it passes immediately, you're testing existing behavior. Fix the test.
3. **Write the minimum code** to make the test pass. No more.
4. **Run all tests.** If anything else broke, fix before continuing.
5. **Refactor** if needed, keeping tests green.

If you wrote code before the test: stop, delete the code, write the test first. The implementation biases your test design.

## Mock Hygiene

Before adding any mock, answer three questions:
1. **Am I testing mock behavior or real behavior?** If your assertion is on a mock's return value, you're testing the mock.
2. **What side effects does the real method have?** If the test depends on those side effects, mock at a lower level (the actual slow/external operation), not the high-level method.
3. **Is my mock data complete?** Mock the COMPLETE data structure as it exists in reality. Partial mocks pass unit tests but fail integration because downstream code depends on fields you omitted.

## Five Anti-Patterns

### 1. Testing mock behavior instead of real behavior
Gate question: "Am I asserting on a mock element or on real component behavior?"

### 2. Test-only methods in production classes
Methods like `destroy()` that only exist for test cleanup belong in test utilities, not on the production class.

### 3. Mocking without understanding dependencies
Before mocking, trace the dependency chain. Mock the leaf (network call, filesystem), not the branch (service layer).

### 4. Incomplete mock data structures
If the real object has 8 fields and your mock has 3, you've hidden 5 assumptions. Mock the full shape.

### 5. Integration tests as afterthought
Integration tests verify that units work together. Write them alongside unit tests, not after.

## Signals

- **Test passes immediately** → you're testing existing behavior, not new behavior
- **Hard to test** → the design is unclear. Test difficulty is a design signal, not a testing problem.
- **Test errors vs test failures** → errors (import, syntax) mean your test setup is wrong. Failures (assertion) mean the behavior is wrong. Fix errors first.

## Regression Test Verification

When writing a regression test for a bug fix:
1. Write the test → run it → it should pass (fix is in place)
2. **Revert the fix** → run test → it MUST FAIL
3. Restore the fix → run test → passes again

A regression test that has never been seen to fail proves nothing.
