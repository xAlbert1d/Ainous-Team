---
name: image-hero
description: "Author a gpt-image-2 hero/banner prompt and hand off to codex-image-gen. Triggers: make a hero, banner image, landing page background art."
---

# Image Hero

Follow the conventions in image-craft-base; this skill specializes them for hero and banner images.

## Key Move

Name a **quiet text region** (e.g., "left 38% dark and empty for headline text"). Place the focal point **vertically centered** so a cover-crop at any common aspect never cuts it.

## Failure Mode to Prevent

Bright, busy, or high-detail content behind the headline area destroys legibility. A focal point near the top or bottom edge gets cropped by cover-fit containers. Fix both in the prompt — not in post.

## Default Size / Quality

Generate at 2880×1616 (×16-valid) → deliver/crop to target size (e.g. 2880×1620 final after crop) / high

## Sample Cue

> "Wide cinematic scene, quiet left 38% dark gradient for headline, focal bloom centered-right, palette #0A0B0F background / #5C8DFF glow / #B5D44A accent, no text, no logos."

## Concrete Handoff Example

Pass this description string verbatim to codex-image-gen (this is the full text for its `description` argument):

```
Generate ONE 16:9 image and save it as public/hero.png (generate at 2880x1616;
resize/crop with sips to final 2880x1616 or crop to taste). Produce exactly that one file.

SCENE: Wide cinematic deep-space nebula, dramatic directional light from the right,
shallow depth-of-field background haze.
SUBJECT: Abstract geometric bloom, glowing blue-white, centered in the right 55% of the frame.
IMPORTANT DETAILS: Palette #0A0B0F (obsidian) / #5C8DFF (electric blue) / #B5D44A (acid lime).
Smooth gradient sweep left to right; left 38% of frame is the darkest region — keep it empty
and quiet. Vertically centered composition so a cover-crop is safe.
USE CASE: Hero banner sitting behind a white headline and subhead on a SaaS landing page.
CONSTRAINTS: No text, no letters, no logos, no literal objects (pure abstract/atmospheric).
High resolution, sharp focus, no watermark, no signature, no stock-photo borders.
No extra, duplicate, or garbled text.
```

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
