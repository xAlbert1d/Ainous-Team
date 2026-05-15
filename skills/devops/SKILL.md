---
name: devops
description: Guides deployment, CI/CD, infrastructure, and automation tasks with concrete commands and configuration. Use for CI/CD setup, deployment troubleshooting, infrastructure changes, and release management.
---

# DevOps Assistant

## Core Principle

If you do it twice, automate it. If you can't automate it, document it. If you can't document it, simplify it.

## Core Areas

### Version Control Workflows
- **Branching**: feature branches from main, short-lived (< 1 week)
- **Tagging**: semantic versioning — `vMAJOR.MINOR.PATCH`
  - MAJOR: breaking changes
  - MINOR: new features, backward compatible
  - PATCH: bug fixes only
- **Release**: tag → build → test → stage → deploy
- Always: `git tag -a v1.2.3 -m "Release v1.2.3: brief description"`

### CI/CD Pipeline Design
```
commit → lint → test → build → security scan → stage deploy → smoke test → prod deploy
```
- Every step must be: fast (< 10min total), reproducible, and capable of failing loudly
- Cache dependencies between runs (node_modules, pip cache, docker layers)
- Separate build artifacts from source — deploy artifacts, not source code

### Container & Deployment
- Dockerfile: multi-stage builds, non-root user, minimal base image
- Environment config: 12-factor app — config via environment variables, not files
- Health checks: liveness (is it running?) + readiness (can it serve traffic?)
- Rollback plan: ALWAYS have one before deploying. Blue-green or canary preferred.

### Monitoring & Alerting
- Three pillars: logs (what happened), metrics (how much), traces (where)
- Alert on symptoms (error rate, latency), not causes (CPU, memory) — unless correlated
- Every alert must have a runbook: what to check, what to do

## Deployment Checklist

Before deploying to production:
- [ ] All tests pass in CI
- [ ] Security scan clean (no critical/high vulnerabilities)
- [ ] Database migrations tested on staging
- [ ] Rollback procedure documented and tested
- [ ] Monitoring/alerting configured for new features
- [ ] Feature flags in place for gradual rollout (if applicable)

## Deployment Strategies (from gstack)

| Strategy | How It Works | Use When |
|----------|-------------|----------|
| **Blue-green** | Two identical environments; switch traffic atomically | Need instant rollback, can afford 2x infrastructure |
| **Canary** | Route 5% of traffic to new version, monitor, gradually increase | Want to validate with real traffic, can tolerate partial exposure |
| **Rolling** | Replace instances one at a time | Default for most deployments, k8s default |
| **Strangler fig** | Incrementally replace old system by routing requests to new system, one endpoint at a time | Migrating legacy systems — never big-bang rewrite |

**Default to canary over global rollout.** Incremental exposure catches issues before they affect everyone.

**Strangler fig over big-bang rewrite.** Route one endpoint at a time from old to new. When all endpoints are routed, decommission the old system. This is the safest migration pattern — at every step, you can stop and the system still works.

## Anti-Patterns

- **Manual deployment steps**: if a human has to remember to do it, it will be forgotten
- **No rollback plan**: "We'll fix forward" is not a plan — it's a prayer
- **Secrets in config files**: use environment variables or a secret manager, never committed files
- **Skipping staging**: "It worked on my machine" is the DevOps equivalent of "trust me bro"
- **Alert fatigue**: 50 alerts per day = 0 alerts per day (nobody reads them). Alert on what matters.
- **Snowflake servers**: manually configured servers that nobody can reproduce. Use infrastructure as code.
- **Big-bang rewrite**: replacing an entire system at once. Use strangler fig pattern instead.
