# Architecture Delta — v5.9.5 → v5.12.1

How the ainous-team architecture changed across the audit-and-refinement work. The single biggest
shift is the **enforcement boundary**: from one code-backed surface (with the entire memory/learning
lifecycle hanging on consolidator prose — a single point of failure) to **two** code-backed
subsystems, with prose reserved for decisions that genuinely require judgment.

---

## Enforcement architecture — BEFORE (v5.9.5)

```mermaid
flowchart TB
    subgraph ENF["ENFORCED (code) — the ONLY one"]
        AE["hooks/authority-enforce.sh<br/>path / command gate · fail-closed<br/>READS trust.level as authz input"]
    end

    subgraph NORM["NORMATIVE — consolidator prose &nbsp;&nbsp;★ SINGLE POINT OF FAILURE ★"]
        M["memory caps · learnings dedup · orphan-prune<br/>decision rotation · stale-fact pruning · index integrity<br/>playbook 30-cap retirement"]
        T["trust +2 / −5 progression<br/>strategy promotion / retirement"]
    end

    NORM -->|"sets trust.level (prose only)"| AE
    NORM -.->|"if consolidation never runs:<br/>memory grows unbounded, caps unenforced"| X((rot))

    class AE enf
    class M,T norm
    class X bad
    classDef enf fill:#14532d,stroke:#22c55e,color:#fff
    classDef norm fill:#7f1d1d,stroke:#ef4444,color:#fff
    classDef bad fill:#000,stroke:#ef4444,color:#f87171
```

**Pre-ship gates:** `[1] role-infra  [2] hook-env-vars`
**Open security:** S-1 (spawn-telemetry path traversal) · S-2 (write-proxy nonce redirect) · Q-12 (WebFetch block registered but never invoked)

---

## Enforcement architecture — AFTER (v5.12.1)

```mermaid
flowchart TB
    subgraph SEC["ENFORCED — security gate"]
        AE["hooks/authority-enforce.sh<br/>path / command gate · fail-closed<br/>trust.level READ (now provenance-gated)<br/>S-1 / S-2 nonce bound to spawn event<br/>WebFetch / WebSearch block WIRED"]
    end

    subgraph MEM["ENFORCED — memory-lifecycle gate"]
        MM["scripts/memory-maintain.py<br/>session cap · dedup · orphan-prune<br/>decision rotation · stale-fact FLAG<br/>index integrity (fail-safe)<br/>archive capping<br/>TRUST AUDIT → clamp DOWN"]
    end

    subgraph NORM["NORMATIVE (prose) — only irreducible judgment"]
        J["strategy promotion / RETIREMENT<br/>trust RAISING · poisoned-memory promotion gate<br/>expertise-weighted synthesis"]
    end

    SE["SessionEnd hook"] -->|"fail-open"| MM
    PS["pre-ship gates 3·4·5"] -->|"hard-check"| MM
    MM -->|"clamps trust.level down<br/>to history-justified max"| AE
    J -.->|"proposes (no longer a SPOF —<br/>invariants run without it)"| MM

    class AE,MM enf
    class J norm
    class SE,PS hook
    classDef enf fill:#14532d,stroke:#22c55e,color:#fff
    classDef norm fill:#78350f,stroke:#f59e0b,color:#fff
    classDef hook fill:#1e3a8a,stroke:#3b82f6,color:#fff
```

**Pre-ship gates:** `[1] role-infra  [2] hook-env  [3] mem-cap  [4] trust-audit  [5] model-consistency`
**Security:** S-1 closed · S-2 closed (all 4 tiers) · Q-12 wired · trust.level now provenance-gated

---

## The core shift: NORMATIVE → ENFORCED

This table *is* the architecture diff — what moved from "prose the LLM is asked to follow" to
"code-backed invariant."

| Mechanism | Before | After |
|---|---|---|
| Session / memory caps | prose | **ENFORCED** (`memory-maintain.py`) |
| learnings dedup / orphan-prune | prose | **ENFORCED** |
| Expired-decision rotation | prose | **ENFORCED** |
| Stale-fact flagging | prose | **ENFORCED** (deletion still judgment) |
| Knowledge-index integrity | prose | **ENFORCED** (fail-safe, >30% shrink guard) |
| Archive-file capping | did not exist (unbounded) | **ENFORCED** |
| **Trust clamping (down)** | prose, ungated | **ENFORCED** + provenance-gated |
| Trust raising | prose | prose (intentional — judgment) |
| Strategy promotion / retirement | prose | prose (intentional — judgment) |
| Model-field consistency | hand-managed | **ENFORCED** (Gate 5) |
| Pre-ship gates | 2 | **5** |
| Enforced subsystems | **1** | **2** |

---

## Trust data-flow — the security-relevant change

```mermaid
flowchart LR
    subgraph B["BEFORE"]
        direction LR
        P1["consolidator prose<br/>sets trust.level"] --> G1["growth.json<br/>(not provenance-gated)"] --> R1["authority-enforce.sh<br/>reads as authz input"]
    end
    subgraph A["AFTER"]
        direction LR
        P2["consolidator prose<br/>proposes trust"] --> M2["memory-maintain.py<br/>trust_audit: clamp DOWN<br/>to history-justified"] --> G2["growth.json<br/>(provenance-gated)"] --> R2["authority-enforce.sh<br/>reads as authz input"]
    end
    classDef n fill:#1f2937,stroke:#6b7280,color:#fff
    class P1,G1,R1,P2,M2,G2,R2 n
```

Before, the one value the fail-closed security gate trusts was set purely by prose and writable
without provenance. After, a wrong/escalated value is mechanically clamped down to what the role's own
session history justifies (fail-safe — only lowers, never raises), and the surface is provenance-gated.

---

## Secondary structural deltas

| Dimension | Before | After |
|---|---|---|
| Security: nonce path traversal (S-1) | open | closed (charset + realpath containment) |
| Security: cross-teammate nonce redirect (S-2) | open | closed across all 4 write-proxy tiers |
| Security: teammate WebFetch/Search block (Q-12) | dead code | wired into PreToolUse matcher |
| Skills vault | 57 | 54 (3 off-mission cut) |
| Orchestration docs | mis-filed as skills | moved to `commands/` (correct layer) |
| Dart `pm-client` (1,118 LOC) | shipped in package | extracted out of package |
| Dead scripts / templates | present | removed |
| Instruction Startup Sequence | duplicated across 9 role files | single `runtime-charter` reference |
| Model tiers | sonnet-heavy | consolidator + researcher → opus (aliases) |
| Newer-model features | none | opt-in docs (`effort`, `opusplan`, 1M); version-agnostic |

---

## One-sentence summary

**Before:** one enforced organ (the security gate) reading a trust value that prose set, with the
entire memory/learning lifecycle hanging on a single consolidator prompt nothing guaranteed would run.
**After:** two enforced organs — the security gate *and* a mechanical memory-lifecycle gate that bounds
memory and clamps trust every session end — with prose reduced to the decisions that genuinely require
judgment, and five pre-ship gates verifying it all.
