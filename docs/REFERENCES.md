# External References & Improvement Opportunities

Domain research (signal sweep → researcher verification) on the newest progress relevant to the
ainous-team plugin, as of **2026-06-02**. Each item is web-verified where possible; confidence and
recency are labelled honestly. These inform *future* improvements — none are implemented yet.

> Method: `@signal` scanned GitHub/arXiv/blogs/official docs for late-2025–2026 developments mapped to
> our components; `@researcher` then verified claims via live web fetch, flagged the unverifiable, and
> mapped each to specific plugin files. Items below are the keepers.

---

## Verified findings

| Claim | Verified? | Confidence | Source (date) |
|---|---|---|---|
| **AutoDream** — Anthropic shipped background memory consolidation for Claude Code (24h-idle + 5-session trigger, 4-phase, 200-line index limit, `/dream`) | WEB-CONFIRMED | HIGH | zenvanriel / claudefa.st / letsdatascience (Mar–May 2026) |
| AutoDream **scans `.claude/ainous-roles/` / `playbook.md`** (could clobber our memory) | **UNVERIFIABLE** | LOW | no public source confirms or denies scope |
| **OWASP Top 10 for Agentic Applications 2026**, incl. **ASI04 Agentic Supply Chain / dynamic composition** | WEB-CONFIRMED | HIGH | genai.owasp.org (Dec 9 2025) |
| ASI04 explicitly prescribes SessionStart hook-checksum | NOT STATED (sound inference) | MEDIUM | OWASP / Microsoft (Mar 2026) |
| **Multi-agent debate**: single-line anti-conformity necessary but insufficient; synthesis must weight argument quality + surface dissent, not detect consensus | WEB-CONFIRMED | HIGH | NeurIPS 2025; Free-MAD (arXiv 2509.11035); MAD-Spear (2507.13038) |
| **NeuroTaint**: taint propagates via semantic influence AND into memory writes, not just verbatim output | WEB-CONFIRMED | HIGH | arXiv 2604.23374 (Apr 2026) |
| **Darwin Gödel Machine**: accept self-modifications on *empirical* improvement, not LLM judgment | WEB-CONFIRMED | HIGH | arXiv 2505.22954 (May 2025) |
| **Tool-output sanitizer** at the tool boundary blocks most injection as a first line | WEB-CONFIRMED | HIGH | CommandSans (2510.08829); 2601.04795; 2510.05244 |
| Claude Code **SubagentStop** `background_tasks`/`session_crons` fields; `reloadSkills` | WEB-CONFIRMED | HIGH | Claude Code release notes (v2.1.145+/152+) |
| Our `authority-enforce.sh` deny messages name the rule/capability (info-leak surface) | OBSERVED in code | HIGH | `hooks/authority-enforce.sh` deny paths |
| Our `learnings.jsonl` `utility` field is defined but never populated | OBSERVED in code | HIGH | plugin source |

---

## Improvement opportunities (prioritized — NOT yet implemented)

### P0 — defensive-now (passive platform behavior or real attack surface)
1. **AutoDream defensive posture.** AutoDream is real and could (scope unconfirmed) prune/restructure
   our memory files via its 200-line index limit. Safe regardless of scope: add protective headers to
   `playbook.md`/`team-knowledge.md`, and a SessionStart checksum/size-baseline of our memory files so
   silent external mutation is at least *detected*. Files: `scripts/memory-maintain.py`, a SessionStart
   hook, the memory files. Effort: S–M.
2. **Hook-script integrity at load (OWASP ASI04).** We HMAC teammate writes but never attest the
   plugin's OWN hooks. If `~/.claude/plugins/cache/ainous-team/` is swapped, `authority-enforce.sh`
   could be replaced with an exit-0 stub and all controls evaporate. Add a SHA-256 manifest verified by
   a SessionStart hook before proceeding. Files: `hooks/session-start`, new `hooks/manifest.sha256`,
   `scripts/pre-ship-gate.sh`. Effort: S–M.
3. **Deny-message info-leak (causality laundering).** `authority-enforce.sh` deny paths print the rule/
   capability that triggered the block — probeable. Emit opaque codes (`AUTHORITY_DENY [Exx]`) to the
   agent; keep detail in a local operator log. Files: `hooks/authority-enforce.sh`. Effort: M.

### P1 — important (next 1–2 cycles)
4. **Semantic-taint corroboration policy.** Our taint model is binary/session-level and does NOT taint
   memory writes. Minimal adoptable rule: the consolidator must not promote a tainted-session entry to
   `verified` until an untainted session corroborates it. Files: `consolidator-instructions.md`,
   `security-instructions.md`. Effort: S (policy).
5. **Utility-score validation gate (DGM / SkillOpt).** Today playbook edits are accepted on LLM
   judgment. Populate the existing `utility` field and only keep strategies whose utility improves over
   the next N sessions (retire the rest). Files: `scripts/memory-maintain.py`, `consolidator-instructions.md`,
   `coordinator-instructions.md`. Effort: M.
6. **Coordinator synthesis: weight argument quality, surface dissent.** Single-line anti-conformity
   injection (which we have) is necessary but insufficient — the *synthesis* step must not treat
   consensus as a correctness signal. Files: `coordinator-instructions.md`. Effort: S.

### P2 — nice-to-have
7. **Tool-output sanitizer** as a PostToolUse hook on WebFetch/WebSearch (first line; taint stays as
   defense-in-depth). Files: new hook + `hooks/hooks.json`. Effort: M.
8. **Adopt new lifecycle fields** — log `background_tasks`/`session_crons` from `SubagentStop`; consider
   `reloadSkills` on SessionStart. Files: `teammate-lifecycle-reaper`, `runtime-charter.md`, `session-start`. Effort: S.

---

## Honesty notes
- **AutoDream scan scope is the key unknown.** No public source confirms whether it touches
  `.claude/ainous-roles/`. The P0-1 recommendation is *detect-not-prevent* precisely because we can't
  verify; do not assume our memory is safe OR doomed without testing on a real post-AutoDream `.claude`.
- Some arXiv IDs in the broader sweep are single-source; only the web-confirmed items are listed here.
- This is a reference base, not a commitment to implement. Validate each against the installed Claude
  Code version before acting (per the plugin's model/version-agnostic principle).

---

## Reference list (the keepers)

**Orchestration / multi-agent**
- Multi-Agent in Production 2026 — https://medium.com/@Micheal-Lanham/multi-agent-in-production-in-2026-what-actually-survived-f86de8bb1cd1 (Apr 2026)
- NeurIPS 2025 MAD Judges — https://neurips.cc/virtual/2025/poster/117644
- Free-MAD (consensus-free debate) — https://arxiv.org/pdf/2509.11035 (Sep 2025)
- MAD-Spear (conformity injection attack) — https://arxiv.org/pdf/2507.13038 (Jul 2025)

**Memory / persistent learning**
- AutoDream guide — https://zenvanriel.com/ai-engineer-blog/claude-code-autodream-memory-consolidation-guide/ (Mar 2026)
- AutoDream mechanics — https://claudefa.st/blog/guide/mechanics/auto-dream (Apr 2026)
- MAGMA multi-graph agentic memory — https://arxiv.org/html/2601.03236v2 (Jan 2026)
- Darwin Gödel Machine — https://arxiv.org/pdf/2505.22954 (May 2025)

**Governance / security**
- OWASP Top 10 for Agentic Applications 2026 — https://genai.owasp.org/2025/12/09/owasp-top-10-for-agentic-applications-the-benchmark-for-agentic-security-in-the-age-of-autonomous-ai/ (Dec 2025)
- NeuroTaint / Ghost in the Agent — https://arxiv.org/abs/2604.23374 (Apr 2026)
- Causality Laundering (denial-feedback leakage) — https://arxiv.org/pdf/2604.04035 (Apr 2026)
- CommandSans (tool-output sanitizer) — https://arxiv.org/pdf/2510.08829 (Oct 2025)
- Indirect Prompt Injection firewalls — https://arxiv.org/html/2510.05244v1 (Oct 2025)

**Claude Code / Anthropic platform**
- Agent SDK overview — https://code.claude.com/docs/en/agent-sdk/overview (Jun 2026)
- Hooks reference — https://code.claude.com/docs/en/hooks
- Release notes — https://releasebot.io/updates/anthropic/claude-code
