---
name: negotiate
description: Managing conflicting requirements, stakeholder alignment, technical vs business tradeoffs, and saying no constructively. Use when facing competing demands, scope conflicts, or resource contention.
---

# Negotiation & Stakeholder Alignment

## Core Principle

Negotiation is not about winning — it's about finding the solution that satisfies the most important constraints for all parties. Understand what each side NEEDS (not just what they WANT) and you'll find the overlap.

## Framework: Interests, Not Positions

| Concept | Example |
|---------|---------|
| **Position** (what they say) | "We need this feature by Friday" |
| **Interest** (what they need) | "We have a demo with a key client on Monday" |
| **Solution space** | Demo-ready version by Friday (may not be production-ready) |

Always ask: "What's driving this request?" The stated position is often not the real need.

## Common Conflict Patterns

### Technical vs Business
- Business: "Ship it now"
- Engineering: "It's not ready — there's tech debt / missing tests / security gaps"
- **Resolution framework:**
  1. Quantify the risk: "Shipping now has X% chance of Y consequence"
  2. Quantify the delay: "Proper fix takes N more days"
  3. Propose options: ship with known risks (documented), ship partial (reduced scope), delay (quantified benefit)
  4. Let the business decide with full information — don't withhold risk to get your preferred outcome

### Scope vs Timeline
- "We need all 10 features by launch"
- "We can do 6 features by launch, or 10 features 3 weeks after launch"
- **Resolution:** Use MoSCoW from `prioritize` skill. Force-classify into Must/Should/Could/Won't. Ship Must by deadline, Should in fast follow.

### Quality vs Speed
- "Just make it work"
- "If we skip tests, it'll break in production"
- **Resolution:** Propose the minimum quality bar: "We ship with tests for the happy path. Edge cases in a follow-up PR this week." Never ship zero tests — the minimum is one test per new code path.

### Multiple Stakeholders
- Stakeholder A wants feature X
- Stakeholder B wants feature Y
- Both claim top priority
- **Resolution:** Make the tradeoff explicit. "We can do X this sprint and Y next sprint, or Y this sprint and X next sprint. Here's the impact of each order." Force a joint decision rather than trying to do both.

## Saying No Constructively

"No" without an alternative is a dead end. Always pair with what you CAN do:

| Instead of | Say |
|-----------|-----|
| "No, we can't do that by Friday" | "We can deliver the core workflow by Friday. The full version would be ready next Wednesday." |
| "No, that's too risky" | "That approach has X risk. Here's a safer alternative that achieves 80% of the goal." |
| "No, that's out of scope" | "That's a great idea for v2. For this release, we're focused on [scope]. Adding it now would delay shipping by N days." |
| "No" | "Yes, and here's what it would cost: [timeline/scope/quality tradeoff]" |

## Alignment Checklist

Before starting work that involves multiple stakeholders:
1. **Shared understanding**: does everyone agree on WHAT we're building? (Write it down, get sign-off)
2. **Priority alignment**: does everyone agree on the ORDER of importance? (Use `prioritize` skill)
3. **Success criteria**: does everyone agree on WHEN we're done? (Concrete, measurable)
4. **Tradeoff awareness**: does everyone understand what we're NOT doing? (Won't list)
5. **Escalation path**: if disagreements arise, who decides? (Name the person)

## When to Use

- Sprint planning with competing requests
- Architecture decisions with business constraints
- Scope negotiations with product/design
- Resource allocation conversations
- Vendor negotiations, contract discussions
- Any conversation where two parties want different things from the same resource

## Anti-Patterns

- **Avoiding conflict**: saying yes to everything and then delivering nothing on time
- **Technical veto**: using technical complexity as a reason to reject business needs without proposing alternatives
- **Hidden agendas**: advocating for a position without disclosing your real interest
- **Escalation as first resort**: going to the manager before trying to resolve directly
- **Zero-sum thinking**: "if they get X, I lose Y" — often both can get what they need with creative solutions
- **Agreement without commitment**: everyone nods in the meeting, nobody follows through. Write down decisions and owners.
