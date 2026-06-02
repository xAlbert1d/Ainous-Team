# Changes — v5.10.0 + v5.11.0

Audit-and-refinement pass on top of v5.9.5. Net: 57 files changed, +2,298 / −1,543.
Full rationale: `docs/PROJECT-ANALYSIS.md`.

## Security (independently adversarially verified)
- **S-1 (HIGH, CLOSED)** — `hooks/spawn-telemetry`: per-spawn nonce path charset-validated +
  `realpath`-contained to `~/.claude/teams`; closes a path-traversal write primitive. Fail-open.
- **S-2 (HIGH, CLOSED — all 4 tiers)** — `hooks/write-proxy`: nonce lookup bound to the matched
  spawn **event's** names, never caller-supplied `tool_input`; `_find_spawn_event` OR→AND matching;
  Tier-1 rejects name/event mismatch. Closes cross-teammate nonce-redirection bypass of the C-2 HMAC gate.
- **Q-12 (wired)** — `hooks/hooks.json`: `WebFetch|WebSearch` added to the authority-enforce
  PreToolUse matcher; the v5.9.3 teammate web-tool block was registered but never invoked.
- **R-nonce-clobber** — documented accepted MEDIUM residual (O_TRUNC overwrite required for
  crash-recovery re-spawn; only a self-defeating DoS for an already-trusted spawner).

## Reliability — mechanical memory enforcement (P0)
- **New `scripts/memory-maintain.py`** — session cap enforcement, learnings dedup/orphan-prune,
  expired-decision rotation, stale-fact flagging, knowledge-index integrity, and trust-level audit
  moved from consolidator prompt instructions to deterministic code; invoked fail-open from
  `SessionEnd` + checked in pre-ship gate. Removes the consolidator single-point-of-failure.
  `--check`/`--dry-run`/`--growth-dir`; extended test suite.
  **Note:** The 30-strategy playbook cap is **reported only** — this script logs a violation and
  returns False for `--check`, but does NOT auto-retire strategies. Retirement requires consolidator
  judgment about which entries have the lowest utility scores. The pre-ship gate will fail if the
  cap is exceeded, prompting the consolidator to act.

## Model fit (version-agnostic)
- consolidator + researcher re-tiered to `opus` via family aliases (no version pinning).
- New `docs/NEWER-MODELS.md` — opt-in enhancements (effort, opusplan, 1M); all optional.
- Governing principle: works on any model/CC version, better on newer; newer-only features are
  opt-in and degrade gracefully.

## Instruction tuning (graceful degradation — no scaffolding removed)
- Context-degradation ladder kept; triggers on explicit signal, not self-estimated fill.
- Spawn verbosity tier-conditional (coaching for haiku/unknown, supporting for sonnet/opus).
- Keyword routing kept as baseline; additive logged semantic-override hatch.
- Journal compaction 5→15 raw entries; absorption-retirement records model version.
- Anti-conformity injection unchanged.

## Cleanup
- Cut 3 off-mission skills (video-script/edit, caption-format).
- Moved team-review/-periodic/-implement skills→commands (skill count 57→54).
- Extracted Flutter pm-client out of the package; removed dead operator `app/` baseline.
- Deleted dead `layer2-effectiveness-audit.sh` + unused `knowledge-index.md` template.
- `confidence-calibration` → `default_skills` (10 roles).
- Consolidated Startup Sequence into a runtime-charter reference.
- Allowlisted version-dependent `CLAUDE_CODE_TEAM_NAME` in the hook env-var gate.

## Tests
- `tests/test-write-proxy.sh` 21/21 (new S-2 regressions); `tests/test-memory-maintain.sh` 16/16 (new).
- No regressions; pre-ship Gate 2 (hook env-vars) + Gate 3 (memory caps) pass.

## Corrections caught during the work
- `migrate-legacy-provenance.sh` was initially flagged dead but is kept — live test dependency.
- The first S-2 fix was incomplete (Tier-3b only); independent testing caught it, all four tiers then fixed.
