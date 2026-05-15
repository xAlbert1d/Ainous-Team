---
name: team-retro
description: Run a periodic team health review — individual growth, team dynamics, coordinator self-assessment, and action items.
allowed-tools: [Read, Grep, Glob, Bash, Write, Agent]
---

# Team Periodic Review

Run the periodic team review process. This combines 1-on-1 growth reviews, team retro, and coordinator self-assessment.

## Steps

1. Check when the last review was: read `.claude/ainous-roles/coordinator/reviews.md` for the most recent `## Review:` entry date
2. Read `${CLAUDE_PLUGIN_ROOT}/skills/team-review-periodic/SKILL.md` for the full review methodology
3. Follow the skill's 4-part process: Individual Growth -> Team Dynamics -> Coordinator Self-Assessment -> Action Items
4. Write the review report to `.claude/ainous-roles/coordinator/reviews.md`
5. Present a summary to the user

If less than 7 days AND less than 10 commits since last review, ask the user if they want to run early.
