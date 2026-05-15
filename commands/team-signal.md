---
name: team-signal
description: Scan external sources for team-relevant signals — trends, tools, vulnerabilities, and insights from GitHub, HackerNews, social platforms, RSS feeds, and more.
allowed-tools: [Read, Write, Grep, Glob, Bash, WebSearch, WebFetch, Agent]
---

# Team Signal Scan

Scan external information sources for signals relevant to the team's work.

## Arguments

- No argument or `quick`: Quick scan — Tier 1 sources only (RSS, GitHub, HN API). ~5 minutes.
- `deep`: Deep scan — all tiers including social, blogs, research. ~15-30 minutes.
- `<topic>`: Targeted scan — search all sources for a specific topic.

## Steps

1. Read project subscriptions: `.claude/ainous-roles/signal/subscriptions.md` (if exists)
2. If no subscriptions exist, copy template from `${CLAUDE_PLUGIN_ROOT}/templates/signal-subscriptions.md` and ask user to configure
3. Spawn @signal agent with the appropriate scan mode:
   - `subagent_type: "ainous-team:signal"`
   - Include scan mode (quick/deep/targeted) and any topic filter in the prompt
4. When @signal returns, review findings and route to relevant roles
5. Present a summary to the user:
   - How many signals found
   - Top 3-5 most relevant signals
   - Which roles should be notified
