---
name: image-social-card
description: "Author a gpt-image-2 OG/social card or 9:16 story prompt with verbatim text and hand off to codex-image-gen. Triggers: OG image, social card, Open Graph, share card, story graphic."
---

# Image Social Card

Follow the conventions in image-craft-base; this skill specializes them for OG/social cards and 9:16 story graphics.

## Key Move

**Text must be verbatim.** Quote the exact string in the prompt: `headline reads exactly "Ship faster"`. Add `"no other text, no extra, duplicate, or garbled text"` to CONSTRAINTS. Always use `quality=high` — text accuracy degrades at lower tiers. Verify spelling visually after generation.

For 9:16 stories, apply the **Meta safe zone (March 2026)**: keep all key content and text out of the top 14%, bottom 20–35%, and sides 6%. Place text in the center band (~80% wide × 51–66% tall).

## Failure Modes to Prevent

- **Misspelled or duplicated text** — the most common failure on gpt-image-2. Quote exact strings, use `quality=high`, verify visually. Regenerate if wrong; do not ship garbled text.
- **Text in the unsafe overlay zone** — platform UI (reactions, caption bar, profile strip) covers the safe-zone margins. Text placed there will be obscured.

## Default Size / Quality

OG card: generate 1216×640 (×16-valid) → crop/resize to deliver 1200×630 / high
Story: generate 1088×1920 (×16-valid) → crop to deliver 1080×1920 / high

## Sample Cues

**OG card:**
> "Bold editorial layout, headline reads exactly 'Ship faster', no other text, dark #111111 background, bold white sans-serif, centered composition, generate at 1216×640 (crop/resize to final 1200×630 OG delivery)."

**9:16 story:**
> "Vibrant gradient story card, headline reads exactly 'New drop', centered vertically in safe zone (avoid top 14% and bottom 35%), bold sans white text, palette #FF4F00 / #1A1A2E, no other text."

## Handoff

Build the 5-section prompt per image-craft-base, then pass it to codex-image-gen. Always call out the verbatim text requirement in the prompt and verify spelling in the output image before handing off to the user.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
