---
name: observability
description: Logging, metrics, tracing, and alerting strategy. Use when designing monitoring for a service, investigating production behavior, or setting up alerting. Covers the three pillars and runbook design.
---

# Observability

## Core Principle

You can't fix what you can't see. Observability is not monitoring — monitoring tells you WHAT is broken, observability tells you WHY.

## Three Pillars

### 1. Logs (what happened)
Structured, contextual records of events.

**Rules:**
- Structured format (JSON) — not free-text prose. Every log entry should be machine-parseable.
- Include context: request ID, user ID, operation, timestamp, duration
- Log levels matter: ERROR (action needed), WARN (degraded but functional), INFO (normal operations), DEBUG (development only — never in production)
- **Never log**: passwords, tokens, PII, full request bodies with sensitive fields
- **Always log**: request start/end with duration, errors with stack traces, state transitions, auth decisions (allowed/denied)

### 2. Metrics (how much)
Numerical measurements aggregated over time.

**The Four Golden Signals** (from Google SRE):
| Signal | What It Measures | Example |
|--------|-----------------|---------|
| **Latency** | Time to serve a request | p50, p95, p99 response time |
| **Traffic** | Demand on the system | Requests per second |
| **Errors** | Rate of failed requests | 5xx responses / total responses |
| **Saturation** | How full the system is | CPU %, memory %, connection pool usage |

If you measure nothing else, measure these four.

### 3. Traces (where)
End-to-end request path through the system.

**When essential:**
- Microservices: a request touches 3+ services
- Async workflows: message queues, background jobs
- Performance investigation: "which service is slow?"

**Implementation:** propagate a trace ID through all service calls. Each service logs its span (start, end, duration, status) with the trace ID.

## Alerting Strategy

### Alert on Symptoms, Not Causes
- **Good**: "Error rate exceeded 5% for 5 minutes" (symptom — users are affected)
- **Bad**: "CPU at 90%" (cause — maybe the system handles it fine)
- Exception: alert on causes that ALWAYS lead to symptoms (disk full, certificate expiring)

### Alert Severity

| Severity | Meaning | Response | Example |
|----------|---------|----------|---------|
| **Page** | User-facing impact NOW | Wake someone up | Error rate > 5%, service down |
| **Ticket** | Will become a problem soon | Fix this week | Disk 80% full, cert expires in 7 days |
| **Log** | Interesting but not actionable now | Review in retro | Unusual traffic pattern, slow query |

### Every Alert Needs a Runbook
An alert without a runbook wastes the on-call engineer's time:
```markdown
## Alert: [Name]
**What it means:** [plain English]
**Likely causes:** [ranked by probability]
**Immediate actions:** [step 1, step 2, step 3]
**Escalation:** [who to contact if steps don't resolve]
```

## When to Use

- Designing a new service — build observability in from the start
- Production incidents — "we had no visibility" means observability is missing
- Performance investigations — which component is the bottleneck?
- SLA/SLO definition — you can't promise what you can't measure
- Not just code — works for infrastructure, data pipelines, ML model performance

## Anti-Patterns

- **Alert fatigue**: 50 alerts per day = zero alerts per day. Nobody reads them. Alert on what matters.
- **Logging everything**: 10GB of logs per hour with no structure. Log what helps investigation, not everything.
- **Metrics without dashboards**: collecting metrics nobody looks at. If there's no dashboard, the metric doesn't exist.
- **Missing request ID**: logs from different services that can't be correlated. Propagate a request ID everywhere.
- **Monitoring without alerting**: beautiful dashboards that nobody watches. If it's important enough to graph, it's important enough to alert on.
