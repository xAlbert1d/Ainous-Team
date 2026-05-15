---
name: compliance-check
description: Regulatory compliance review for code and data systems. Use when code handles PII, PHI, payment data, or operates in regulated environments (GDPR, HIPAA, SOC 2, PCI-DSS). Invoke before shipping features that touch user data collection, retention, or deletion.
---

# Compliance Check

## Core Principle

Compliance is a design constraint, not a post-launch audit. Retrofitting compliant data flows onto a system built without them is 10x more expensive than building them in from the start. Identify the applicable regulations before writing the first line of code that touches regulated data.

## When NOT to Use

Skip this skill for purely internal tooling with no user data. Do not apply full compliance overhead to developer scripts, internal dashboards that touch only synthetic data, or systems explicitly scoped to non-regulated data categories.

## Step 1: Data Classification

Before any other check, identify what category of data is involved. The category determines which regulations apply.

| Category | Examples | Regulations |
|----------|----------|-------------|
| **PII** | name, email, IP address, device ID, location | GDPR, CCPA, local privacy laws |
| **PHI** | health records, diagnoses, prescriptions, insurance | HIPAA |
| **Financial** | card numbers, bank accounts, transaction history | PCI-DSS, GLBA |
| **Children's data** | any data from users under 13/16 | COPPA, GDPR Art. 8 |
| **Public / Non-personal** | aggregated stats, public records | No personal data regime |

If the category is unclear, treat it as PII. Reclassifying down is safer than treating regulated data as unregulated.

## Six Core Checks

### 1. Data Flow Mapping
Trace where data enters the system, every place it is stored, every service it is forwarded to, and when it is deleted. A data flow map must answer: What is collected? Where does it go? Who can read it? When is it deleted? If you cannot answer all four questions, the flow is not auditable.

### 2. Consent and Purpose Limitation
Data collected for one purpose cannot be used for another without re-consent (GDPR Art. 5(1)(b)). Check: Is the data being used beyond the stated reason for collection? Is analytics data being used to train models without explicit consent? Is a marketing system accessing support tickets?

### 3. Retention Policy Enforcement
Every regulated data category requires a retention limit. Check: Does the code implement a deletion path? Is there a scheduled job that enforces retention? Are backups included in the retention policy, or do they persist deleted data indefinitely? No deletion path = non-compliant by default.

### 4. Breach Notification Readiness
If this data were exposed, would the team know within 72 hours (GDPR requirement)? Check: Is there audit logging for data access? Are access logs retained long enough to reconstruct what was exposed? Is there a documented incident response process that includes regulatory notification steps?

### 5. Third-Party Data Sharing
Any data sent to an external service (analytics, monitoring, ML APIs, CDNs) requires a Data Processing Agreement (DPA) with that vendor. Check: Are all third-party integrations covered by DPAs? Does the privacy policy disclose these vendors? Is data minimized before sending to third parties (e.g., hashing emails before sending to analytics)?

### 6. Access Control and Minimization
Apply minimum necessary access. Check: Can every engineer with production access read raw PII? Is access to PHI restricted and logged? Are database columns containing regulated data encrypted at rest with separate key management?

## Regulation Quick Reference

**GDPR (EU):** Right to erasure (implement a delete endpoint), data minimization (collect only what you need), explicit consent, DPAs for all processors, 72-hour breach notification to supervisory authority.

**HIPAA (US Health):** PHI must be encrypted in transit and at rest. Audit logs for all PHI access. Minimum necessary standard for access. Business Associate Agreements (BAAs) required with all vendors who process PHI.

**PCI-DSS (Payments):** Never store CVV after authorization. Card numbers must be tokenized (store token, not PAN). Quarterly vulnerability scans. Access to cardholder data restricted and logged. Network segmentation for cardholder data environments.

**SOC 2:** Access controls, availability SLAs, confidentiality controls, processing integrity (data is complete and accurate), privacy (notice, consent, collection, use, retention, disclosure, quality, monitoring).

## Findings Format

Report each gap as:

```
C-<N>: <title>
Regulation: GDPR | HIPAA | PCI-DSS | SOC 2
Risk: critical | high | medium | low
Observation: <what the code does>
Gap: <what the regulation requires that is missing>
Remediation: <specific change needed>
```

## Anti-Patterns

- Logging PII in application logs — logs are often long-retained, widely accessible, and included in bug reports
- "We'll add compliance later" — data collected non-compliantly cannot be retroactively legitimized; it must be deleted
- Conflating encryption with compliance — encryption satisfies one control; access, audit, retention, and consent are separate controls that encryption does not address
- Using production data in staging/dev environments — staging systems almost never have production-equivalent access controls
