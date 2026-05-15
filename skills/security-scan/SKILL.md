---
name: security-scan
description: Security scanning methodology. Use when reviewing code for vulnerabilities, auditing dependencies, or checking for secrets and misconfigurations before release.
---

# Security Scanning

## Core Principle

Secure by default: deny first, grant explicitly, minimize surface area. Every endpoint, config, and data path is hostile until proven safe.

## Scan Priority (by risk)

1. **Secrets and auth** -- leaked credentials grant immediate full access
2. **Injection flaws** -- untrusted input reaching interpreters (SQL, shell, template)
3. **Authorization gaps** -- authenticated users accessing resources they shouldn't
4. **Configuration weaknesses** -- defaults, debug modes, permissive CORS, missing headers

Use OWASP Top 10 categories as your checklist framework: Broken Access Control, Cryptographic Failures, Injection, Insecure Design, Security Misconfiguration, Vulnerable Components, Authentication Failures, Data Integrity Failures, Logging Gaps, SSRF. Reference them by name to ensure coverage -- don't skip categories just because they seem unlikely.

## Eight Developer Mistakes to Check

1. **Untrusted input flows** -- trace every user input to where it's consumed. If it reaches a query, command, or template without sanitization, flag it.
2. **Custom crypto** -- rolled-your-own encryption, hashing, or token generation instead of standard libraries. Always flag.
3. **Error detail exposure** -- stack traces, internal paths, database names, or version strings in responses.
4. **Missing authorization checks** -- authenticated != authorized. Every operation on a resource must verify the caller owns or has permission for that resource.
5. **Session mismanagement** -- tokens that never expire, sessions not invalidated on logout, cookies missing Secure/HttpOnly/SameSite flags.
6. **Outdated dependencies** -- known CVEs in pinned versions. Check lock files, not just manifests.
7. **Missing audit logs** -- authentication events, privilege changes, data access, and admin operations must be logged with who/what/when.
8. **Default configurations** -- default passwords, sample configs shipped to production, debug endpoints left enabled.

## Defense-in-Depth Layers

Security fails when a single layer is the only barrier. Verify controls at each level:
- **Network:** firewall rules, TLS enforcement, internal service isolation
- **Application:** input validation, authentication, authorization, rate limiting
- **Data:** encryption at rest and in transit, minimal privilege database accounts, parameterized queries
- **Monitoring:** intrusion detection, anomaly alerts, audit log review, incident response plan

## Secrets Detection Patterns

Scan code, config, and environment files for:
- API keys: strings matching `[A-Za-z0-9_-]{20,}` near keywords like `api_key`, `apikey`, `API_KEY`
- Tokens: `Bearer `, `ghp_`, `sk-`, `xox[bpas]-`, `AKIA` prefixes
- Passwords: assignments to variables named `password`, `passwd`, `secret`, `credential`
- Private keys: `-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`
- Connection strings: URIs containing `://user:pass@`

Check `.env`, `.env.*`, config YAML/JSON, CI pipeline files, and test fixtures.

## Input Validation Rules

- **Allow-lists over deny-lists.** Define what IS valid, reject everything else.
- **Validate type, length, and format** at the boundary -- before data enters business logic.
- **Distrust all client data** including headers, cookies, query params, and request bodies.
- Reject, don't sanitize, when possible. Sanitization is a second chance for attackers.

## Findings Format

Report each finding as a structured artifact:

```
S-<N>: <title>
Severity: critical | high | medium | low
Location: <file>:<line>
Observation: <what you found>
Evidence: <code snippet or config value showing the issue>
Fix: <specific remediation step>
```

Number findings sequentially. Group by severity in the final report.
