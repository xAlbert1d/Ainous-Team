---
name: release-gate
description: Release engineering discipline — scope drift detection, coverage audit, test bootstrap, and documentation sync. Use before shipping any release, creating a PR, or deploying to production.
---

# Release Gate

## Core Principle

Shipping is not "merge and pray." Every release passes through gates that catch what reviews miss.

## Five Gates

### Gate 1: Scope Drift Detection
Compare what was requested against what was changed:
1. Read the stated intent: task description, PR title, commit messages, linked issues
2. Read the actual change: `git diff --stat` + file-by-file review
3. Classify:
   - **CLEAN**: all changed files relate to stated intent
   - **DRIFT DETECTED**: files modified that don't relate to intent. List them.
   - **REQUIREMENTS MISSING**: intent mentions work not reflected in the diff. List gaps.

If DRIFT or MISSING, stop and address before proceeding.

### Gate 2: Test Coverage Audit
Every release produces a coverage report:
- Run the test suite with coverage enabled
- Compare coverage % against previous release
- Flag any **newly added code paths with 0% coverage**
- Flag any **coverage decrease** from previous release

If no test framework exists:
- **Bootstrap one.** Create the infrastructure from scratch — test runner, config, first test file.
- "No tests exist yet" is never an acceptable reason to ship without tests. Create them.

### Gate 3: Security Scan
Quick security check (invoke `security-scan` skill if available):
- No secrets in diff (API keys, tokens, passwords)
- No new dependencies with known vulnerabilities
- No dynamic code execution on user input
- Auth/permission checks on new endpoints

### Gate 4: Documentation Sync
Cross-reference all docs against the diff:
- Read README, ARCHITECTURE, CONTRIBUTING, CHANGELOG, API docs
- For each doc file: does the content still match reality after this change?
- Update any doc that drifted — **in the same PR, not as a follow-up**
- If a new feature was added, add documentation for it

### Gate 5: Final Verification
- All tests pass (not "passed earlier" — run now)
- Build succeeds
- No unresolved review comments
- Changelog updated (if the project maintains one)
- Version bumped (if applicable)

## Auto-Fix vs Ask

When gates find issues, classify before acting:

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Auto-fix** | High confidence, low risk, mechanical | Fix immediately (typos, missing imports, doc formatting) |
| **Ask** | Uncertain, judgment needed, could change behavior | Batch into ONE question to the user. Don't interrupt 5 times. |
| **Block** | Security issue, scope drift, missing requirements | Stop. Report. Don't proceed until resolved. |

## When to Use

- Before every PR creation
- Before every deployment
- Before every release tag
- After a round of review fixes (re-run the gates)
- Not just code — works for documentation releases, config changes, infrastructure updates

## Anti-Patterns

- **Ship without gates**: "Tests passed on my machine" is not a release gate
- **Partial gates**: running tests but skipping coverage audit. Running coverage but skipping doc sync. All gates or none.
- **Gates as ceremony**: running gates but ignoring their output. If a gate flags something, address it.
- **Post-merge gates**: catching problems after merge is 10x more expensive than before. Run gates pre-merge.
- **Documentation as follow-up**: "I'll update docs in a separate PR" — you won't. Do it now.
