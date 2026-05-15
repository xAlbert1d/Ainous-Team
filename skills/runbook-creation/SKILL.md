---
name: runbook-creation
description: Operational runbook authoring. Use when creating or updating incident response procedures, deployment steps, rollback guides, or on-call playbooks. Invoke when a process must be reproducible by someone who wasn't present when it was designed.
---

# Runbook Creation

## Core Principle

Write for the on-call engineer at 3am who has never seen this system before. Every assumption you leave implicit is a minute of confusion during an incident. Runbooks that require prior knowledge are not runbooks — they are notes for the author.

## When NOT to Use

Do not use this skill for internal implementation documentation, API reference docs, or architecture decision records. Runbooks are for operators responding to events, not developers building features.

## Required Sections

Every runbook must contain all six sections — no exceptions:

**Trigger** — the exact alert name, symptom, or condition that causes an operator to open this runbook. Include the monitoring tool and the alert threshold. If there is no alert, describe how to detect the situation manually.

**Severity** — P1/P2/P3 and the SLA (e.g., "P2 — respond within 30 minutes, resolve within 4 hours"). Operators use this to decide whether to wake someone up.

**Prerequisites** — list every access, tool, credential, and permission needed before starting. If a step requires VPN, say so here. If it requires AWS Console access to a specific account, say so here. Operators with missing prerequisites must know before step 1, not during step 7.

**Steps** — numbered, with every step containing an action and a verification. Never write an action without a verification. See the step format below.

**Rollback** — explicit steps to undo if the runbook makes things worse. If no rollback exists, state that explicitly and document the escalation path instead.

**Escalation** — the named owner(s), contact method, and the condition that triggers escalation. "If this runbook doesn't resolve the issue within X minutes, contact [name] via [channel]."

## Step Format

Every step is either an action or a branch:

```
N. ACTION: <exact command or UI operation>
   VERIFY: <what to check, and what success looks like>

N. CHECK: <condition>
   - If <true>: continue to step N+1
   - If <false>: go to step M
```

Never write "check the logs." Write:
```
3. ACTION: Run: kubectl logs -n production deployment/api-server --tail=100 | grep ERROR
   VERIFY: If you see "connection pool exhausted", continue to step 4.
           If you see a different error, go to step 12 (Unknown Error Path).
```

## Five Authoring Techniques

### 1. Assumption-Free Writing
Before writing each step, ask: "What would someone need to know to execute this who has never touched this system?" State every tool name, binary path, environment name, and expected output explicitly.

### 2. Decision Tree Structure
Every branch point in an incident has two or more outcomes. Model them explicitly. Ambiguous prose ("if something seems wrong") forces the operator to make judgment calls under pressure. Binary, labeled branches ("if exit code is 0" / "if exit code is non-zero") eliminate ambiguity.

### 3. Verification Steps
Verification is not optional. After every destructive or stateful action, include a check that confirms the action succeeded. This prevents operators from proceeding past a silent failure into deeper breakage.

### 4. Escalation Paths
Operators must never reach the end of a runbook with an unresolved incident and no next step. The last section of every runbook names a human, a contact method, and a time threshold.

### 5. Idempotency
Write every step so it can be safely re-run. If a step creates a resource, add a guard: "If the resource already exists, skip this step." Idempotent runbooks allow operators to restart from any point without worsening the situation.

## Anti-Patterns

- "Check the logs" — which logs, where, what to look for, and what the output means
- "Restart the service" — which service, on which host, using which command, and how to verify it restarted
- Steps with no verification — the operator has no way to know if the step worked
- Runbooks that require you to read another runbook mid-incident — inline the critical parts or link with a clear label
- "Contact the on-call engineer" as step 1 — exhaust self-service options first; reserve escalation for when they are needed
