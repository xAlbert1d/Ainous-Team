---
name: infographic
description: Turns data and processes into structured visual summaries using markdown tables, metrics, and hierarchy. Use for project reports, dashboards, status summaries, and team presentations.
---

# Infographic Builder

## Core Principle

An infographic is a visual argument. Every element should support one key message.

## Three Phases

### Phase 1: Identify the Message
- What ONE thing should the viewer take away?
- All visual elements support this message
- If you have multiple messages, you have multiple infographics

### Phase 2: Structure the Hierarchy
- **Hero metric**: the single most important number/fact — largest, top, bold
- **Supporting data**: 3-5 data points that support the hero metric
- **Context**: comparisons, trends, or benchmarks that give the data meaning
- **Details**: supplementary info for those who want to go deeper

### Phase 3: Format for Scanning
- Use headers to create visual sections
- Tables for comparisons
- Bold for key numbers
- Bullet points for parallel items
- Icons/emoji sparingly for visual anchors (only when requested)

## Output Structure

```markdown
# [Title — the key message]

## [Hero Metric]
**[Big Number]** — [what it means]

## Key Findings
| Metric | Value | Change |
|--------|-------|--------|
| ...    | ...   | ...    |

## Context
[1-2 sentences explaining why this matters]

## Details
- [Supporting point 1]
- [Supporting point 2]
```

## Anti-Patterns

- **Data dump**: showing all data without hierarchy — everything is equally (un)important
- **No comparison**: numbers without context are meaningless. "500ms" — is that good or bad?
- **Too much text**: an infographic with 500 words is just an article with formatting
- **Decoration over information**: fancy formatting that doesn't convey meaning
