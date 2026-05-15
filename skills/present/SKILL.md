---
name: present
description: Technical presentation to any audience — storytelling with data, slide structure, demo scripting, adapting depth to audience. Use when preparing talks, demos, stakeholder updates, or any presentation of technical work.
---

# Presentation

## Core Principle

The audience's time is more valuable than your preparation time. Every minute of presentation should deliver value they couldn't get from reading a document.

## Audience Adaptation

Before structuring anything, answer: **who is in the room and what do they need?**

| Audience | They Care About | Avoid | Depth |
|----------|----------------|-------|-------|
| **Executives** | Impact, timeline, risk, cost | Implementation details, jargon | High-level, decision-focused |
| **Product** | User value, tradeoffs, timeline | Architecture internals | Feature-level, outcome-focused |
| **Engineers** | How it works, tradeoffs, edge cases | Marketing language, vague claims | Deep, technical, honest |
| **Mixed** | Different things simultaneously | Going too deep OR too shallow | Layer it: headline → context → detail |

For mixed audiences: lead with what executives need (impact, decision), then provide depth for engineers. Executives can leave after the first section; engineers stay for the details.

## Structure: The 3-Act Presentation

### Act 1: Why (20% of time)
- What problem are we solving? (use SCQA skill if applicable)
- Why does this matter NOW?
- What's the cost of doing nothing?
- **Hook**: open with the most interesting result, not the background

### Act 2: How (60% of time)
- What did we build / what do we propose?
- **Demo > slides > talking**: show the thing whenever possible
- Architecture overview (use `diagram` skill for visuals)
- Key decisions and tradeoffs — what we chose and what we gave up
- Risks and mitigations

### Act 3: What's Next (20% of time)
- Clear ask: what do you need from this audience?
- Timeline and milestones
- Open questions — what's still unresolved?
- One clear next step

## Demo Scripting

If you're showing a demo:
- **Script it.** Practice it. Time it. Don't wing it.
- Show the end result first (the "wow"), then show how it works
- Have a backup plan for when the demo breaks (screenshot, recorded video)
- Keep it under 5 minutes — demos lose attention fast
- Narrate what you're doing and why, not just clicking silently

## Slide Design (when slides are needed)

- **One idea per slide.** If a slide has two ideas, split it.
- **Headlines, not titles**: "Revenue grew 40% YoY" not "Revenue Performance"
- **Data visualization**: chart > table > bullet points. If it's a number, visualize it.
- **Minimal text**: if you're reading your slides, they have too much text
- **Consistent design**: use the `tone-enforce` skill principles for visual consistency

## When to Use

- Conference talks, meetups, internal tech talks
- Sprint demos, stakeholder updates
- Product reviews, architecture proposals
- Investor pitches, board updates
- Teaching, training, workshops
- Any context where you present work to others

## Anti-Patterns

- **Reading slides aloud**: if the audience can read it themselves, why are you presenting?
- **Starting with background**: 10 minutes of context before the interesting part. Lead with the result.
- **No clear ask**: presenting without telling the audience what you want from them
- **Demo without rehearsal**: live demos that break destroy confidence. Always have a backup.
- **One structure for all audiences**: presenting the same content to executives and engineers. Adapt.
- **All talking, no showing**: if you built something, show it. Words about a product are less compelling than the product itself.
