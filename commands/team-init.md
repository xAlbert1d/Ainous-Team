---
name: team-init
description: Initialize Ainous Team for the first time. Guides you through choosing coordinator mode and sets up all 12 roles.
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
