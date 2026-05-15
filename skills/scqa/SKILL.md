---
name: scqa
description: Structures content using the Situation→Complication→Question→Answer framework for clear logical narratives. Use when writing architecture proposals, RFCs, incident reports, or design documents.
---

# SCQA Writing Framework

## Core Principle

Every compelling piece of technical writing follows the same arc: here's where we are, here's the problem, here's the question that matters, here's the answer.

## Four Phases

### Phase 1: Situation
- Set context the reader needs — current state, assumptions, background
- Keep it short — 2-3 sentences maximum. The reader wants to get to the problem.
- Only include context that's necessary to understand the complication

### Phase 2: Complication
- Introduce the problem, tension, or change that disrupts the situation
- This is what makes the reader care. No complication = no reason to keep reading.
- Be specific: "Response times increased 3x after the migration" not "performance got worse"

### Phase 3: Question
- Frame the key question that naturally arises from the complication
- The question should be what the reader is already thinking
- One question only. If you have multiple questions, you have multiple documents.

### Phase 4: Answer
- Deliver the solution, insight, or recommendation
- Lead with the conclusion, then support with evidence
- Include trade-offs and alternatives considered

## When to Use

- Architecture Decision Records (ADRs)
- RFCs and design proposals
- Incident postmortems
- Team communications and status updates
- Technical blog posts

## Anti-Patterns

- **Burying the lead**: 3 paragraphs of context before the actual point. Cut ruthlessly.
- **Missing complication**: jumping from situation to answer. Without tension, the reader doesn't understand why the answer matters.
- **Wrong question**: answering a different question than the complication implies. Re-read your complication — what question does it naturally raise?
- **Answer without evidence**: "We should use X" without explaining why or what alternatives were considered.
