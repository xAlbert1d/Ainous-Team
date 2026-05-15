# Team as Organism: Design Principles

**Date:** 2026-03-31
**Status:** Active design reference

## Core Insight

The team is not a collection of agents — it is itself an agent at a higher layer of abstraction. Just as biological organisms emerge from cells that each perform one function, the ainous-team emerges from roles that each contribute one capability. The organizing principle is **embed, don't repeat**: each layer wraps the lower layer's capability as a black box.

## Biological Organization Layers

```
Cell        → Role         (individual capability, scoped tools, one metric)
Organ       → Role cluster (researcher+architect = understanding, developer+tester = building)
Organism    → Team         (11 roles, one coherent output via coordinator)
Society     → Team of teams (future: cross-project collaboration)
```

### What this means for the system

Each layer operates on its own abstraction:

- **Role layer**: strategies, tools, baselines, trust scores. A developer knows HOW to write code.
- **Team layer**: routing, composition, topology, spawn mode. The coordinator knows WHEN to invoke which roles and in what order.
- **Cross-project layer** (future): strategy transfer, project similarity matching. The system knows WHICH strategies from past projects apply here.

The coordinator doesn't duplicate the architect's design ability — it routes to it. The consolidator doesn't duplicate the researcher's exploration ability — it distills what was discovered. No repetition, just embedding.

## Dynamic Graph Topology

### Current state: fixed pipeline

```
research → design → implement → test → review → docs
```

This works for greenfield features but is wasteful for many common tasks:

| Task type | Optimal topology | Why |
|-----------|-----------------|-----|
| Simple bugfix | developer → tester | No design phase needed |
| Security-sensitive feature | security → architect → developer → security | Security bookends the work |
| Documentation update | writer | Single role, no pipeline |
| Refactoring | architect → developer → code-quality (loop) | No research, heavy review |
| Investigation | researcher | Single role, no pipeline |
| Prototype | developer → user feedback → architect → developer | Iterative, not linear |

### Goal: learned topology

The coordinator should learn which topologies work for which task shapes. Data sources:
- **Retros**: "this task would have been faster if we'd skipped the architect phase"
- **Contract fulfillment**: if a role consistently delivers empty contracts, it wasn't needed
- **User scores**: which team compositions correlate with high ratings

The coordinator's playbook should evolve topology strategies like:
- `bugfix-topology`: developer → tester (skip research/architect/review)
- `security-first-topology`: security scan → architect → developer → security scan
- `full-pipeline`: the current default, for complex features

## Exploration Force

### The problem

Without exploration, the system converges to a local optimum. If the coordinator always uses the same 3 roles for the same task type, it never discovers that adding a researcher improves outcomes by 20%.

### Biological analogy

Evolution has mutation + selection. The system needs an analogous mechanism:

| Biology | Ainous Team | Mechanism |
|---------|-------------|-----------|
| Mutation | Strategy experiments | Consolidator injects `[experimental]` strategies occasionally |
| Recombination | Topology experiments | Coordinator tries unusual pipeline orders |
| Selection | Score-based retention | High-scoring experiments get reinforced, low-scoring get retired |
| Genetic drift | Random role pairing | Spawn unusual combinations (security + writer) to find novel insights |

### Exploration schedule

Exploration rate should decay with maturity (simulated annealing):

```
New system (sessions 0-20):   High exploration — try everything
Maturing (sessions 20-100):   Moderate — experiment on 20% of tasks
Stable (sessions 100+):       Low — experiment on 5% of tasks, mostly exploit known-good strategies
```

Implementation: the consolidator tracks `system_maturity` (total sessions across all roles) and adjusts the `[experimental]` injection rate.

### Competition runs

For high-stakes tasks, spawn 2-3 agents with the same role but different strategy emphasis. Compare outputs against the execution contract. Winning strategy combination gets reinforced.

Key finding from research: [A-HMAD (ACL 2025)](https://aclanthology.org/2025.acl-long.421/) shows heterogeneous agents significantly outperform homogeneous ones. Don't make identical copies — vary the strategy emphasis.

## Minimal Stable Complexity

### The goal is NOT maximum capability

The goal is the **leanest team configuration** that reliably serves the user's actual work patterns. Like biological homeostasis:

- Unused roles get retired (0 sessions for 20+ consolidation cycles → propose retirement)
- Redundant strategies get merged (two strategies that always co-occur → combine)
- Unstable topologies get abandoned (pipeline that consistently needs 3 verification gate iterations → restructure)
- What remains is a lean, adapted team shaped by real usage

### Anti-patterns to avoid

- **Role bloat**: creating new roles for every task shape instead of improving existing ones
- **Strategy accumulation**: playbooks growing without bound because retirement is too conservative
- **Pipeline rigidity**: always using the full pipeline when simpler topologies would suffice
- **Over-exploration**: spending tokens on experiments when the system is already well-adapted

## Consciousness as Dynamic Graph

The team's "consciousness" at any moment is the active pattern of roles, their connections, and the information flowing between them. This isn't stored anywhere — it emerges from the coordinator's routing decisions, the shared task list, and the mailbox messages between roles.

Properties of this dynamic graph:
- **Nodes**: active role instances (can be multiple instances of the same role)
- **Edges**: information flow (task handoffs, authority requests, security scans)
- **Weights**: trust levels gate edge permissions (intern roles have fewer edges)
- **Topology**: changes per task based on coordinator's learned routing strategies

The retro mechanism is how the system becomes aware of its own graph structure — the coordinator reflecting on "how did we connect?" is meta-cognition at the team layer.

## Implementation Path

These principles are **reference architecture**, not immediate implementation targets. They guide decisions when building new features:

| Principle | Already implemented | Next step |
|-----------|-------------------|-----------|
| Embed, don't repeat | Role specialization, coordinator routing | Detect redundancy in consolidator |
| Dynamic topology | Coordinator plans per-task | Learn topology preferences from retros |
| Exploration force | Agent competitions (designed, not built) | Add `[experimental]` injection to consolidator |
| Minimal stable complexity | Role evolution (designed, not built) | Retirement proposals from consolidator |
| Team as meta-agent | Team-knowledge, retros, user corrections | Team-level growth.json (aggregate metrics) |

## Research References

- [Multi-Agent Memory Architecture](https://arxiv.org/html/2603.10062v1) (2026) — 3-layer hierarchy, coherence protocols
- [Meta-Harness](https://yoonholee.com/meta-harness/) (2026) — Strategy search via propose-evaluate-log
- [MAR: Multi-Agent Reflexion](https://arxiv.org/abs/2512.20845) (2025) — Multi-persona reflection
- [A-HMAD](https://aclanthology.org/2025.acl-long.421/) (ACL 2025) — Heterogeneous agents outperform homogeneous
- [MetaGen Dual-Loop](https://www.emergentmind.com/topics/dual-loop-multi-agent-role-playing-construction) (2026) — Dynamic role generation
- [PAHF](https://arxiv.org/abs/2602.16173) (2026) — Implicit feedback from user corrections
- [Hyperagents](https://arxiv.org/abs/2603.19461) (Meta, 2026) — Self-improvement principle
