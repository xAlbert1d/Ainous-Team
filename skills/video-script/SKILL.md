---
name: video-script
description: Structures scripts for demo videos, tutorials, and presentations with hooks, pacing, and calls-to-action. Use when planning video content, conference talks, or recorded demos.
---

# Video Script Generator

## Core Principle

Every second of video costs attention. If a section doesn't teach, prove, or engage — cut it.

## Structure

### 1. Hook (first 5-10 seconds)
- Open with the payoff or a surprising claim
- BAD: "Hi everyone, today I'm going to talk about..."
- GOOD: "This one change cut our deploy time from 20 minutes to 45 seconds."
- Visual: show the end result immediately (demo-first)

### 2. Context (15-30 seconds)
- Why this matters — the problem being solved
- Keep it brief — the viewer already clicked because of the title/thumbnail
- Establish credibility quickly: "We've been running this in production for 6 months"

### 3. Content Sections (bulk of video)
- Break into 2-4 clear sections with visual transitions
- Each section: concept (10s) → demo (30-60s) → key takeaway (5s)
- **Show, don't tell**: screen recordings > slides > talking head
- Pacing: alternate between explanation and demonstration

### 4. Recap (10-15 seconds)
- Summarize the 2-3 key takeaways
- Reinforce the main insight from the hook

### 5. Call-to-Action (5-10 seconds)
- ONE action: "Link in description", "Try it yourself", "Star the repo"
- Don't ask for 5 things (subscribe, like, comment, share, donate)

## Pacing Rules

| Segment | Duration | Purpose |
|---------|----------|---------|
| Quick cuts | 2-3 sec | Energy, transitions, montages |
| Demo shots | 10-30 sec | Showing functionality |
| Explanation | 5-15 sec | Context between demos |
| Pause/breath | 1-2 sec | Let key points land |

## Script Format

```
[VISUAL: screen recording of terminal]
[NARRATION]: "Watch what happens when we run the deploy command."
[ACTION: type `deploy --production` and press enter]
[VISUAL: progress bar completing in 45 seconds]
[NARRATION]: "45 seconds. That's it."
```

## Anti-Patterns

- **Talking head for 5 minutes**: show the thing, don't describe it
- **No visual cues in script**: the editor needs to know what to show
- **Monotone pacing**: same speed throughout — vary rhythm
- **Starting with credentials**: "I'm a senior engineer at..." — nobody cares yet, earn attention first
