---
name: image-icon
description: "Author a gpt-image-2 prompt for an app icon, favicon, glyph, or logo/wordmark and hand off to codex-image-gen. Triggers: make an icon, app icon/favicon, logo/glyph, transparent icon."
---

# Image Icon

Follow the conventions in image-craft-base; this skill specializes them for icons, favicons, glyphs, and logo/wordmarks.

## GATE — Transparency

**State this to the user before generating:** gpt-image-2 cannot produce a transparent background. Generate on a named solid flat color (e.g., `flat #FFFFFF background` or `flat #000000 background`), then remove the background in post (rembg, Figma, Photoshop). Never silently ship a baked solid background as if it were transparent — tell the user the extra step is required.

## Key Move

Single centered glyph on a named solid flat background. Keep detail minimal enough to read at 32px. For a wordmark: quote the exact text and add `"no other text"` to CONSTRAINTS.

## Failure Modes to Prevent

- Glyph too detailed or multi-element — dissolves to mush at favicon size. Simplify to one bold shape.
- Garbled or duplicated wordmark characters — quote exact text, use `quality=high`, verify spelling visually after generation.
- Background not named / not flat — makes background removal unreliable.

## Default Size / Quality

1024×1024 / high

## Sample Cues

**Glyph mode:**
> "Single rounded paper-plane glyph, centered, bold geometric, flat #FFFFFF background, legible at 32px, no other elements."

**Logo/wordmark mode:**
> "Wordmark reading exactly 'ACME', bold geometric sans, centered, flat #FFFFFF background, no other text, no icons, no decorative elements."

## Concrete Handoff Example

Pass this description string verbatim to codex-image-gen (this is the full text for its `description` argument):

```
Generate ONE 1:1 image and save it as public/icons/app-icon.png (generate at 1024×1024;
resize/crop with sips if the native size differs). Produce exactly that one file.

SCENE: Flat studio, no shadows, no gradients, flat #2E4057 solid background.
SUBJECT: Single centered paper-plane glyph, bold geometric, occupying ~60% of the canvas.
IMPORTANT DETAILS: Palette #2E4057 (background) / #FFFFFF (glyph). Crisp geometric outlines,
no decorative flourishes, legible at 32px.
USE CASE: App icon / favicon glyph on a named solid background (background will be removed in post).
CONSTRAINTS: Single glyph only, no other elements, no text, no shadows, no gradients.
High resolution, sharp focus, no watermark, no signature, no stock-photo borders.
No extra, duplicate, or garbled text.
```

Post step: remove the solid #2E4057 background (rembg, Figma, or Photoshop) to obtain a transparent PNG — or route to gpt-image-1.5 which supports native alpha output.

## Handoff

Build the 5-section prompt per image-craft-base, then pass it to codex-image-gen. Include the background-removal note in your response to the user so they know to run the post step.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
