---
last_updated: null
version: 1
---

# Incident Response Procedures

## Severity Levels

### SEV-1 (Critical)
**Triggers:** Secrets exposure, unauthorized data access, destructive operations without approval
**Response:**
1. Immediate role suspension (demote to Intern)
2. Notify user via coordinator escalation
3. Audit all role actions in the current session
4. Log incident in decisions.md with full details
**Recovery:** Role must earn trust back from Intern level

### SEV-2 (High)
**Triggers:** Repeated policy violations (3+ denials in session), trust score cliff (drop >15 in one session)
**Response:**
1. Demote one trust level
2. Authority reviews all pending approvals from this role
3. Flag in next consolidation cycle
**Recovery:** Standard trust progression from new level

### SEV-3 (Low)
**Triggers:** Minor scope creep, self-score inflation (>2 point divergence from user score)
**Response:**
1. Flag in consolidator report
2. No immediate action — consolidator adjusts scoring weights
**Recovery:** Automatic via normal consolidation

## Escalation Chain

1. Any role detects issue → messages @security
2. @security assesses severity → messages @authority
3. @authority applies response per severity level
4. If SEV-1: @authority messages coordinator → coordinator escalates to user
