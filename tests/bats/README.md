# authority-enforce.bats — Test Suite

This suite covers `hooks/authority-enforce.sh` with 21 bats-core test cases: 10 known-bug regressions (C1, C1a, C2, C3, C4, H1, H3, H4, H5, BUG-1) and 11 F1 provenance-validator cases (valid full provenance, missing source field, invalid source_type enum, role mismatch, user-confirmed rejection, user-confirmed diagnostic message, user-confirmed reachability regression, partial provenance, legacy-unverified grandfathering, and a documented v1 laundering gap).

## Prerequisites

- [bats-core](https://github.com/bats-core/bats-core) installed and on `PATH` (`bats --version` should print 1.x or later)
- `python3` on `PATH` (the hook requires it; the test helpers use it to build JSON fixtures)
- Working directory: the project root (`ainous-team/`)

## Run the full suite

```sh
bats tests/bats/authority-enforce.bats
```

## What each section covers

**Section 1 — Bug regressions:** C1/C1a verify that Bash commands containing literal newlines, carriage returns, vertical tabs, form feeds, null bytes, and NEL (U+0085) are all rejected before the allowlist check. C2/C3 verify that a missing or tampered `growth.json` fails closed to Intern trust rather than silently falling through to Junior. C4 confirms that a ~512 KB Write payload passes without argv truncation. H1 is a meta-test that grep-inspects the `agents-instructions/` directory to confirm the security ↔ coordinator Escalates-To cycle that existed pre-fix is absent. H3 verifies that a Layer-2 spawn event whose timestamp predates the session anchor is rejected. H4 confirms UTF-8 content under `LC_ALL=C` does not produce an unhandled Python traceback. H5 covers bare-date spawn timestamps and far-future timestamps, both of which must be rejected. BUG-1 verifies that the Layer-3 trailing-slash directory pattern `src/` correctly matches files inside `src/` while rejecting a file whose basename is literally `src`.

**Section 2 — F1 provenance cases:** Tests F1-1 through F1-5c cover the full provenance validator: a valid write passes; missing required fields, invalid enum values, and role mismatches each produce exit 2 with a diagnostic message. F1-5/F1-5b/F1-5c cover the retired `user-confirmed` source type — it is now rejected by the enum (the source was never emitted; user-level signal flows via `user-corrections.md`). `legacy-unverified` is accepted as a grandfathered enum value. F1-6 tests partial provenance. Test F1-8 is a deliberate known-gap documentation test — it demonstrates that promotion-step laundering (a `@consolidator` write with valid provenance over poisoned content) passes the v1 lightweight check; the test is labeled `[KNOWN-GAP v1]` and is expected to pass under current code.

## Isolation guarantee

Every test runs under `BATS_TEST_TMPDIR`, an isolated directory that bats-core creates fresh per test and removes after teardown. No test writes to `~/.claude/`, `.claude/`, or any other real project path.

## Historical baseline

`tests/test-provenance.sh` is preserved as the bash precursor to this suite. It covers TC1–TC12 including migration-script tests (TC10–TC12) that are not duplicated here. Run it independently with `bash tests/test-provenance.sh`.
