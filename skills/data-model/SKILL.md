---
name: data-model
description: Schema design, normalization, denormalization tradeoffs, indexing strategy, and data lifecycle. Use when designing databases, planning migrations, or evaluating data architecture decisions.
---

# Data Modeling

## Core Principle

The schema is the most expensive thing to change later. Get the model right — the code can always be refactored, but migrating a million rows is painful.

## Design Process

### Step 1: Identify Entities and Relationships
- List every noun in the requirements — these are candidate entities
- For each pair of entities: is there a relationship? What kind?
  - **1:1** — rare. Often means they should be the same table.
  - **1:N** — common. Foreign key on the "many" side.
  - **M:N** — needs a junction table.
- Draw the ER diagram (use the `diagram` skill for Mermaid syntax)

### Step 2: Normalize (start here)
Normalize to 3NF as the default:
- **1NF**: no repeating groups, atomic values. One value per cell.
- **2NF**: no partial dependencies. Every non-key column depends on the whole primary key.
- **3NF**: no transitive dependencies. Non-key columns don't depend on other non-key columns.

Rule: normalize first, denormalize intentionally. Never start denormalized "for performance" without measuring.

### Step 3: Denormalize (only with evidence)
Valid reasons to denormalize:
- **Read performance**: a query joins 5 tables on every page load. Denormalize the hot path.
- **Reporting**: analytical queries need pre-aggregated data. Materialized views or summary tables.
- **Caching**: store computed values to avoid recalculation (but add invalidation logic).

For each denormalization: document WHY, what the source of truth is, and how consistency is maintained.

### Step 4: Index Strategy
- Index columns used in WHERE, JOIN, and ORDER BY clauses
- Composite indexes: leftmost prefix rule — `(a, b, c)` supports queries on `a`, `(a, b)`, and `(a, b, c)` but NOT `(b, c)` alone
- Don't over-index: each index slows writes. Only index what queries actually need.
- Use `EXPLAIN ANALYZE` to verify index usage — an unused index is a write penalty for nothing

### Step 5: Data Lifecycle
- **Retention**: how long is each data type kept? (7 years for financial, 30 days for logs, forever for user accounts?)
- **Archival**: when does data move from hot storage to cold?
- **Deletion**: soft delete (mark as deleted) or hard delete (remove)? Soft delete is safer but increases table size.
- **Compliance**: GDPR right to erasure, data residency requirements

## Common Patterns

| Pattern | Use When | Tradeoff |
|---------|----------|----------|
| **Soft delete** | Need audit trail, undo capability | Table bloat, query complexity (WHERE deleted_at IS NULL) |
| **Event sourcing** | Need full history of changes | Storage cost, replay complexity |
| **CQRS** | Read and write patterns differ significantly | Two models to maintain |
| **Polymorphic associations** | Multiple entity types share a relationship | Harder to enforce FK constraints |
| **JSON columns** | Flexible schema, rare queries on the data | Can't index easily, no type safety |

## When to Use

- Designing a new database schema
- Planning a migration to add/change tables
- Performance investigation involving slow queries
- Data architecture review
- Not just SQL — works for document stores, key-value, graph databases

## Anti-Patterns

- **Premature denormalization**: "We'll need this for performance" without measuring. Normalize first.
- **God table**: one table with 50 columns. Split into entities with clear responsibilities.
- **Missing indexes**: "Queries are slow" → check indexes first. It's the most common cause.
- **Stringly-typed data**: storing structured data (dates, enums, JSON) as strings. Use proper types.
- **No migration plan**: changing the schema without thinking about existing data. Plan the migration before changing the model.
- **Ignoring data lifecycle**: tables that grow forever without archival. Eventually they'll be a problem.
