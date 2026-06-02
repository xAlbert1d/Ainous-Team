---
name: image-background
description: "Author a gpt-image-2 full-bleed abstract/ambient background prompt and hand off to codex-image-gen. Triggers: background art, abstract backdrop, ambient gradient art."
---

# Image Background

Follow the conventions in image-craft-base; this skill specializes them for full-bleed abstract and ambient backgrounds.

## Key Move

Reserve a **dark quiet zone** for overlaid UI text by naming it in the prompt (e.g., "quiet dark lower third for text overlay"). Explicitly include `"non-repeating"` and `"do not tile"` in CONSTRAINTS — a background that accidentally tiles looks broken on wide viewports.

## Failure Modes to Prevent

- **Competes with foreground UI** — high-detail or high-saturation content across the full frame destroys readability of overlaid text, icons, and controls. Reserve quiet zones by name.
- **Accidental tiling** — without an explicit `non-repeating` constraint, the model sometimes produces edge-matched patterns that tile. State it explicitly.

## Default Size / Quality

2560×1440 / medium

## Sample Cue

> "Full-bleed ambient aurora gradient, quiet dark lower third for text overlay, non-repeating, low saturation, soft horizontal bands, palette #0D1117 deep dark / #1A3A5C midnight blue / #0E6E55 muted teal, no focal objects, no text."

## Handoff

Build the 5-section prompt per image-craft-base, then pass it to codex-image-gen. If the background will sit behind live UI text, remind the user to screenshot the composed result — an image that looks fine alone can destroy legibility behind a headline.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
