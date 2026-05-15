---
name: threat-model
description: Structured threat modeling using STRIDE framework and trust boundary mapping. Use when designing security-sensitive features, reviewing architecture for threats, or preparing for security audits. Extends security-scan with architecture-level thinking.
---

# Threat Modeling

## Core Principle

Vulnerability scanning finds bugs in code. Threat modeling finds flaws in design. Both are necessary — scanning without modeling misses architectural weaknesses.

## STRIDE Framework

Analyze each component of the system against six threat categories:

| Threat | Question | Example |
|--------|----------|---------|
| **S**poofing | Can an attacker pretend to be someone else? | Forged auth tokens, stolen session cookies, DNS spoofing |
| **T**ampering | Can an attacker modify data they shouldn't? | SQL injection, man-in-the-middle, unsigned config files |
| **R**epudiation | Can an attacker deny their actions? | Missing audit logs, unsigned transactions, no request logging |
| **I**nformation Disclosure | Can an attacker access data they shouldn't? | Error messages with stack traces, unencrypted storage, verbose logs |
| **D**enial of Service | Can an attacker prevent legitimate use? | Unbounded queries, no rate limiting, resource exhaustion |
| **E**levation of Privilege | Can an attacker gain higher access? | Missing auth checks, IDOR, role confusion, path traversal |

For each component: walk through all six categories. Most components are vulnerable to 2-3. If you find zero threats, you're not looking hard enough.

## Trust Boundary Mapping

A trust boundary is where code with one trust level meets code or data with a different trust level.

### Step 1: Identify Boundaries
- **External → Internal**: user input, API requests, webhooks, file uploads
- **Internal → External**: API calls to third parties, email sending, database queries
- **Service → Service**: internal microservice calls, queue messages
- **Privilege levels**: admin vs user, authenticated vs anonymous, owner vs viewer

### Step 2: Map Data Flow Across Boundaries
For each boundary crossing:
- What data crosses?
- Who/what is on each side?
- What validation/sanitization happens at the crossing?
- What happens if the data is malicious?

### Step 3: Assess Each Crossing
- **Input validation**: is data validated at the boundary? (Not deeper — at the boundary)
- **Authentication**: is the caller verified before data crosses?
- **Authorization**: does the caller have permission for this specific action?
- **Encryption**: is data protected in transit? At rest?
- **Logging**: is the crossing auditable?

## Threat Model Output Format

```markdown
## Threat Model: [System/Feature Name]

### Trust Boundaries
1. [Boundary name] — [what's on each side]
2. ...

### Threats Identified
#### T-1: [Threat name] (STRIDE: [category])
- **Component:** [what's affected]
- **Boundary:** [which trust boundary]
- **Attack:** [how an attacker would exploit this]
- **Impact:** critical / high / medium / low
- **Mitigation:** [specific countermeasure]
- **Status:** mitigated / accepted / open

### Risk Summary
| Category | Threats Found | Mitigated | Accepted | Open |
|----------|--------------|-----------|----------|------|
| Spoofing | ... | ... | ... | ... |
| ...      | ... | ... | ... | ... |
```

## When to Use

- Before implementing authentication or authorization systems
- When adding new API endpoints that accept user input
- When integrating with third-party services
- Before a security audit (prepare the model proactively)
- When handling sensitive data (PII, financial, health, credentials)
- Architecture reviews for any system that faces the internet
- Not just code — works for infrastructure, processes, and organizational security

## Lightweight Mode

For smaller features that don't warrant a full STRIDE analysis:
1. Draw the data flow (even mentally)
2. Identify where untrusted data enters
3. Check: is it validated? authenticated? authorized? logged?
4. If all four: probably fine. If any missing: investigate.

## Anti-Patterns

- **Threat modeling after implementation**: the model should inform the design, not audit the result. Do it early.
- **STRIDE as checkbox**: mechanically listing "no spoofing risk, no tampering risk" for every component. If you're not finding threats, you're not trying.
- **Missing the human element**: not all threats are technical. Social engineering, insider threats, credential sharing — these need modeling too.
- **Treating all threats equally**: a low-impact information disclosure is not the same as a critical privilege escalation. Prioritize by impact.
- **Security theater**: adding mitigations that look good but don't actually address the threat (e.g., rate limiting on an endpoint with no authentication)
