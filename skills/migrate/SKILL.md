---
name: migrate
description: Migration and upgrade methodology. Use when planning schema changes, data migrations, API version upgrades, or any operation that transforms existing production state. Invoke before executing any migration.
---

# Migration Methodology

## Core Principle

Migrations are the most dangerous routine operation. They transform live state that you cannot recreate. Every migration needs a rollback plan written and tested BEFORE you start. If you cannot articulate how to undo it, you are not ready to do it.

## Schema Migration Safety

Never drop a column in the same deploy as the code change that stops using it. The safe sequence:

1. **Deploy code** that handles both old and new schema (reads from new column, falls back to old).
2. **Run the migration** — add the new column, backfill data.
3. **Deploy code** that uses only the new schema.
4. **Later migration** removes the old column, after confirming no code references it.

Collapsing these steps causes downtime: the migration runs while old code still needs the dropped column, or new code deploys before the column exists.

## The Expand-Contract Pattern

Every structural change follows three phases:
- **Expand:** add the new structure alongside the old. Both coexist.
- **Migrate:** move data from old to new. Verify completeness.
- **Contract:** remove the old structure.

Never skip the migrate step. Never contract before verifying the expansion is complete and correct.

## Feature Flags for Risky Migrations

For migrations that change behavior (not just schema): deploy behind a feature flag. Test in production with a small subset of traffic. Monitor error rates. Gradually increase rollout. Keep the kill switch ready — flipping the flag reverts to old behavior instantly, no deploy needed.

## Data Migration Principles

- **Always back up** before migrating. Verify the backup is restorable.
- **Test on production-like data** first. A migration that works on 1,000 rows may timeout on 10 million.
- **Measure migration time** on realistic data volume. If it takes longer than your maintenance window, you need batching.
- **Idempotent migrations** — safe to re-run. Use `INSERT ... ON CONFLICT DO NOTHING` or `WHERE NOT EXISTS` patterns. A migration that fails halfway through and cannot be re-run is a crisis.

## Safe vs Breaking Changes

**Backward-compatible (safe):** adding columns with defaults, adding new tables, adding new endpoints, adding optional fields to APIs, widening a column type (int to bigint).

**Breaking (dangerous):** removing or renaming columns, changing column types to narrower types, removing endpoints, changing response formats, adding NOT NULL without a default, renaming tables.

## Rollback Planning

For every migration step, write the reverse step before executing. The rollback script is not optional documentation — it is a deliverable. Test the rollback on a copy. If a migration step has no feasible rollback (e.g., lossy data transformation), acknowledge that explicitly and plan extra verification before that step.

## Communication

Migrations that affect other teams need advance notice: what is changing, when it happens, who is affected, and what action they need to take. Send this at least one sprint ahead. Post-migration, confirm completion and any follow-up required.

## The No Big Bang Rule

Prefer many small migrations over one large migration. Each small migration is independently testable, independently rollback-able, and independently monitorable. A 10-step migration plan where each step is safe is far less risky than a 1-step migration that does everything at once. If a step fails, you know exactly which step and can address it in isolation.
