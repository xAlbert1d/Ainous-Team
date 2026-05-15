---
name: perf
description: Performance optimization principles. Use when investigating slow code, optimizing hot paths, adding caching, or evaluating performance tradeoffs. Invoke before making any change motivated by speed.
---

# Performance Optimization

## Core Principle

NEVER optimize without measuring first. Intuition about bottlenecks is wrong more often than right. The function you think is slow is usually not the actual bottleneck.

## The Methodology

1. **Measure** — establish a quantified baseline of current performance
2. **Identify** — use profiling to find the actual bottleneck, not the guessed one
3. **Hypothesize** — form a specific prediction: "changing X will improve Y by roughly Z"
4. **Change ONE thing** — isolate the variable so you know what caused the improvement
5. **Measure again** — same conditions, same methodology as the baseline
6. **Compare** — did it actually improve? By how much? Was the tradeoff worth it?

If you skip step 1, you cannot do step 6. Without before-and-after numbers, you are guessing.

## Profile Before Optimizing

Use profiling tools to find actual hotspots. CPU profilers, memory profilers, query analyzers, network watchers — use the right instrument for the right layer. A database query taking 800ms matters more than a loop taking 2ms, even if the loop "looks" inefficient.

## Benchmark Discipline

- Establish a baseline BEFORE changing anything
- Run benchmarks 3+ times minimum; compute mean and variance
- Control for warm-up effects, garbage collection pauses, and background processes
- Use the same data set, same machine state, same conditions across runs
- Record the numbers somewhere persistent — memory is unreliable

## Common Bottleneck Patterns

- **N+1 queries**: fetching a list, then querying each item individually. Batch or join instead.
- **Unnecessary serialization/deserialization**: converting data formats in hot paths when you could pass the original structure.
- **Blocking I/O in async paths**: one synchronous call stalls the entire event loop.
- **Excessive allocation in hot loops**: creating objects per-iteration that could be reused or pre-allocated.
- **Missing indexes**: a full table scan on every request because nobody added an index on the WHERE column.
- **Unbounded data fetching**: loading 100k rows when the UI shows 20. Always paginate.

## The 80/20 Rule

80% of execution time is spent in 20% of the code. Find that 20% first. Optimizing code that runs once at startup while ignoring a function called 10,000 times per request is wasted effort.

## Optimization Anti-Patterns

- **Premature optimization**: optimizing before you have evidence of a problem. Write clear code first, optimize when measurements demand it.
- **Micro-optimization**: shaving nanoseconds off a function when the bottleneck is a 200ms network round-trip. Optimize at the right layer.
- **Complexity for speed**: making code unreadable for a 5% improvement that nobody will notice. Maintainability has a cost too.

## Cache Discipline

Every cache is a tradeoff between freshness and speed. Before adding a cache, define:
- **Invalidation strategy**: how and when does stale data get evicted? If you cannot answer this clearly, do not add the cache.
- **Size bounds**: unbounded caches become memory leaks. Set a max size.
- **TTL**: every cached entry needs a time-to-live. "Cache forever" is a bug waiting to happen.

A cache without an invalidation strategy is a source of bugs that are hard to reproduce and harder to debug.

## When to Stop

When performance meets the actual requirements. Not when it is "as fast as possible" — that goal has no end. Define the target (p99 under 200ms, page load under 2s, batch completes in under 1 hour), hit it, and move on. Over-optimization is time stolen from features your users actually need.
