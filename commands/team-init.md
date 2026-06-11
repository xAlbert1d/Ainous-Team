---
name: team-init
description: Initialize Ainous Team for the first time. Guides you through choosing coordinator mode and sets up all 13 roles.
---

Check if Ainous Team is already initialized by looking for `~/.claude/ainous-roles/`.

If already initialized:
- Inform the user that Ainous Team is already set up at `~/.claude/ainous-roles/`
- Suggest they can re-run setup manually with `--agentmode` if they want to switch modes:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --agentmode`
- Do not re-run setup automatically

If not initialized:
1. Explain the two modes briefly:
   - **Coordinator-as-default** (recommended): Claude automatically plans, delegates to role agents, and synthesizes results. You just type tasks naturally.
   - **Agent mode**: You manually invoke roles with `@coordinator`, `@developer`, etc.

2. Ask the user which mode they want using AskUserQuestion with these options:
   - "Coordinator-as-default (recommended)" — Claude automatically acts as the team coordinator
   - "Agent mode" — You manually invoke roles with @mentions

3. Based on their choice, run the setup script:
   - Coordinator-as-default: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"`
   - Agent mode: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --agentmode`

4. After setup completes, confirm success and show what's available:
   - `/team-status` — dashboard
   - `/team-history` — session history
   - `/team-alerts` — health checks
   - `/team-retro` — periodic team review

5. Arm the periodic self-improvement cron (same logic as coordinator-instructions §5b — reference that section rather than duplicating the full prompt text to avoid drift):
   - Call `CronList`; if no job whose prompt contains `[ainous-self-improve]` exists, call `CronCreate` as specified in coordinator-instructions §5b.
   - Before arming, ensure `.claude/.gitignore` lists `scheduled_tasks.json` (append if absent).
   - This is best-effort: if `CronCreate`/`CronList` are unavailable (older Claude Code), skip silently — the SessionStart reminder is the floor.
