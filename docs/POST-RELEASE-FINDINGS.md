# Post-release critical research — findings against v5.11.0

Fresh adversarial pass (security + code-quality + architecture) over the current state, including
scrutiny of the code we just added. Ordered by what should be fixed first.

## 🔴 P0 — regressions / overclaims in code WE just shipped (fix before publishing the PR)

- **M-1 (HIGH, our code, runs automatically): `verify_index_integrity` destroys valid index data.**
  `scripts/memory-maintain.py:565-592`. Two defects, PoC-confirmed (a 3-entry index wiped to its
  header): (1) removes the ENTIRE line if it contains any broken link (drops co-located valid links);
  (2) resolves relative links against `project_root` instead of the index file's own dir, so
  legitimate relative links are judged broken and deleted. Runs unlocked + fail-open from SessionEnd —
  silent data loss, no attacker needed. Fix: link-granular removal; resolve against `index_path.parent`;
  refuse to write an index shrunk by >N% without `--check`.
- **enforce_playbook_cap is a no-op (overclaim).** `memory-maintain.py:221-255` only REPORTS a
  violation; it never retires anything. The changelog implies the 30-strategy cap is now mechanical —
  it isn't. Fix: make it retire lowest-utility mechanically, or relabel honestly in CHANGES + docstring.
- **"WAL + flock" overclaim (M-2, MED).** Only `enforce_session_cap` takes the advisory lock; the other
  five mutators WAL-write unlocked → a concurrent append landing mid read-modify-write is lost. Fix:
  extend the lock to all mutators, or correct the claim.
- **N-1 (must-fix, trap): `_acquire_advisory_lock` annotated `-> bool` but returns `(bool, int)`.**
  `memory-maintain.py:75`. A future `if _acquire_advisory_lock(p):` caller gets a truthy tuple, never
  unpacks the fd → orphaned lock. One-line annotation fix.
- **N-3 (data correctness): dedup/prune silently no-op on an all-malformed JSONL file**, leaving corrupt
  data forever. `memory-maintain.py:280-301`. Fix: detect "lines present but none parsed" → log + return False.

## 🟠 P1 — pre-existing backlog from the first audit, cheap and real (never fixed)

- **Q-5: `hooks/hooks.json:101` write-proxy `"timeout": 3000`.** Units are seconds → 50 minutes. A hung
  write-proxy blocks the session for ~50 min. Fix: `30`. One number.
- **Q-1: `scripts/verify-artifact.sh:166-168` dead `$?` check under `set -e`** → malformed manifests
  silently pass validation. Fix: `if ! manifest=$(_parse_manifest); then _fail ...`.
- **Q-3: `schemas/events/spawn.json` is decorative** — required fields (`timestamp`/`phase`/`detail`/`mode`)
  are never emitted (hook emits `ts`/`spawn_mode`/…), and the only mechanical emitter bypasses the
  validator; `log-event.sh` defaults to `warn`. Validation that never fires. Fix: align schema to the
  emitter (or route the emitter through the validator).
- **Q-7 / N-5: `growth.json` read-modify-write race** in `hooks/session-end` skill-aggregation block
  (no lock) — now compounded because memory-maintain's flock doesn't protect the unlocked block.
  Fix: shared flock helper for all growth.json writers.
- **Q-14: `hooks/session-start:119-141` spawns one `python3` per taint/nonce file** (O(n) startups,
  ~10-20s at scale). Fix: single sweep in one interpreter.
- **R-3b (LOW-MED): `hooks/spawn-telemetry:45` passes untrusted JSON via argv** (write-proxy uses a
  tempfile; this didn't get the same fix) → oversized payload → ARG_MAX → fail-open, lost spawn event.

## 🟠 P1 — the real remaining architectural SPOF (needs a decision)

- **The trust gap.** memory-maintain.py fixed memory *hygiene*, but the security-load-bearing value —
  `trust.level` in `growth.json`, which `authority-enforce.sh:1802-1816` reads as the fail-closed
  authorization input — is STILL set only by consolidator prose AND `growth.json` is NOT a
  provenance-gated surface (`_provenance_common.py:47-62`). So a write that escalates trust carries no
  provenance requirement that every *less* sensitive surface requires. The SPOF moved from "memory
  hygiene (annoying if it fails)" to "the trust value the security gate trusts (privilege escalation if
  wrong)." **Highest-leverage architectural change:** add a `trust-audit` to memory-maintain.py that
  clamps any `trust.level` exceeding what the role's session history justifies (fail-safe down), gate
  the trust subtree in `_provenance_common.py`, and wire a Gate 4 into `pre-ship-gate.sh`. Converts a
  judgment SPOF into a value that can't move without a code-checked audit trail.

## 🟡 P2 — lower-priority

- Archive files (`sessions-archive.jsonl`, `decisions-archive.md`) grow unbounded — caps moved one file
  downstream. Add rotation.
- `model` dual-sourced across `agents/*.md` + `capabilities/*.json` with no reconciliation (in sync
  today, hand-managed). Single-source it + a pre-ship cross-check.
- Refresh the NORMATIVE/ENFORCED appendix (`CLAUDE-DESIGN.md:462-487`) — the 50-session-cap row is now
  stale (it IS mechanical post-5.11).
- ~3,800 lines of instruction boilerplate (cost/maintenance, not correctness).

## What's verified CLEAN
- S-1, S-2 (all 4 tiers), taint propagation, the authority-baseline + env-var-allowlist changes — all
  re-checked adversarially, no new gaps. The crypto path is sound; the new bugs are in the text-rewrite
  and the prose-vs-enforced boundary.
