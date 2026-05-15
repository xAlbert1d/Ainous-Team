---
name: confidence-calibration
description: Structural confidence labeling for role outputs. Use when emitting findings, assessments, or recommendations that downstream roles or the coordinator will act on. Invoke before any completed event where genuine uncertainty exists.
---

# Confidence Calibration

## Core Principle

LLMs have trained overconfidence, not fear-suppressed uncertainty. The intervention must be structural (explicit labels, schema fields, coordinator gating) — not social (reassurance, permission to be uncertain). A role that outputs false confidence is more dangerous than one that outputs admitted uncertainty, because downstream roles and the coordinator cannot compensate for what they cannot see.

## When to Use

- Any role emitting findings, assessments, or recommendations that will be used by downstream roles
- Research findings before design begins
- Security assessments before implementation
- Architect designs before developer implements
- Tester results before coordinator accepts completion
- Any `completed` event where the role has genuine uncertainty

## When NOT to Use

- Binary correct/incorrect outputs — tests pass or fail, no confidence gradation applies
- Mechanical operations (file reads, git commands, tool calls)
- Tasks where the output IS the uncertainty — a researcher reporting "I don't know" is complete, not uncertain

## Structured Confidence Fields

Emit with every significant `completed` event:

```json
{
  "confidence": 7,
  "confidence_basis": "reasoned",
  "uncertain_areas": ["dependency behavior beyond 3 hops", "production-scale performance"]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `confidence` | 0–10 integer | Overall confidence in the output |
| `confidence_basis` | enum | How confidence was earned (see below) |
| `uncertain_areas` | string list | Explicit list of what the role doesn't know |

## Confidence-Basis Discipline

Never report a higher basis than earned:

| Basis | Meaning | Required evidence |
|-------|---------|-------------------|
| `tested` | Directly verified | Tests ran and passed, code read, source checked |
| `reasoned` | Inference chain is sound but unverified | Logical derivation from known premises |
| `inferred` | Pattern match from analogous cases | Similar prior cases observed |
| `guessed` | Below 40% confidence | Low evidence — emit with this basis, do not suppress |

Conflating `reasoned` with `tested` is the most common overconfidence failure. Reporting confidence 8+ without a `tested` basis requires explicit justification.

## Coordinator Gating

At verification gates, the coordinator applies:

- **confidence ≥ 8, basis `tested` or `reasoned`**: proceed normally
- **confidence 6–7**: proceed with `uncertain_areas` flagged to the next phase
- **confidence < 6**: require additional verification pass or spawn a second opinion

## Anti-Overconfidence Prompting

When invoking this skill, add to the spawn prompt:

> Before completing, explicitly identify: what are you most uncertain about? What would change your conclusion? Report these in `uncertain_areas`.

## Calibration Tracking

Consolidator tracks per-role: if stated confidence does not predict actual pass rate, future confidence reports from that role are discounted. Roles that consistently over-report confidence lose calibration credit.

## Output Format

```
confidence: <0-10>
confidence_basis: tested|reasoned|inferred|guessed
uncertain_areas:
  - <specific area 1>
  - <specific area 2>
```

## Anti-Patterns

- **Omitting confidence fields when uncertain** — downstream roles make decisions assuming certainty that doesn't exist
- **Prose hedging instead of structured labels** ("this might be...", "probably...") — invisible to coordinator gating
- **Treating confidence expression as weakness** — it is quality signal, not failure
- **Conflating `reasoned` with `tested`** — the most common overconfidence failure
- **Reporting confidence 8+ without `tested` basis** — requires explicit justification
- **Using confidence to avoid making a recommendation** — emit the recommendation AND the confidence

## The Biological Analogy Failure

"Psychological safety" (the biological fix for underexpressed uncertainty — create a safe environment so people speak up) does not apply to LLMs. LLMs don't suppress uncertainty out of fear. They overexpress confidence due to training distribution: confident-sounding outputs were selected for. The fix is structural override, not environmental safety. This skill is named "confidence calibration" rather than "psychological safety" to prevent the wrong intervention from being applied.

## Evidence Base

- LLM overconfidence is comparable to human experts, and uncalibrated confidence is more dangerous than incompetence (PersonaGym, 2025)
- LLMs change 58% of responses under user pressure even when originally correct — a downstream effect of overconfidence
- Confirmed gap by: @researcher (internal audit), @security (finding suppression risk), runtime-charter (confidence schema added v4.8.0)
