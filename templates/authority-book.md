---
last_updated: null
version: 1
---

# Authority Book — Role Permission Matrix

Authority approval is only required for actions **outside** a role's baseline permissions.
Actions within baseline are auto-approved. Actions outside require a message to @authority.

## Permission Matrix

| Role | Read | Write | Git | Network | Special |
|------|------|-------|-----|---------|---------|
| **coordinator** | all files | task plans, journals | commit (no push) | no | spawns teammates, manages task list |
| **developer** | all files | production code (`src/`, `lib/`, `app/`, `pkg/`) | commit (no push) | no | the primary implementer |
| **architect** | all files | design docs, specs | commit (no push) | no | — |
| **code-quality** | all files | none (read-only reviewer) | no | no | — |
| **tester** | all files | test files only (`tests/`, `*test*`, `*spec*`) | commit (no push) | no | — |
| **researcher** | all files | research notes, journals | no | read-only (WebSearch, WebFetch) | — |
| **writer** | all files | docs only (`docs/`, `*.md`, `README*`) | commit (no push) | no | — |
| **designer** | all files | design specs, assets (`design/`, `assets/`, `*.svg`, `*.css`, `*.scss`, `.claude/ainous-roles/designer/`) | commit (no push) | no | can invoke image-gen skills |
| **security** | all files | security reports, journals | no | read-only (for CVE checks) | can escalate to authority |
| **authority** | all files | authority-book, decisions, journals | no | no | approval/denial power |
| **consolidator** | all role files | playbooks, growth.json, journals | commit (universal repo) | no | — |
| **signal** | all files | team-knowledge, signal journals, subscriptions | no | read-only (WebSearch, WebFetch, Camoufox) | external intelligence scout |
| **retriever** | all role files | none (read-only) | no | no | — |

## Out-of-Baseline Actions (require @authority approval)

Any action not listed in a role's baseline above requires authority approval. Common examples:

- **code-quality wants to write a fix** — needs authority (baseline is read-only)
- **researcher wants to modify a file** — needs authority (baseline is read-only + notes)
- **tester wants to modify production code** — needs authority (baseline is test files only)
- **coordinator wants to push to remote** — needs authority (baseline is commit only)
- **writer wants to modify non-doc files** — needs authority (baseline is docs only)
- **designer wants to modify source code** — needs authority (baseline is design specs and assets only)
- **designer wants to publish brand assets publicly** — needs authority (brand-asset publication requires approval)
- **any role wants to install packages** — needs authority (no role has this baseline)
- **any role wants to run destructive git** — escalate to user (no role has this baseline)

## Escalate to User (no role can approve)

These always require human approval, even authority cannot self-approve:

- Push to remote repository
- Destructive git operations (force push, reset --hard, branch -D)
- Install, upgrade, or remove packages
- Modify CI/CD pipelines
- Add MCP servers
- Open network listeners
- Delete production data

## Updating This Book

- Only @authority can modify this file
- Changes require a decision log entry explaining why
- The coordinator can request permission changes via @authority
- Version is incremented on each update

## Trust Levels

Each role has a trust level tracked in growth.json that determines permission scope.

### Intern (trust_score < 50)
- Read-only access to all files
- Cannot use Write, Edit, or Bash for modifications
- All outputs are suggestions requiring authority approval
- Minimum 3 sessions before promotion eligibility

### Junior (trust_score 50-74) — default
- Baseline permissions as defined in the Permission Matrix above
- Out-of-baseline actions require authority approval

### Senior (trust_score 75-89)
- Expanded baseline: can act on adjacent areas with notification (not approval)
- Tester at Senior: can modify test infrastructure, not just test files
- Architect at Senior: can write implementation stubs, not just design docs
- Writer at Senior: can modify code comments, not just doc files

### Principal (trust_score 90+, requires explicit user approval)
- Broadest autonomy within domain scope
- Can approve other roles' out-of-baseline requests (delegation)
- Very few roles should reach this level

### Promotion Gates
All required: minimum sessions (3/8/15 per level), trust score threshold (50/75/90), zero violations in last 5 sessions. Principal requires explicit user approval.

### Trust Score Calculation
+2 per session without violations, +1 per authority approval granted, -5 per denial, -15 per violation, -3 per user override. Capped 0-100.

### Demotion Triggers (immediate)
- Critical violation (secrets, destructive ops) — Intern
- 3+ authority denials in one session — drop one level
- Score below current level minimum — drop one level
- User reverts work 3+ times — drop one level
