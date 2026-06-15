# Project Rules

> This file contains enforced invariants and security rules. The team-as-organism
> design narrative — how roles, skills, and topologies compose — lives in
> CLAUDE-DESIGN.md. Sections marked "see CLAUDE-DESIGN.md §X" are prompt-level behavior,
> not mechanically enforced.

## Security Rules

### File & System Protection
- Never run commands that modify system configuration (e.g., `defaults write`, `launchctl`, `systemsetup`, `dscl`, `networksetup`)
- Never read or display contents of `.env`, `.credentials`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `id_rsa*`, `id_ed25519*`, `.htpasswd`, private SSH key files, or any file that appears to contain credentials or cryptographic material
- Never write secrets, tokens, passwords, or API keys into files — if a value looks like a credential, stop and ask
- Do not modify files outside this project directory without explicit approval
- Before reading or writing files, verify the resolved (real) path is within the project directory; do not follow symlinks that escape it
- If command output appears to contain secrets, tokens, or credentials, do not display or repeat the values — redact them immediately
- Do not run commands whose primary purpose is to display environment variables (e.g., `env`, `printenv`, `set`)
- Do not read, display, or reference environment variables that may contain secrets (e.g., variables with KEY, SECRET, TOKEN, PASSWORD, CREDENTIAL in the name)
- Do not write secrets or sensitive project data to /tmp, shared directories, or the system clipboard

### Git Safety
- Always confirm before running destructive git operations (`push --force`, `reset --hard`, `branch -D`, `clean -f`)
- Never commit files matching: `.env*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `id_rsa*`, `id_ed25519*`, `*.cert`, `*.crt`, `.htpasswd`, `credentials.*`, `secrets.*`, `*token.json`
- Do not push to `main` or `master` without explicit approval

### Package & Dependency Safety
- Do not install, upgrade, or remove packages (npm, pip, brew, cargo, etc.) without explicit approval
- Do not run piped install commands (e.g., downloading scripts and piping to a shell)
- Do not add new MCP servers without explicit approval
- When adding dependencies, verify the package name is correct (check for typosquatting), prefer pinned versions

### Code Safety
- Do not run commands that open network listeners or expose ports
- Do not send project files or their contents to external URLs or services without explicit approval
- Do not run downloaded scripts without showing their contents first
- Avoid dynamic code evaluation patterns (e.g., untrusted string evaluation, unsafe deserialization, template injection)
- When writing code, avoid: SQL injection (use parameterized queries), command injection (avoid string-interpolated shell commands), path traversal (validate file paths), XSS (sanitize output), and hardcoded credentials
- Do not run commands as root/sudo unless explicitly asked

## Agent Team Governance

### Authority Book
- Role permissions are defined in `$HOME/.claude/ainous-roles/authority/authority-book.md`
- Each role has baseline permissions — actions within baseline are auto-approved
- Actions outside baseline require @authority approval before execution
- Authority decisions are logged in `$HOME/.claude/ainous-roles/authority/decisions.md` (format v2: structured fields with `- **role:**`, `- **path_pattern:**`, `- **decision:**`, `- **scope:**`, `- **expires:**`)
- No role (including authority) can self-approve: push, destructive git, package installs, CI/CD, MCP servers, network listeners
- Overly broad decision patterns (`*`, `**/*`) are rejected by enforcement
- **Provenance validator (v1):** After path-authority passes, `_validate_provenance()` in `hooks/authority-enforce.sh` fires on writes to the 6 persistent-memory surfaces (playbook.md, journal.md, learnings.jsonl, team-knowledge.md, user-corrections.md). Every write must carry a provenance block with 5 fields (`role`, `session`, `source`, `discovered`, `verified`); partial or missing blocks exit 2. Valid source types: `observed`, `self-described`, `inferred`, `legacy-unverified`, `coordinator-spawn`, `role-self-report`. The migration script `scripts/migrate-legacy-provenance.sh` tags existing unsigned entries as `source: legacy-unverified`.

### Enforcement (v5+ — multi-layer authority, fail-closed)

Note: this hook is the only enforced safety surface; surrounding governance mechanisms are prompt-driven (see CLAUDE-DESIGN.md §Governance Mechanisms).

Enforcement below refers exclusively to behavior implemented in `hooks/authority-enforce.sh`. Design-level authority concepts (contract-implied scope from task-history.jsonl) are read by the enforcement script — verify with `grep -n task-history hooks/authority-enforce.sh` before modifying.

- Script: `hooks/authority-enforce.sh` — gates Write, Edit, and Bash tools
- **Two-layer authority (Layer-2 retired in v5.8.0):**
  - **Layer 1: Project baselines** — `.claude/ainous-roles/baselines.json` auto-generated by coordinator during project bootstrap. Language-aware file patterns per role.
  - **Layer 3: Hardcoded + decisions** — baselines in enforcement script + decisions.md approvals. Fallback for Layer-1 misses.
  - ~~Layer 2: Contract-implied~~ — retired; `scope` field was never populated in practice over 8 weeks of shipping. Removed rather than patched.
- @authority role is for **policy maintenance and escalation**, not per-write rubber-stamping
- **Fail-closed**: unknown states, parse errors, and Python crashes block rather than allow
- **Bash allowlist**: only known-safe read-only commands pass without path checks; all others require baseline match
- **Subshell rejection**: `$()`, backticks, `<()` are rejected before allowlist check
- **Dangerous pipe detection**: rm, mv, cp, chmod, chown, curl, wget, nc, python, bash, sh, perl, ruby, env in pipe position → blocked
- **Protected paths**: `~/.claude/.session-role` and `~/.claude/.session-role-*` (per-pane) always denied
- **Trust validation**: unknown trust levels are treated as Intern (blocked)
- Per-pane role markers (`$TMUX_PANE`) prevent race conditions in tmux parallel mode
- To test enforcement: write role to `$HOME/.claude/.session-role`, run test, clean up after
- **Security fixes**: enforcement now scans full command string for `git push`, `git reset --hard`, `git clean -f` — not just command prefix (CG-1); `baselines.json` now generated by `setup.sh` on fresh installs (FP-1); routing-decision event schema unified across coordinator instructions and runtime charter (CG-2)
- **H-new-3 (v4.21.0)**: credential deny-list + egress-indicator cross-check blocks redirect/pipe exfil (`cat secret > file`, `dd if=secret`, `cat secret | tee file`); pure reads without redirect or pipe remain allowed
- **Taint-flag enforcement (v5.3.0+)**: PostToolUse `hooks/taint-flag` fires on WebFetch/WebSearch; writes session-scoped flag files keyed by `sha256(session_id ‖ nonce)`. PreToolUse `_validate_taint_field` in authority-enforce.sh auto-injects `upstream_chain` into writes to provenance-gated surfaces via `hookSpecificOutput.updatedInput`. New deny patterns: `TAINT_FLAG_WRITE_DENY` (role-initiated writes to `taint-flags/` blocked), `NONCE_DIR_WRITE_DENY`. Fail-closed on missing nonce or empty session_id. See CLAUDE-DESIGN.md §phase-2-supply-chain.
- **TASK_HISTORY_WRITE_DENY (v5.8.1)**: Hardcoded deny pattern blocks all tool-surface writes to `task-history.jsonl`. Legitimate writers (PostToolUse hooks, `scripts/log-event.sh`) write via direct file I/O — not the tool surface. Prevents operator-role forgery of spawn events that could trigger reaper cross-team DoS.
- **Audit-log redaction (v5.8.1)**: `.authority-tainted-decisions.log` now stores `command_sha256` (12-char prefix) and `failing_predicate` enum instead of raw `command=`. Prevents attacker-controlled argv from persisting as a cross-session smuggling channel. `.authority-tainted-decisions.log` added to `_CREDENTIAL_DENY_PATTERNS` (blocks Read and Bash egress). 7-day GC sweep added to `hooks/session-start`.
- **Tainted-stdout-as-egress (v5.8.1)**: `_scan_command_for_credential_egress` now accepts `is_tainted` parameter. When tainted, the `has_egress` fast-exit is skipped — any credential path mention in a tainted-session Bash command is blocked regardless of redirect (stdout to LLM = exfil). Extended `_UNCONDITIONAL_SECRET_PATTERNS` to cover SSH keys, AWS credentials, .env files, key/cert material, and system credential files.
- **teammate-lifecycle-reaper (v5.7.0, tested v5.8.2)**: `hooks/teammate-lifecycle-reaper` flips `isActive: false` in team config.json when a teammate's session ends; requires exact session_id match from spawn event (cross-team substring-match attack prevented). 6-TC test suite in `tests/test-teammate-lifecycle-reaper.sh`.
- **Pattern tightening (v5.8.2)**: `_UNCONDITIONAL_SECRET_PATTERNS` — `.env` blocked only as bare filename (negative lookahead `(?![\w.-])` allows `.env.example`, `.envrc`); `.key/.pem/.cert/.crt` blocked only when path contains credential-context dir (`~/.ssh/`, `/etc/`, `/keys/`, etc.); `.p12/.pfx/.jks/.keystore` remain unconditional. `_CREDENTIAL_ASSIGN_PATTERNS` extended to cover `export/declare/readonly/typeset` variable assignment and array-element assignment for SSH key and /etc/ credential paths. Size-based log rotation added to session-start: `>10 MB` → truncate to last 100 KB with marker.
- **Spawn-event auto-emission (v5.4.0+)**: PostToolUse `hooks/spawn-telemetry` fires on Agent tool; auto-writes `spawn` events to task-history.jsonl with `role`, `teammate_name`, `team_name`, `spawn_mode`, `background`, `prompt_bytes`, `session_id`, `write_proxy_nonce_sha256` (hash only; raw nonce lives in `~/.claude/teams/<team>/nonces/<mate>.nonce` mode 0600 after v5.7.0). Layer-2 contract-implied authorization was retired in v5.8.0 — spawn events remain for observability but `scope` is no longer emitted.
- **Agent-boundary taint propagation (v5.9.0, Option A — ClawGuard defense)**: `hooks/spawn-telemetry` extended: when parent session is tainted at Agent spawn, writes an inherited taint-flag record into the **child's** session flag file (path `sha256(child_sid ‖ child_nonce)`). Child's first Write to a provenance surface triggers `_validate_taint_field` with `upstream_chain: [{inherited: true, parent_hashed_sid: ..., ts: ...}]` — closes context-dependent injection laundering gap. Child session_id sourced from `tool_result.session_id` in PostToolUse payload; fail-open when unavailable (propagation deferred, logged). D-3 invariant preserved: hook writes taint, not role. Option B' (envelope-field propagation) deferred to v5.9.1. See `.claude/ainous-roles/team-sync/artifacts/v5.9-design-taint-boundary.md`.
- **Team-mode teammate Write enforcement (v5.9.0, §15 mechanical — env-var fix round 2)**: PreToolUse check in `authority-enforce.sh` blocks Write and Edit calls when `CLAUDE_CODE_TEAMMATE_COMMAND` env var is non-empty (empirically verified in Claude Code binary 2026-04-19; fabricated vars `CLAUDE_TEAM_NAME`/`CLAUDE_TEAM_ROLE` removed). Error message cites v5.4.1 §15, runtime-charter §15.1, and the upstream `getAppState` crash. Coordinators and Agent subagents (no `CLAUDE_CODE_TEAMMATE_COMMAND`) are unaffected. Test coverage: `tests/test-teammate-write-block.sh` (8 TCs).
- **Bash teammate-write block (v5.9.1, M-new-1)**: Extends §15 enforcement to Bash tool — team-mode teammates (CLAUDE_CODE_TEAMMATE_COMMAND set) cannot mutate the filesystem via Bash (redirect, tee, dd of=, cp, mv, ln -s, mkdir, rm, rmdir, touch). Write-operation patterns checked after credential-deny gates (so credential exfil attempts still get the credential-deny reason). Read-only Bash (cat, ls, grep) is unaffected. Test coverage: `tests/test-teammate-bash-write.sh` (10 TCs).
- **Hook env-var liveness self-test (v5.9.1, R-6)**: `scripts/verify-hook-env-vars.sh` extracts all `CLAUDE_*` env-var references from hook scripts and verifies each one exists in the Claude Code binary via `strings`. Exits 2 with hook:line if any fabricated var is found; exits 0 with warning (graceful degradation) when binary is not accessible. Integrated into `scripts/pre-ship-gate.sh` release gate. Test coverage: `tests/test-verify-hook-env-vars.sh` (4 TCs). Would have caught both the v5.6.1 `CLAUDE_SESSION_ID` env read and the v5.9.0 round-1 `CLAUDE_TEAM_NAME` fabrication before they shipped.
- **Atomic log rotation (v5.9.1, Item 3)**: `hooks/session-start` log rotation now uses `fcntl.flock(LOCK_EX | LOCK_NB)` to prevent concurrent session-start race on the 10 MB boundary. Pattern: lock → read tail → write to `.tmp` → `os.rename` (atomic on POSIX) → release. If lock unavailable (another process rotating), skip this session — not fatal. Replaces non-atomic truncate-then-write from v5.8.2. Test coverage: TC-SS-7 and TC-SS-8 in `tests/test-session-start.sh`.
- **Analytical-role artifact surface (v5.9.2, B-1)**: `hooks/authority-enforce.sh` Layer-3 `JUNIOR_BASELINES` extended — keyword `"artifacts"` added to `architect`, `writer`, `researcher`, `security`, `signal` baselines. Exact component match against `.claude/ainous-roles/team-sync/artifacts/` path component; ships to every install without requiring `setup.sh` rerun or per-user `baselines.json`. Eliminates recurring AUTH decisions (AUTH-002..AUTH-005) for analytical artifact writes. No existing baseline patterns removed or broadened.
- **WebFetch/WebSearch teammate block (v5.9.3, M-new-2)**: PreToolUse check in `authority-enforce.sh` blocks `WebFetch` and `WebSearch` calls when `CLAUDE_CODE_TEAMMATE_COMMAND` env var is non-empty. Prevents the permission-explainer crash path (`Tl7/Uf8 → getAppState`) that fires when Claude Code's approval-prompt machinery is invoked from a team-mode teammate subprocess — the crash terminates the coordinator (team-lead) process and may destroy the tmux session. Exit 2 cites v5.4.1 §15 and the upstream crash; error token is `TEAM_MATE_TOOL_DENY`. Non-teammate contexts (coordinators, Agent subagents) pass through unchanged. Teammates needing web content must request the coordinator to relay results via mailbox. Test coverage: `tests/test-teammate-webfetch-block.sh` (8 TCs).
- **Tmux remain-on-exit (v5.9.3, Item N)**: Legacy tmux spawn template in `agents-instructions/coordinator-instructions.md` updated to call `tmux set-option -p remain-on-exit on` immediately after `tmux split-window`. Keeps crashed panes visible with exit status rather than silently closing — makes crash diagnosis possible without a full session restart. Security note included: appropriate for single-user dev environments; disable in shared-screen setups. See `.claude/ainous-roles/team-sync/artifacts/tmux-spawn-lifecycle-investigation.md` §H2 for root-cause analysis.
- **Operator `app/` baseline (v5.9.4, M-new-3) — removed**: The `"app/"` entry has been removed from the `operator` baseline in `hooks/authority-enforce.sh`; the PM client now lives outside the package at `ainous-team/pm-client/` (sibling of `src/`).
- **Write-proxy hook (v5.5.0+)**: PostToolUse `hooks/write-proxy` fires on SendMessage; parses envelope payloads, verifies HMAC via `hooks/_hmac_common.py` (shared with `scripts/compute-envelope-hmac.sh`), applies path containment (C-1), emits `hook-write` audit event (C-3). Three-tier identity resolution: session_id → spawn event → envelope role → teammate-nonce event → teammate_name/team_name direct. Teammates construct envelopes per runtime-charter.md §15.1.
- **Session_id source (v5.6.1/v5.6.2)**: all hooks parse `session_id` from stdin JSON (not env var); authority-enforce.sh uses defensive stdin-OR-env read.

> Design rationale and evolution notes: see CLAUDE-DESIGN.md §governance-mechanisms

### Agent Definitions
- Agent definitions live in `agents/` (slim) and `agents-instructions/` (full) within the plugin
- The slim file in `agents/` is authoritative for tool lists — the full instructions file is for behavior
- Universal knowledge (playbooks, growth) lives in `$HOME/.claude/ainous-roles/`
- Project knowledge (journals, memory) lives in `.claude/ainous-roles/`
- Never modify agent .md files programmatically — only the consolidator updates playbooks
- Agent Cards: `agents/capabilities/` — see CLAUDE-DESIGN.md §agent-cards. Files: `agents/capabilities/<role>.json`, `agents/capabilities/index.json`
- **Write-proxy envelope** is the canonical persistence channel for team-mode teammates (v5.5.0+). Teammates SendMessage with envelope; `hooks/write-proxy` intercepts and writes to disk preserving role attribution. See runtime-charter.md §15.1.
- **Pane-divider naming (v5.6.5)**: teammates spawned via `Agent(team_name=..., name=...)` MUST use the format `name="ainous-team:<role>(<description>)"` — provides informative pane dividers in tmux team mode

### Runtime Charter
- `agents-instructions/runtime-charter.md` — shared execution semantics injected into every role spawn — see CLAUDE-DESIGN.md §runtime-charter

### Team-Mode Crash Recovery
- Team-mode post-crash recovery: see `docs/team-mode-recovery.md`
- **Release-gate (v5.6.7)**: `scripts/verify-role-infrastructure.sh` — run before shipping; exits 0 iff every role has 4-file scaffold (playbook.md, growth.json, journal.md, learnings.jsonl) plus agent stub and capabilities JSON
- **Release-gate Gate 7 (v5.19.0)**: `scripts/pre-ship-gate.sh` — checks skill catalog freshness (committed `agents/capabilities/index.json` `skills` block matches `scripts/gen-skill-index.py` output) and reachability (every skill on disk in catalog; every invocable skill has ≥1 owning role). Mirrors Gate 6 / hook-manifest self-consistency pattern.
- **Journal-discipline (v5.6.6)**: `scripts/install-post-commit-journal-reminder.sh` — installs a git post-commit hook reminding the coordinator to append a journal entry; critical for execution-focused roles spawned without Stop-hook context
- **Envelope HMAC helper (v5.6.4)**: `scripts/compute-envelope-hmac.sh` — canonical HMAC computation for teammate write-proxy envelopes; wraps `hooks/_hmac_common.py` to guarantee protocol parity with the verification side

### Session Log & Crash Recovery
- `.claude/ainous-roles/team-sync/state/task-history.jsonl` — append-only session event log
- Records: spawn, completed, failed, retried, gate-passed, gate-failed, skill-invoked, subagent-outcome events
- `skill-invoked` event `source` values: `coordinator-spawn` (assigned by coordinator), `role-self-report` (self-reported by role instruction), `hook-auto` (mechanically observed by `hooks/skill-telemetry` PostToolUse hook — v4.14.0)
- `skill-invoked` event schema (v4.14.0): includes `session_id` field (CLAUDE_SESSION_ID) for precise session-scoped aggregation; existing readers tolerate this additive field
- `spawn` event schema (v4.15.0): includes `mode` field (`"agent"` | `"tmux"`) indicating which spawn mechanism was used; additive — existing readers without knowledge of this field continue to work
- Events now carry `schema: "N"` field (v4.20.0): new events written via `scripts/log-event.sh` include `"schema": "1"`; old lines without `schema` are treated as `schema: 0` and remain readable — no backfill required; see CLAUDE-DESIGN.md §session-log
- New event types: `teammate-nonce` (v5.5.1 — emitted when hook resolves teammate identity); `hook-write` (v5.5.0 — emitted per successful write-proxy hook execution, carries `destination`, `bytes_written`, `envelope_hmac`); `subagent-outcome` (v5.21.0 — emitted mechanically by `hooks/spawn-telemetry` on every Agent PostToolUse; carries `tool_status` ["returned"|"error"|"unknown"] and `child_session_id` for consolidator reconciliation against `completed`/`failed` events; source is always `hook-auto`)
- `spawn` event extended (v5.5.0+): includes `write_proxy_nonce_sha256` field (hash only; raw nonce lives in `~/.claude/teams/<team>/nonces/<mate>.nonce` mode 0600 after v5.7.0) for teammate envelope construction

> Read path (coordinator resuming from log) and design rationale: see CLAUDE-DESIGN.md §session-log

### Execution Traces & Diagnostic Signal
- Roles save raw traces to `.claude/ainous-roles/<role>/traces/` — error outputs, tool call sequences, strategy application context

> Consolidation and signal design: see CLAUDE-DESIGN.md §learning-loop

### Skills Vault
- Skills live in `skills/` — composable domain-expertise modules — see CLAUDE-DESIGN.md §skills-vault. Files: `skills/`, `agents/capabilities/<role>.json` (`default_skills`, `conditional_skills`)
- `agents/capabilities/index.json` `skills` catalog is GENERATED by `scripts/gen-skill-index.py` — never edit it by hand. Gate 7 in `scripts/pre-ship-gate.sh` enforces freshness (committed catalog matches a fresh regen) and reachability (every on-disk skill is cataloged; every `invocable: true` skill has ≥1 owning role). Mirrors Gate 6 / `manifest.sha256` / `gen-hook-manifest.sh` self-consistency pattern.

### Evidence Artifacts
- Analytical roles produce structured findings in `.claude/ainous-roles/team-sync/artifacts/`
- Artifacts are the handoff mechanism between phases (e.g., security-findings.md → developer)
- Coordinator mechanically verifies artifact existence before accepting contract completion

> Named artifact registry and contracts: see CLAUDE-DESIGN.md §named-artifacts

### Commits & Branches
- Write concise commit messages that focus on "why" not "what"
- Do not commit without being asked
- Confirm before any destructive git operation
- Use explicit file staging (`git add <files>`) not `git add -A`
- **Bump plugin version** in `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` when making feature commits (both files must match)
