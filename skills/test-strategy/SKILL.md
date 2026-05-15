---
name: test-strategy
description: Deciding which types of tests to use where — unit, integration, e2e, load, contract, chaos. Broader than TDD (which is a write-test-first methodology). Use when designing a testing approach for a project or feature.
---

# Test Strategy

## Core Principle

Test the behavior, not the implementation. Tests that break when you refactor (without changing behavior) are liabilities, not assets.

## The Testing Pyramid

```
        /  E2E  \        ← Few, slow, expensive, high confidence
       / Integration \    ← Some, medium speed, medium cost
      /    Unit Tests   \ ← Many, fast, cheap, focused
```

### When to Use Each Level

| Level | Tests What | Speed | When to Use |
|-------|-----------|-------|-------------|
| **Unit** | Single function/module in isolation | ms | Pure logic, calculations, transformations, parsing |
| **Integration** | Components working together | seconds | Database queries, API handlers, service interactions |
| **E2E** | Full user workflow | minutes | Critical user paths, checkout flows, auth flows |
| **Contract** | API shape between services | ms | Microservices, external API dependencies |
| **Load** | Performance under stress | minutes | Before launch, after scaling changes, SLA verification |
| **Chaos** | Resilience to failures | varies | Production systems with redundancy claims |

### The Testing Diamond (alternative for API-heavy systems)

```
        /  E2E (few)  \
       / Integration    \    ← MOST tests here
      /   (many, fast)   \
     /  Unit (some, fast)  \
```

When business logic lives in API interactions (not pure functions), integration tests give more confidence per test than unit tests.

## Decision Matrix

| Question | Answer → Test Type |
|----------|--------------------|
| Does this function have no side effects? | Unit test |
| Does this involve a database? | Integration test |
| Does this involve multiple services? | Contract + integration |
| Is this a critical user journey? | E2E test |
| Does this have performance SLAs? | Load test |
| Does this claim to handle failures gracefully? | Chaos/fault injection |
| Is this a utility/helper function? | Unit test (or skip if trivial) |
| Is this UI rendering? | Snapshot or visual regression |

## Coverage vs Confidence

Coverage % is a proxy, not a goal:
- **80% coverage with well-chosen tests** > **100% coverage with trivial tests**
- The goal is: "if I refactor this code, will the tests catch regressions?"
- Measure: what % of BUGS would your test suite catch? That's real coverage.

### What to test first (highest ROI)
1. Code that handles money, auth, or user data
2. Code with complex conditional logic
3. Code that has broken before (regression tests)
4. Code at system boundaries (API endpoints, database queries)
5. Code that multiple teams depend on

### What NOT to test
- Trivial getters/setters with no logic
- Framework boilerplate (the framework is already tested)
- One-off scripts that won't be maintained
- Tests that just assert the implementation (mock everything, test nothing)

## When to Use

- Starting a new project — design the test strategy before writing code
- Adding a new feature — decide which test levels apply
- After an incident — add the missing test type that would have caught it
- Test suite review — is the pyramid balanced or inverted?

## Anti-Patterns

- **Inverted pyramid**: 500 E2E tests, 10 unit tests. Slow, flaky, expensive. Flip it.
- **Mock everything**: mocking every dependency means you're testing your mocks, not your code. Use real dependencies where feasible.
- **Test the implementation**: `expect(mockDb.query).toHaveBeenCalledWith("SELECT...")` — breaks on any refactor. Test the behavior: `expect(result).toEqual(expectedUser)`.
- **No integration tests**: 100% unit test coverage but the database query is wrong. Unit tests can't catch integration bugs.
- **Flaky tests ignored**: a flaky test is worse than no test — it teaches the team to ignore failures. Fix or delete.
